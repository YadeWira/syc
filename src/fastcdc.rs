//! FastCDC chunker — Content-Defined Chunking via Gear rolling hash.
//!
//! Splits a byte stream into variable-size chunks whose boundaries depend on
//! content, not absolute offset. Identical content produces identical
//! boundaries even when shifted, which lets a dedup registry catch partial
//! overlap between files (backup snapshots, VM images, near-duplicate blobs).
//!
//! Algorithm (FastCDC paper, normalized chunking):
//!   - Gear hash: `h = (h << 1) + GEAR[byte]`, table of 256 well-mixed u64
//!     values (deterministic splitmix64 sequence, so encode/decode agree).
//!   - Ignore the first MIN_SIZE bytes (floor).
//!   - From MIN_SIZE..AVG_SIZE: strict mask `MASK_S` — fewer boundaries,
//!     nudges average chunk size up.
//!   - From AVG_SIZE..MAX_SIZE: relaxed mask `MASK_L` — more boundaries,
//!     caps tail.
//!   - If no boundary by MAX_SIZE: force cut.
//!
//! Streaming: buffers up to MAX_SIZE + a pad, emits one chunk at a time.

use anyhow::{anyhow, Result};
use std::collections::HashMap;
use std::hash::Hasher;
use std::io::{self, Read, Write};

use crate::rep::write_varint;

pub const MIN_SIZE: usize = 2 * 1024;
pub const AVG_SIZE: usize = 8 * 1024;
pub const MAX_SIZE: usize = 64 * 1024;

const MASK_S: u64 = 0x0003_59E3_520A_0000;
const MASK_L: u64 = 0x0000_D900_0353_0000;

const fn build_gear() -> [u64; 256] {
    let mut t = [0u64; 256];
    let mut x: u64 = 0x9E37_79B9_7F4A_7C15;
    let mut i = 0;
    while i < 256 {
        x = x.wrapping_mul(0xBF58_476D_1CE4_E5B9).wrapping_add(0x94D0_49BB_1331_11EB);
        t[i] = x;
        i += 1;
    }
    t
}
static GEAR: [u64; 256] = build_gear();

/// Find the next chunk boundary within `buf`. Returns chunk length in bytes.
/// If `buf.len() <= MIN_SIZE`, returns `buf.len()` (accept the short tail).
pub fn next_boundary(buf: &[u8]) -> usize {
    let n = buf.len();
    if n <= MIN_SIZE {
        return n;
    }
    let mut hash: u64 = 0;
    let mut i = MIN_SIZE;
    let end_s = n.min(AVG_SIZE);
    let end_l = n.min(MAX_SIZE);
    while i < end_s {
        hash = (hash << 1).wrapping_add(GEAR[buf[i] as usize]);
        if hash & MASK_S == 0 {
            return i + 1;
        }
        i += 1;
    }
    while i < end_l {
        hash = (hash << 1).wrapping_add(GEAR[buf[i] as usize]);
        if hash & MASK_L == 0 {
            return i + 1;
        }
        i += 1;
    }
    end_l
}

/// Streaming chunker over an arbitrary `Read`. `next_chunk` returns `Ok(None)`
/// when the stream is exhausted. The returned slice is valid until the next
/// call to `next_chunk`.
pub struct Chunker<R: Read> {
    reader: R,
    buf: Vec<u8>,
    eof: bool,
}

impl<R: Read> Chunker<R> {
    pub fn new(reader: R) -> Self {
        Self {
            reader,
            buf: Vec::with_capacity(MAX_SIZE * 2),
            eof: false,
        }
    }

    pub fn next_chunk(&mut self) -> io::Result<Option<Vec<u8>>> {
        // Top up the buffer so we can see MAX_SIZE lookahead.
        while !self.eof && self.buf.len() < MAX_SIZE {
            let need = MAX_SIZE - self.buf.len();
            let start = self.buf.len();
            self.buf.resize(start + need, 0);
            match self.reader.read(&mut self.buf[start..start + need]) {
                Ok(0) => {
                    self.buf.truncate(start);
                    self.eof = true;
                    break;
                }
                Ok(n) => self.buf.truncate(start + n),
                Err(e) if e.kind() == io::ErrorKind::Interrupted => {
                    self.buf.truncate(start);
                }
                Err(e) => {
                    self.buf.truncate(start);
                    return Err(e);
                }
            }
        }
        if self.buf.is_empty() {
            return Ok(None);
        }
        let len = next_boundary(&self.buf);
        let chunk = self.buf[..len].to_vec();
        self.buf.drain(..len);
        Ok(Some(chunk))
    }
}

