//! LZP preprocessor — Lempel-Ziv Prediction, inspired by FreeArc's LZP.
//!
//! Context-hash predictor. For each position `i >= CTX`, hash the `CTX` bytes
//! preceding `i` and look up the last position that shared that context. If
//! the bytes at `i` also match that prior run for at least `MIN_MATCH` bytes,
//! emit (literal_run, match_len) — no explicit offset, since the decoder
//! reproduces the same table and recovers the source position from the
//! current context. Skips over match bytes without updating the table (same
//! as the encoder), so both sides stay in lockstep.
//!
//! Format (little-endian):
//!
//!     repeat:
//!         [u64: block_raw_len]                  -- 0 marks end-of-stream
//!         if block_raw_len < CTX + MIN_MATCH:
//!             [varint: block_raw_len]
//!             block_raw_len raw bytes           -- short block, all-literal
//!         else:
//!             until block_raw_len bytes reconstructed:
//!                 [varint: literal_run_len]
//!                 literal_run_len raw bytes
//!                 if still more to reconstruct:
//!                     [varint: match_len]       -- >= MIN_MATCH
//!
//! Single-block in-memory (no streaming across blocks); caller buffers.

use anyhow::{anyhow, Result};
use byteorder::{LittleEndian, ReadBytesExt, WriteBytesExt};
use std::io::{Read, Write};

use crate::rep::write_varint;

/// Length of the context window hashed for prediction.
pub const CTX: usize = 8;
const HASH_BITS: u32 = 20; // 1M entries, 4 MiB u32 table
const HASH_SIZE: usize = 1 << HASH_BITS;
const HASH_MASK: u32 = (HASH_SIZE - 1) as u32;
/// Minimum match length to emit. LZP is paired with a downstream backend that
/// already handles short matches (zstd/LZMA/PPMd), so we only pay off when
/// the match is long enough that the single varint beats the raw bytes.
pub const MIN_MATCH: usize = 32;

pub struct LzpWriter<W: Write> {
    inner: W,
    buf: Vec<u8>,
}

impl<W: Write> LzpWriter<W> {
    pub fn new(inner: W) -> Self {
        Self { inner, buf: Vec::new() }
    }

    pub fn finish(mut self) -> Result<W> {
        if !self.buf.is_empty() {
            encode_block(&self.buf, &mut self.inner)?;
        }
        self.inner.write_u64::<LittleEndian>(0)?;
        Ok(self.inner)
    }
}

