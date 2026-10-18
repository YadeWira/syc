//! SREP — huge-dictionary LZ77 preprocessor, ported from Bulat Ziganshin's
//! SREP 3.93a (in-mem variant: Compression/SREP/compress_inmem.cpp).
//!
//! Key idea vs REP: sample ONE hash per L-byte block (the *local maximum* of a
//! polynomial rolling hash over that block). For a file of size N this yields
//! only N/L signatures instead of one per position, so the hash table stays
//! lightly loaded even for multi-GB inputs. That's the whole point — cover
//! distances REP can't handle without hash-table saturation.
//!
//! Emits the SAME wire format as `rep.rs`, so we reuse `RepReader` for decode.
//!
//! Defaults: L = MIN_MATCH = 512 (matches SREP's `-m3` preset).
//! Hash slots default to 2^24 (64 MiB of u64 entries).
//!
//! Matches of length < 2L may be missed (window alignment) — this is by design,
//! SREP is meant to catch very long repeats. Use REP for shorter ones.

use anyhow::Result;
use byteorder::{LittleEndian, WriteBytesExt};
use std::io::Write;

use crate::rep::write_varint;

const L: usize = 512;
const MIN_MATCH: usize = 512;
const PRIME: u64 = 153_191;
const HASH_BITS: u32 = 24;
const HASH_SIZE: usize = 1 << HASH_BITS;
const HASH_MASK: u64 = (HASH_SIZE as u64) - 1;
const EMPTY: u64 = u64::MAX;

/// Single-block in-memory SREP writer. Buffers the full input, encodes on
/// finish().
pub struct SrepWriter<W: Write> {
    inner: W,
    buf: Vec<u8>,
}

impl<W: Write> SrepWriter<W> {
    pub fn new(inner: W) -> Self {
        Self { inner, buf: Vec::new() }
    }

    pub fn finish(mut self) -> Result<W> {
        if !self.buf.is_empty() {
            encode_block(&self.buf, &mut self.inner)?;
        }
        // End-of-stream marker (shared with REP decoder).
        self.inner.write_u64::<LittleEndian>(0)?;
        Ok(self.inner)
    }
}