/// Fingerprint a chunk for the dedup registry. xxh3_64 is fast and collision
/// rates at these chunk sizes (2..64 KiB) are far below zero-match archives;
/// for absolute safety use `-hash blake3` at the file level on top.
pub fn chunk_hash(chunk: &[u8]) -> u64 {
    let mut h = twox_hash::XxHash3_64::new();
    h.write(chunk);
    h.finish()
}

/// Encoder-side registry: maps chunk hash to the ID assigned on first sight.
pub struct ChunkRegistry {
    map: HashMap<u64, u32>,
    pub next_id: u32,
}

impl ChunkRegistry {
    pub fn new() -> Self {
        Self { map: HashMap::new(), next_id: 0 }
    }

    /// Look up `hash` in the registry. If absent, assigns a fresh ID, stores
    /// it, and returns `(id, true)`. If present, returns `(existing_id, false)`.
    pub fn get_or_insert(&mut self, hash: u64) -> (u32, bool) {
        if let Some(&id) = self.map.get(&hash) {
            return (id, false);
        }
        let id = self.next_id;
        self.map.insert(hash, id);
        self.next_id += 1;
        (id, true)
    }

    pub fn len(&self) -> usize { self.map.len() }
}

/// Write an inline chunk record: `varint(len<<1)` followed by `len` bytes.
pub fn write_chunk_inline<W: Write>(w: &mut W, chunk: &[u8]) -> Result<()> {
    let header = (chunk.len() as u64) << 1;
    write_varint(w, header)?;
    w.write_all(chunk)?;
    Ok(())
}

/// Write a reference to a previously-seen chunk: `varint((id<<1)|1)`.
pub fn write_chunk_ref<W: Write>(w: &mut W, id: u32) -> Result<()> {
    let header = ((id as u64) << 1) | 1;
    write_varint(w, header)
}

#[derive(Debug)]
pub enum ChunkRec {
    Inline(Vec<u8>),
    Ref(u32),
}

/// Read a single chunk record from `r`. Inline records consume their payload.
pub fn read_chunk_rec<R: Read>(r: &mut R) -> Result<ChunkRec> {
    let header = read_varint(r)?;
    if header & 1 == 0 {
        let len = (header >> 1) as usize;
        if len > MAX_SIZE {
            return Err(anyhow!("fastcdc: chunk too large ({} > {})", len, MAX_SIZE));
        }
        let mut buf = vec![0u8; len];
        r.read_exact(&mut buf)?;
        Ok(ChunkRec::Inline(buf))
    } else {
        let id = (header >> 1) as u32;
        Ok(ChunkRec::Ref(id))
    }
}

fn read_varint<R: Read>(r: &mut R) -> Result<u64> {
    let mut v: u64 = 0;
    let mut s: u32 = 0;
    for _ in 0..10 {
        let mut b = [0u8; 1];
        r.read_exact(&mut b)?;
        v |= ((b[0] & 0x7F) as u64) << s;
        if b[0] & 0x80 == 0 {
            return Ok(v);
        }
        s += 7;
    }
    Err(anyhow!("fastcdc: varint too long"))
}

/// Encoder-side: chunk `src` via FastCDC, emit chunk records to `out`, calling
/// `on_raw` with each byte range as it is reconstructed (used for per-file
/// hash update). Returns total reconstructed bytes.
pub fn pack_chunked_body<R: Read, W: Write, F: FnMut(&[u8])>(
    src: R,
    out: &mut W,
    reg: &mut ChunkRegistry,
    mut on_raw: F,
) -> Result<u64> {
    let mut chunker = Chunker::new(src);
    let mut total: u64 = 0;
    while let Some(chunk) = chunker.next_chunk()? {
        on_raw(&chunk);
        total += chunk.len() as u64;
        let h = chunk_hash(&chunk);
        let (id, is_new) = reg.get_or_insert(h);
        if is_new {
            write_chunk_inline(out, &chunk)?;
        } else {
            write_chunk_ref(out, id)?;
        }
    }
    Ok(total)
}

/// Decoder-side chunk cache. Each inline record grows it by one entry; each
/// ref record replays a previously-seen chunk. Shared across all ChunkedFile
/// entries in one archive frame.
pub struct DecodeRegistry {
    chunks: Vec<Vec<u8>>,
}

impl DecodeRegistry {
    pub fn new() -> Self { Self { chunks: Vec::new() } }