impl<W: Write> Write for LzpWriter<W> {
    fn write(&mut self, data: &[u8]) -> std::io::Result<usize> {
        self.buf.extend_from_slice(data);
        Ok(data.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

pub struct LzpReader<R: Read> {
    inner: R,
    block: Vec<u8>,
    pos: usize,
    done: bool,
}

impl<R: Read> LzpReader<R> {
    pub fn new(inner: R) -> Self {
        Self { inner, block: Vec::new(), pos: 0, done: false }
    }

    fn fill_next_block(&mut self) -> Result<()> {
        let block_len = self.inner.read_u64::<LittleEndian>()? as usize;
        if block_len == 0 {
            self.done = true;
            return Ok(());
        }
        let mut out: Vec<u8> = Vec::with_capacity(block_len);
        if block_len < CTX + MIN_MATCH {
            let lit_len = read_varint(&mut self.inner)? as usize;
            if lit_len != block_len {
                return Err(anyhow!("lzp: short-block header mismatch"));
            }
            out.resize(lit_len, 0);
            self.inner.read_exact(&mut out)?;
            self.block = out;
            self.pos = 0;
            return Ok(());
        }
        let mut table: Vec<u32> = vec![u32::MAX; HASH_SIZE];
        let mut upd_i: usize = CTX;

        while out.len() < block_len {
            let lit_len = read_varint(&mut self.inner)? as usize;
            let start = out.len();
            if start + lit_len > block_len {
                return Err(anyhow!("lzp: literal run overflows block"));
            }
            out.resize(start + lit_len, 0);
            self.inner.read_exact(&mut out[start..start + lit_len])?;
            if out.len() >= block_len {
                break;
            }
            let match_start = out.len();
            while upd_i < match_start {
                let h = (ctx_hash_at(&out, upd_i) & HASH_MASK) as usize;
                table[h] = upd_i as u32;
                upd_i += 1;
            }
            let h = (ctx_hash_at(&out, match_start) & HASH_MASK) as usize;
            let candidate = table[h];
            if candidate == u32::MAX {
                return Err(anyhow!("lzp: match with no predicted source"));
            }
            let p = candidate as usize;
            table[h] = match_start as u32;
            let m = read_varint(&mut self.inner)? as usize;
            if m < MIN_MATCH || p + m > match_start || match_start + m > block_len {
                return Err(anyhow!(
                    "lzp: bad match len={m} p={p} at {match_start} (block={block_len})"
                ));
            }
            for j in 0..m {
                let b = out[p + j];
                out.push(b);
            }
            upd_i = match_start + m;
        }
        if out.len() != block_len {
            return Err(anyhow!("lzp: block size mismatch {} vs {}", out.len(), block_len));
        }
        self.block = out;
        self.pos = 0;
        Ok(())
    }
}

impl<R: Read> Read for LzpReader<R> {
    fn read(&mut self, dst: &mut [u8]) -> std::io::Result<usize> {
        if self.pos >= self.block.len() {
            if self.done {
                return Ok(0);
            }
            self.fill_next_block()
                .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e.to_string()))?;
            if self.done {
                return Ok(0);
            }
        }
        let avail = self.block.len() - self.pos;
        let n = dst.len().min(avail);
        dst[..n].copy_from_slice(&self.block[self.pos..self.pos + n]);
        self.pos += n;
        Ok(n)
    }
}

fn encode_block<W: Write>(buf: &[u8], out: &mut W) -> Result<()> {
    out.write_u64::<LittleEndian>(buf.len() as u64)?;
    if buf.len() < CTX + MIN_MATCH {
        write_varint(out, buf.len() as u64)?;
        out.write_all(buf)?;
        return Ok(());
    }
    let mut table: Vec<u32> = vec![u32::MAX; HASH_SIZE];
    let mut i: usize = CTX;
    let mut lit_start: usize = 0;

    while i + MIN_MATCH <= buf.len() {
        let h = (ctx_hash_at(buf, i) & HASH_MASK) as usize;
        let candidate = table[h];
        table[h] = i as u32;
        if candidate != u32::MAX {
            let p = candidate as usize;
            if p + MIN_MATCH <= i && buf[p..p + MIN_MATCH] == buf[i..i + MIN_MATCH] {
                let mut m = MIN_MATCH;
                while i + m < buf.len() && p + m < i && buf[p + m] == buf[i + m] {
                    m += 1;
                }
                let lit_len = i - lit_start;
                write_varint(out, lit_len as u64)?;
                out.write_all(&buf[lit_start..i])?;
                write_varint(out, m as u64)?;
                i += m;
                lit_start = i;
                continue;
            }
        }
        i += 1;
    }
    let lit_len = buf.len() - lit_start;
    write_varint(out, lit_len as u64)?;
    out.write_all(&buf[lit_start..])?;
    Ok(())
}

#[inline]
fn ctx_hash_at(buf: &[u8], pos: usize) -> u32 {
    let mut h: u32 = 2166136261;
    for j in 0..CTX {
        h ^= buf[pos - CTX + j] as u32;
        h = h.wrapping_mul(16777619);
    }
    h
}

fn read_varint<R: Read>(r: &mut R) -> Result<u64> {
    let mut v: u64 = 0;
    let mut s: u32 = 0;
    for _ in 0..10 {
        let b = r.read_u8()?;
        v |= ((b & 0x7F) as u64) << s;
        if b & 0x80 == 0 {
            return Ok(v);
        }
        s += 7;
    }
    Err(anyhow!("lzp: varint too long"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn roundtrip(data: &[u8]) {
        let mut compressed = Vec::new();
        {
            let mut w = LzpWriter::new(&mut compressed);
            w.write_all(data).unwrap();
            w.finish().unwrap();
        }
        let mut r = LzpReader::new(&compressed[..]);
        let mut out = Vec::new();
        r.read_to_end(&mut out).unwrap();
        assert_eq!(out, data);
    }

    #[test]
    fn empty() { roundtrip(b""); }

    #[test]
    fn tiny() { roundtrip(b"hello world"); }

    #[test]
    fn below_threshold() {
        let data = vec![0xABu8; CTX + MIN_MATCH - 1];
        roundtrip(&data);
    }

    #[test]
    fn repeated_chunks() {
        let chunk = b"the quick brown fox jumps over the lazy dog 0123456789 abcdefghij";
        let mut data = Vec::new();
        for _ in 0..20 {
            data.extend_from_slice(chunk);
        }
        roundtrip(&data);
    }

    #[test]
    fn mixed_noise_and_repeats() {
        let mut data = Vec::new();
        let mut s: u32 = 0xC0FFEE;
        for _ in 0..2000 {
            s = s.wrapping_mul(1664525).wrapping_add(1013904223);
            data.push((s >> 16) as u8);
        }
        let rep = b"REPEATED_PAYLOAD_REPEATED_PAYLOAD_REPEATED_PAYLOAD_REPEATED_PAYLOAD";
        for _ in 0..5 {
            data.extend_from_slice(rep);
        }
        for _ in 0..2000 {
            s = s.wrapping_mul(1664525).wrapping_add(1013904223);
            data.push((s >> 16) as u8);
        }
        for _ in 0..5 {
            data.extend_from_slice(rep);
        }
        roundtrip(&data);
    }
}