impl<W: Write> Write for SrepWriter<W> {
    fn write(&mut self, data: &[u8]) -> std::io::Result<usize> {
        self.buf.extend_from_slice(data);
        Ok(data.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

fn encode_block<W: Write>(buf: &[u8], out: &mut W) -> Result<()> {
    out.write_u64::<LittleEndian>(buf.len() as u64)?;
    if buf.len() < 2 * L {
        write_varint(out, buf.len() as u64)?;
        out.write_all(buf)?;
        return Ok(());
    }

    // Precompute PRIME^L (mod 2^64).
    let prime_l = pow_mod64(PRIME, L as u64);

    // Initial polynomial hash over buf[0..L].
    let mut hash: u64 = 0;
    for &b in &buf[..L] {
        hash = hash.wrapping_mul(PRIME).wrapping_add(b as u64);
    }

    // Step 1 — for each L-byte block starting at block_start=0, scan L windows
    // and record the (hash_mod_mask, position_within_block) with max raw hash.
    // Blocks processed: 0..num_blocks-1 (same as SREP, which reserves the last
    // L bytes since their windows would run past the buffer).
    let num_blocks = buf.len() / L;
    if num_blocks < 2 {
        write_varint(out, buf.len() as u64)?;
        out.write_all(buf)?;
        return Ok(());
    }
    // Signatures[b] = (slot, offset_within_block) for block b in [0..num_blocks-1).
    let mut signatures: Vec<(u64, u16)> = Vec::with_capacity(num_blocks);
    // Current window start as we walk.
    let mut p = 0usize;
    for _block in 0..(num_blocks - 1) {
        let mut max_hash = hash;
        let mut max_off: u16 = 0;
        for i in 0..L {
            if hash > max_hash {
                max_hash = hash;
                max_off = i as u16;
            }
            // Roll hash one byte: drop buf[p], add buf[p+L].
            let sub = buf[p] as u64;
            let add = buf[p + L] as u64;
            hash = hash
                .wrapping_mul(PRIME)
                .wrapping_add(add)
                .wrapping_sub(prime_l.wrapping_mul(sub));
            p += 1;
        }
        signatures.push((max_hash & HASH_MASK, max_off));
    }

    // Step 2 — walk blocks, lookup hash table, verify, extend, emit.
    let mut table: Vec<u64> = vec![EMPTY; HASH_SIZE];
    let mut i: usize = 0;
    let mut lit_start: usize = 0;
    let mut last_match_end: usize = 0;

    for (slot, off) in signatures.iter().copied() {
        let slot = slot as usize;
        let cand_pos = i + off as usize; // absolute window position in buf
        // Only consider if we're past the last emitted match.
        if cand_pos >= last_match_end {
            let prev = table[slot];
            if prev != EMPTY {
                let prev = prev as usize;
                if prev < cand_pos {
                    // Verify & extend.
                    if windows_equal(buf, prev, cand_pos, L) {
                        // Extend forward.
                        let mut end_a = prev + L;
                        let mut end_b = cand_pos + L;
                        while end_b < buf.len() && buf[end_a] == buf[end_b] {
                            end_a += 1;
                            end_b += 1;
                        }
                        // Extend backward.
                        let mut start_a = prev;
                        let mut start_b = cand_pos;
                        let back_limit = last_match_end.max(
                            // Don't back past the candidate source either.
                            0,
                        );
                        while start_a > 0 && start_b > back_limit && buf[start_a - 1] == buf[start_b - 1] {
                            start_a -= 1;
                            start_b -= 1;
                        }
                        let match_len = end_b - start_b;
                        if match_len >= MIN_MATCH {
                            let lit_len = start_b - lit_start;
                            write_varint(out, lit_len as u64)?;
                            out.write_all(&buf[lit_start..start_b])?;
                            let back = start_b - start_a;
                            write_varint(out, match_len as u64)?;
                            write_varint(out, back as u64)?;
                            last_match_end = end_b;
                            lit_start = end_b;
                        }
                    }
                }
            }
            table[slot] = cand_pos as u64;
        }
        i += L;
    }

    // Flush trailing literal run.
    let lit_len = buf.len() - lit_start;
    write_varint(out, lit_len as u64)?;
    out.write_all(&buf[lit_start..])?;
    Ok(())
}

#[inline]
fn windows_equal(buf: &[u8], a: usize, b: usize, n: usize) -> bool {
    if a + n > buf.len() || b + n > buf.len() {
        return false;
    }
    buf[a..a + n] == buf[b..b + n]
}

#[inline]
fn pow_mod64(base: u64, mut exp: u64) -> u64 {
    let mut b = base;
    let mut r: u64 = 1;
    while exp > 0 {
        if exp & 1 == 1 {
            r = r.wrapping_mul(b);
        }
        b = b.wrapping_mul(b);
        exp >>= 1;
    }
    r
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rep::RepReader;
    use std::io::Read;

    fn roundtrip(data: &[u8]) {
        let mut compressed = Vec::new();
        {
            let mut w = SrepWriter::new(&mut compressed);
            w.write_all(data).unwrap();
            w.finish().unwrap();
        }
        let mut r = RepReader::new(&compressed[..]);
        let mut out = Vec::new();
        r.read_to_end(&mut out).unwrap();
        assert_eq!(out.len(), data.len());
        assert_eq!(out, data);
    }

    #[test]
    fn empty() { roundtrip(b""); }

    #[test]
    fn tiny() { roundtrip(b"hello world"); }

    #[test]
    fn repeated_big() {
        // Two identical 4 KiB chunks far apart → SREP must find the match.
        let mut chunk = Vec::with_capacity(4096);
        for i in 0..4096 { chunk.push((i % 251) as u8); }
        let mut data = Vec::new();
        data.extend_from_slice(&chunk);
        // Gap of pseudo-random bytes.
        for i in 0..8192 { data.push(((i * 31 + 7) % 251) as u8); }
        data.extend_from_slice(&chunk);
        roundtrip(&data);
    }

    #[test]
    fn no_matches() {
        let mut data = Vec::with_capacity(10_000);
        for i in 0..10_000 { data.push(((i * 1103515245 + 12345) >> 8) as u8); }
        roundtrip(&data);
    }
}
