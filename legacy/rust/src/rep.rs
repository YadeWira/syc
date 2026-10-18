//! REP preprocessor — inspired by FreeArc's REP.
//!
//! Finds long repeated byte sequences (matches of length >= MIN_MATCH) at
//! arbitrary distances within a single buffered block and replaces them with
//! (length, back_offset) references. What remains passes through unchanged.
//! Downstream compressor (zstd/LZMA) re-compresses the result.
//!
//! Format (little-endian):
//!
//!     [u64: block_raw_len]                      -- 0 marks end-of-stream
//!     repeat until we've reconstructed block_raw_len bytes:
//!         [varint: literal_run_len]
//!         literal_run_len raw bytes
//!         if match follows:
//!             [varint: match_len]               -- >= MIN_MATCH, or 0 = block end
//!             [varint: match_back_offset]       -- from start of match in raw
//!
//! Rolling hash: multiply-shift on 32-bit window. MIN_MATCH bytes confirmed
//! byte-exact before emitting.
//!
//! Single-block in-memory (no streaming across blocks); caller buffers.

use anyhow::{anyhow, Result};
use byteorder::{LittleEndian, ReadBytesExt, WriteBytesExt};
use std::io::{Read, Write};

/// Default floor for REP match length. At runtime callers may use a stricter
/// value via `encode_block_with_min`.
pub const MIN_MATCH: usize = 64;
const HASH_BITS: u32 = 24; // 16M entries
const HASH_SIZE: usize = 1 << HASH_BITS;
const HASH_MASK: u32 = (HASH_SIZE - 1) as u32;

/// Writer adapter: buffers all writes in memory, on finish() encodes the whole
/// buffer as a single REP block and flushes to the inner writer.
pub struct RepWriter<W: Write> {
    inner: W,
    buf: Vec<u8>,
}

impl<W: Write> RepWriter<W> {
    pub fn new(inner: W) -> Self {
        Self { inner, buf: Vec::new() }
    }

    pub fn finish(mut self) -> Result<W> {
        if !self.buf.is_empty() {
            encode_block(&self.buf, &mut self.inner)?;
        }
        // End-of-stream marker: block_raw_len = 0
        self.inner.write_u64::<LittleEndian>(0)?;
        Ok(self.inner)
    }
}

impl<W: Write> Write for RepWriter<W> {
    fn write(&mut self, data: &[u8]) -> std::io::Result<usize> {
        self.buf.extend_from_slice(data);
        Ok(data.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

/// Reader adapter: reads REP-encoded blocks and yields the reconstructed
/// stream. Buffers one block at a time.
pub struct RepReader<R: Read> {
    inner: R,
    block: Vec<u8>,
    pos: usize,
    done: bool,
}

impl<R: Read> RepReader<R> {
    pub fn new(inner: R) -> Self {
        Self { inner, block: Vec::new(), pos: 0, done: false }
    }

    fn fill_next_block(&mut self) -> Result<()> {
        let block_len = self.inner.read_u64::<LittleEndian>()? as usize;
        if block_len == 0 {
            self.done = true;
            return Ok(());
        }
        let mut out = Vec::with_capacity(block_len);
        while out.len() < block_len {
            let lit_len = read_varint(&mut self.inner)? as usize;
            let start = out.len();
            out.resize(start + lit_len, 0);
            self.inner.read_exact(&mut out[start..start + lit_len])?;
            if out.len() >= block_len {
                break;
            }
            let match_len = read_varint(&mut self.inner)? as usize;
            let back = read_varint(&mut self.inner)? as usize;
            if match_len == 0 || back == 0 || back > out.len() {
                return Err(anyhow!("rep: bad reference len={match_len} back={back}"));
            }
            let src_start = out.len() - back;
            for i in 0..match_len {
                let b = out[src_start + i];
                out.push(b);
            }
        }
        if out.len() != block_len {
            return Err(anyhow!("rep: block size mismatch {} vs {}", out.len(), block_len));
        }
        self.block = out;
        self.pos = 0;
        Ok(())
    }
}

impl<R: Read> Read for RepReader<R> {
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
    if buf.len() < MIN_MATCH {
        // All literal.
        write_varint(out, buf.len() as u64)?;
        out.write_all(buf)?;
        return Ok(());
    }

    // Rolling hash over MIN_MATCH-byte windows, indexed by last position.
    // 0xFFFF_FFFF = empty slot sentinel.
    let mut table: Vec<u32> = vec![u32::MAX; HASH_SIZE];

    let mut i: usize = 0;
    let mut lit_start: usize = 0;

    while i + MIN_MATCH <= buf.len() {
        let h = (hash_at(buf, i) & HASH_MASK) as usize;
        let candidate = table[h];
        table[h] = i as u32;

        if candidate != u32::MAX {
            let cand = candidate as usize;
            // Verify match: must match at least MIN_MATCH bytes.
            if cand + MIN_MATCH <= buf.len() && buf[cand..cand + MIN_MATCH] == buf[i..i + MIN_MATCH]
            {
                // Extend match forward.
                let mut m = MIN_MATCH;
                while i + m < buf.len() && cand + m < i && buf[cand + m] == buf[i + m] {
                    m += 1;
                }
                // Emit literal run [lit_start..i], then reference (m, i-cand).
                let lit_len = i - lit_start;
                write_varint(out, lit_len as u64)?;
                out.write_all(&buf[lit_start..i])?;
                write_varint(out, m as u64)?;
                write_varint(out, (i - cand) as u64)?;
                i += m;
                lit_start = i;
                continue;
            }
        }
        i += 1;
    }

    // Flush trailing literal run.
    let lit_len = buf.len() - lit_start;
    write_varint(out, lit_len as u64)?;
    out.write_all(&buf[lit_start..])?;
    Ok(())
}

#[inline]
fn hash_at(buf: &[u8], pos: usize) -> u32 {
    // Fast FNV-1a-ish over MIN_MATCH bytes. MIN_MATCH=64 is small enough to
    // be fine as a straight hash (no need for rolling-update since we jump
    // by match length on hits).
    let mut h: u32 = 2166136261;
    for j in 0..MIN_MATCH {
        h ^= buf[pos + j] as u32;
        h = h.wrapping_mul(16777619);
    }
    h
}

pub fn write_varint<W: Write>(w: &mut W, mut v: u64) -> Result<()> {
    while v >= 0x80 {
        w.write_u8(((v as u8) & 0x7F) | 0x80)?;
        v >>= 7;
    }
    w.write_u8(v as u8)?;
    Ok(())
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
    Err(anyhow!("varint too long"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn roundtrip(data: &[u8]) {
        let mut compressed = Vec::new();
        {
            let mut w = RepWriter::new(&mut compressed);
            w.write_all(data).unwrap();
            w.finish().unwrap();
        }
        let mut r = RepReader::new(&compressed[..]);
        let mut out = Vec::new();
        r.read_to_end(&mut out).unwrap();
        assert_eq!(out, data);
    }

    #[test]
    fn empty() { roundtrip(b""); }

    #[test]
    fn tiny() { roundtrip(b"hello world"); }

    #[test]
    fn repeated() {
        let chunk = b"abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz01";
        let mut data = Vec::new();
        for _ in 0..10 { data.extend_from_slice(chunk); }
        roundtrip(&data);
    }
}
