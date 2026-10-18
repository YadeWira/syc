//! Delta pre-filter: transforms byte[i] -> byte[i] - byte[i-stride] (wrapping)
//! on encode, and the inverse on decode. Cheap win on data with smooth numeric
//! structure: 16-bit PCM audio (stride=2), 32-bit RGBA rasters (stride=4),
//! mono 8-bit samples (stride=1). Neutral-to-slight-loss on everything else,
//! so strictly opt-in via `-delta N`.
//!
//! Mirrors xz's built-in Delta filter (xz2 doesn't expose it from Rust) so
//! ratio improvements on PCM match what `xz --delta=dist=N --lzma2` would
//! give. The wrapper sits between the archive body stream and the backend
//! compressor; no per-entry framing, so it's archive-level (all bodies share
//! the same running state, which is fine because deltas just reset to zero
//! at stream start and realign after a few bytes anyway).

use std::io::{self, Read, Write};

pub const MAX_STRIDE: usize = 4;

/// Returns true if `stride` is an accepted value (1, 2, or 4).
pub fn is_valid_stride(stride: u8) -> bool {
    matches!(stride, 1 | 2 | 4)
}

pub struct DeltaWriter<W: Write> {
    inner: W,
    stride: usize,
    ring: [u8; MAX_STRIDE],
    pos: usize,
    buf: Vec<u8>,
}

impl<W: Write> DeltaWriter<W> {
    pub fn new(inner: W, stride: u8) -> Self {
        Self {
            inner,
            stride: stride as usize,
            ring: [0; MAX_STRIDE],
            pos: 0,
            buf: Vec::with_capacity(16 * 1024),
        }
    }

    pub fn finish(self) -> io::Result<W> {
        Ok(self.inner)
    }
}

impl<W: Write> Write for DeltaWriter<W> {
    fn write(&mut self, data: &[u8]) -> io::Result<usize> {
        self.buf.clear();
        self.buf.reserve(data.len());
        for &b in data {
            let prev = self.ring[self.pos];
            self.buf.push(b.wrapping_sub(prev));
            self.ring[self.pos] = b;
            self.pos += 1;
            if self.pos == self.stride {
                self.pos = 0;
            }
        }
        self.inner.write_all(&self.buf)?;
        Ok(data.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        self.inner.flush()
    }
}

pub struct DeltaReader<R: Read> {
    inner: R,
    stride: usize,
    ring: [u8; MAX_STRIDE],
    pos: usize,
}

impl<R: Read> DeltaReader<R> {
    pub fn new(inner: R, stride: u8) -> Self {
        Self {
            inner,
            stride: stride as usize,
            ring: [0; MAX_STRIDE],
            pos: 0,
        }
    }
}

impl<R: Read> Read for DeltaReader<R> {
    fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
        let n = self.inner.read(out)?;
        for b in &mut out[..n] {
            let prev = self.ring[self.pos];
            let val = b.wrapping_add(prev);
            *b = val;
            self.ring[self.pos] = val;
            self.pos += 1;
            if self.pos == self.stride {
                self.pos = 0;
            }
        }
        Ok(n)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn roundtrip(stride: u8, input: &[u8]) {
        let mut encoded = Vec::new();
        {
            let mut w = DeltaWriter::new(&mut encoded, stride);
            w.write_all(input).unwrap();
            w.finish().unwrap();
        }
        let mut decoded = Vec::new();
        let mut r = DeltaReader::new(&encoded[..], stride);
        let mut buf = [0u8; 37]; // odd size to exercise boundary alignment
        loop {
            let n = r.read(&mut buf).unwrap();
            if n == 0 { break; }
            decoded.extend_from_slice(&buf[..n]);
        }
        assert_eq!(decoded, input);
    }

    #[test]
    fn roundtrip_stride1_random() {
        let data: Vec<u8> = (0..4096).map(|i| ((i * 2654435761u32) >> 24) as u8).collect();
        roundtrip(1, &data);
    }

    #[test]
    fn roundtrip_stride2_sawtooth() {
        // 16-bit LE sawtooth — realistic PCM. After delta(2), stream is all
        // the same u16 value repeated, perfect for LZMA.
        let mut data = Vec::new();
        for i in 0..2048i32 {
            let v: i16 = ((i * 17) & 0x7FFF) as i16;
            data.extend_from_slice(&v.to_le_bytes());
        }
        roundtrip(2, &data);
    }

    #[test]
    fn roundtrip_stride4_rgba() {
        // Horizontal gradient — after delta(4), per-channel constant.
        let mut data = Vec::new();
        for x in 0..1024u32 {
            data.push((x & 0xFF) as u8);        // R
            data.push(((x >> 1) & 0xFF) as u8); // G
            data.push(((x >> 2) & 0xFF) as u8); // B
            data.push(0xFF);                     // A
        }
        roundtrip(4, &data);
    }

    #[test]
    fn roundtrip_empty() {
        roundtrip(2, &[]);
    }
}