    /// Stream the body of one ChunkedFile entry, invoking `on_raw` with each
    /// emitted byte range (for write-to-file, hash-update, or compare). Stops
    /// when `total_size` bytes have been reconstructed. Errors on overshoot
    /// or dangling ref.
    pub fn read_body<R: Read, F: FnMut(&[u8]) -> Result<()>>(
        &mut self,
        r: &mut R,
        total_size: u64,
        mut on_raw: F,
    ) -> Result<()> {
        let mut got: u64 = 0;
        while got < total_size {
            let rec = read_chunk_rec(r)?;
            match rec {
                ChunkRec::Inline(bytes) => {
                    got += bytes.len() as u64;
                    if got > total_size {
                        return Err(anyhow!(
                            "fastcdc: inline chunk overshoots body ({} > {})", got, total_size
                        ));
                    }
                    on_raw(&bytes)?;
                    self.chunks.push(bytes);
                }
                ChunkRec::Ref(id) => {
                    let bytes = self.chunks.get(id as usize).ok_or_else(|| {
                        anyhow!("fastcdc: ref to unknown chunk id {}", id)
                    })?;
                    got += bytes.len() as u64;
                    if got > total_size {
                        return Err(anyhow!(
                            "fastcdc: ref chunk overshoots body ({} > {})", got, total_size
                        ));
                    }
                    on_raw(bytes)?;
                }
            }
        }
        Ok(())
    }

    pub fn unique_chunks(&self) -> usize { self.chunks.len() }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[test]
    fn small_stream_single_chunk() {
        let data = b"hello world";
        let mut c = Chunker::new(Cursor::new(data));
        let ch = c.next_chunk().unwrap().unwrap();
        assert_eq!(&ch[..], data);
        assert!(c.next_chunk().unwrap().is_none());
    }

    #[test]
    fn deterministic_boundaries() {
        // Two runs over identical data must produce identical chunks.
        let mut data = Vec::with_capacity(1_000_000);
        let mut x: u64 = 0xDEAD_BEEF;
        for _ in 0..1_000_000 {
            x = x.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            data.push((x >> 33) as u8);
        }
        let mut a = Vec::new();
        {
            let mut c = Chunker::new(Cursor::new(&data));
            while let Some(ch) = c.next_chunk().unwrap() { a.push(ch); }
        }
        let mut b = Vec::new();
        {
            let mut c = Chunker::new(Cursor::new(&data));
            while let Some(ch) = c.next_chunk().unwrap() { b.push(ch); }
        }
        assert_eq!(a, b);
        let total: usize = a.iter().map(|c| c.len()).sum();
        assert_eq!(total, data.len());
        // Boundaries should land in [MIN_SIZE..=MAX_SIZE] except possibly tail.
        for (i, ch) in a.iter().enumerate() {
            let is_last = i + 1 == a.len();
            if !is_last {
                assert!(ch.len() >= MIN_SIZE && ch.len() <= MAX_SIZE,
                    "bad chunk {} len={}", i, ch.len());
            }
        }
    }

    #[test]
    fn shift_resynchronizes() {
        // FastCDC property: inserting a small prefix should only affect the
        // first chunk or two; later chunks must still match the original.
        let mut data = Vec::with_capacity(300_000);
        let mut x: u64 = 0xC0FFEE;
        for _ in 0..300_000 {
            x = x.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            data.push((x >> 33) as u8);
        }
        let mut a = Vec::new();
        {
            let mut c = Chunker::new(Cursor::new(&data));
            while let Some(ch) = c.next_chunk().unwrap() { a.push(ch); }
        }
        let mut shifted = vec![0xAAu8; 7];
        shifted.extend_from_slice(&data);
        let mut b = Vec::new();
        {
            let mut c = Chunker::new(Cursor::new(&shifted));
            while let Some(ch) = c.next_chunk().unwrap() { b.push(ch); }
        }
        use std::collections::HashSet;
        let hashes_a: HashSet<u64> = a.iter().map(|c| xxhash(c)).collect();
        let hashes_b: HashSet<u64> = b.iter().map(|c| xxhash(c)).collect();
        let shared = hashes_a.intersection(&hashes_b).count();
        // With a 7-byte prefix shift, most chunks should resync.
        assert!(shared >= a.len() / 2,
            "resync too weak: shared {}/{}", shared, a.len());
    }

    fn xxhash(buf: &[u8]) -> u64 {
        use std::hash::Hasher;
        let mut h = twox_hash::XxHash3_64::new();
        h.write(buf);
        h.finish()
    }
}
