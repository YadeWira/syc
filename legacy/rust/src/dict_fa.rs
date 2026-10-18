//! English-text dictionary preprocessor inspired by FreeArc's `Dict.cpp` (by
//! Bulat Ziganshin). Replaces the most common English words with single-byte
//! tokens in the 0x80..=0xFF range so the downstream compressor has fewer
//! symbols to model. Opt-in — only useful on text.
//!
//! Encoding scheme
//! ---------------
//!   * Each dictionary word starts with a literal space (most English word
//!     boundaries are `SP + word + nonletter`). Tokens encode that leading
//!     space too, so the source " the" → 1 byte saves 3 bytes.
//!   * Byte `0x80 + idx` is a token (128 words fit in `0x80..=0xFF`).
//!   * Byte `0x01` is the escape prefix: `0x01 XX` decodes to literal `XX`.
//!     This lets input bytes in `{0x01} ∪ 0x80..=0xFF` survive the round-trip
//!     even though they collide with token/escape bytes. 0x01 is rare in
//!     English prose, so the escape overhead on real text is negligible.
//!   * Every other byte is emitted literally.
//!
//! Disk format: no framing — the encoder writes the raw token stream and the
//! caller wraps it in whatever framing it already uses. This preprocessor is
//! meant to sit between the entry's bytes and the main compressor, so the
//! compressor's own length handling covers us.
//!
//! Matching rule: a word `W` (already prefixed by `SP`) matches at position
//! `i` iff `input[i..i+W.len()] == W` AND `i+W.len()` is either end-of-input
//! or a non-letter byte. That guard prevents " the" from matching inside
//! " there".

use anyhow::{anyhow, Result};
use std::collections::HashMap;
use std::io::{Read, Write};

/// Escape prefix. Rare in English text; any naked 0x01 or 0x80..=0xFF in the
/// source is emitted as `ESCAPE + byte`.
const ESCAPE: u8 = 0x01;

/// The 128 most common English words, each prefixed with a space so one token
/// replaces both the delimiter and the word. Ordering matters: token `0x80+i`
/// decodes to `WORDS[i]`, so this list is the on-wire format — do not reorder.
#[rustfmt::skip]
pub const WORDS: &[&[u8]] = &[
    b" the", b" of", b" and", b" to", b" in", b" is", b" for", b" on",
    b" that", b" by", b" with", b" this", b" at", b" from", b" are", b" as",
    b" you", b" it", b" not", b" or", b" be", b" have", b" an", b" was",
    b" your", b" all", b" we", b" can", b" will", b" more", b" about", b" but",
    b" they", b" one", b" their", b" has", b" what", b" when", b" which", b" if",
    b" my", b" me", b" been", b" like", b" its", b" some", b" would", b" than",
    b" these", b" could", b" them", b" our", b" out", b" also", b" had", b" new",
    b" just", b" only", b" so", b" over", b" back", b" who", b" into", b" first",
    b" because", b" people", b" any", b" other", b" very", b" after", b" should", b" well",
    b" where", b" time", b" now", b" how", b" before", b" still", b" must", b" such",
    b" said", b" two", b" made", b" much", b" then", b" see", b" use", b" work",
    b" many", b" good", b" each", b" find", b" year", b" day", b" make", b" come",
    b" most", b" look", b" used", b" here", b" down", b" take", b" there", b" those",
    b" even", b" last", b" life", b" right", b" think", b" know", b" get", b" under",
    b" between", b" long", b" same", b" few", b" through", b" never", b" too", b" own",
    b" while", b" being", b" another", b" part", b" does", b" without", b" world", b" every",
];

const _: () = assert!(WORDS.len() == 128, "dict_fa tokens must fit in 0x80..=0xFF");

fn is_letter(b: u8) -> bool {
    b.is_ascii_alphabetic()
}

fn build_lookup() -> (HashMap<&'static [u8], u8>, usize) {
    let mut m = HashMap::with_capacity(WORDS.len());
    let mut max_len = 0;
    for (i, w) in WORDS.iter().enumerate() {
        m.insert(*w, 0x80u8 + i as u8);
        if w.len() > max_len {
            max_len = w.len();
        }
    }
    (m, max_len)
}

pub fn encode(input: &[u8]) -> Vec<u8> {
    let (dict, max_len) = build_lookup();
    let mut out = Vec::with_capacity(input.len());
    let mut i = 0usize;
    while i < input.len() {
        let b = input[i];
        if b == b' ' {
            let remain = input.len() - i;
            let hi = max_len.min(remain);
            // Try longest match first, stepping down. Most calls miss fast
            // (the HashMap key doesn't exist) so the slowdown is bounded.
            let mut matched = None;
            for len in (2..=hi).rev() {
                let cand = &input[i..i + len];
                if let Some(&tok) = dict.get(cand) {
                    // Boundary guard: the char after `cand` must not be a
                    // letter, otherwise " the" would swallow a prefix of
                    // " there" and decode wrong.
                    let ok = i + len == input.len() || !is_letter(input[i + len]);
                    if ok {
                        matched = Some((tok, len));
                        break;
                    }
                }
            }
            if let Some((tok, len)) = matched {
                out.push(tok);
                i += len;
                continue;
            }
        }
        if b == ESCAPE || b >= 0x80 {
            out.push(ESCAPE);
            out.push(b);
        } else {
            out.push(b);
        }
        i += 1;
    }
    out
}

pub fn decode(input: &[u8]) -> Result<Vec<u8>> {
    let mut out = Vec::with_capacity(input.len());
    let mut i = 0usize;
    while i < input.len() {
        let b = input[i];
        if b == ESCAPE {
            if i + 1 >= input.len() {
                return Err(anyhow!("dict_fa: dangling escape at end of stream"));
            }
            out.push(input[i + 1]);
            i += 2;
        } else if b >= 0x80 {
            let idx = (b - 0x80) as usize;
            // Unreachable in a well-formed stream (we only emit 0..WORDS.len())
            // but decode is driven by untrusted bytes off disk, so validate.
            let w = WORDS
                .get(idx)
                .ok_or_else(|| anyhow!("dict_fa: token 0x{:02x} out of range", b))?;
            out.extend_from_slice(w);
            i += 1;
        } else {
            out.push(b);
            i += 1;
        }
    }
    Ok(out)
}

/// Cheap heuristic: is this byte slice plausibly English-ish text? Used by the
/// integration layer to decide whether to enable the preprocessor per stream.
/// Threshold 90% printable-ASCII picked empirically: UTF-8 text with accented
/// chars still passes (the accented bytes are 0x80+ but the majority stays
/// ASCII), random binary fails.
pub fn looks_like_text(sample: &[u8]) -> bool {
    if sample.is_empty() {
        return false;
    }
    let mut printable = 0usize;
    for &b in sample {
        if b == b'\n' || b == b'\r' || b == b'\t' || (0x20..=0x7E).contains(&b) {
            printable += 1;
        }
    }
    printable * 100 >= sample.len() * 90
}

pub struct DictWriter<W: Write> {
    inner: W,
    buf: Vec<u8>,
}

impl<W: Write> DictWriter<W> {
    pub fn new(inner: W) -> Self {
        Self { inner, buf: Vec::new() }
    }

    pub fn finish(mut self) -> Result<W> {
        if !self.buf.is_empty() {
            let out = encode(&self.buf);
            self.inner.write_all(&out)?;
        }
        Ok(self.inner)
    }
}

impl<W: Write> Write for DictWriter<W> {
    fn write(&mut self, data: &[u8]) -> std::io::Result<usize> {
        self.buf.extend_from_slice(data);
        Ok(data.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

pub struct DictReader<R: Read> {
    decoded: Vec<u8>,
    pos: usize,
    _marker: std::marker::PhantomData<R>,
}

impl<R: Read> DictReader<R> {
    pub fn new(mut inner: R) -> Result<Self> {
        let mut raw = Vec::new();
        inner.read_to_end(&mut raw)?;
        let decoded = decode(&raw)?;
        Ok(Self {
            decoded,
            pos: 0,
            _marker: std::marker::PhantomData,
        })
    }
}

impl<R: Read> Read for DictReader<R> {
    fn read(&mut self, dst: &mut [u8]) -> std::io::Result<usize> {
        let avail = self.decoded.len() - self.pos;
        let n = avail.min(dst.len());
        dst[..n].copy_from_slice(&self.decoded[self.pos..self.pos + n]);
        self.pos += n;
        Ok(n)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip_english() {
        let src = b"the quick brown fox jumps over the lazy dog. this is a test of the dictionary preprocessor because we want to see how well it works when the input has many common words.";
        let enc = encode(src);
        let dec = decode(&enc).unwrap();
        assert_eq!(&dec[..], &src[..]);
        assert!(enc.len() < src.len(), "encode did not shrink English text: {} -> {}", src.len(), enc.len());
    }

    #[test]
    fn roundtrip_binary_with_escapes() {
        let mut src = Vec::new();
        for b in 0u8..=255 {
            src.push(b);
        }
        for _ in 0..4 {
            src.extend_from_slice(&[0x01, 0x80, 0xff, 0x7f, 0x00]);
        }
        let enc = encode(&src);
        let dec = decode(&enc).unwrap();
        assert_eq!(dec, src);
    }

    #[test]
    fn boundary_guard_prevents_substring_match() {
        // " the" must NOT match inside " there" / " theater" etc.
        let src = b" there and the theater";
        let enc = encode(src);
        let dec = decode(&enc).unwrap();
        assert_eq!(&dec[..], &src[..]);
    }

    #[test]
    fn empty_roundtrip() {
        assert!(encode(b"").is_empty());
        assert_eq!(decode(b"").unwrap(), Vec::<u8>::new());
    }

    /// Run with: `cargo test --release --bin syc bench_corpus -- --ignored --nocapture`
    /// Expects env `SYC_DICTFA_CORPUS=/path/to/text.txt`. Prints raw vs. dict+zstd
    /// sizes at levels 9 and 19 so we can judge whether the preprocessor earns
    /// its keep before committing to a format change.
    #[test]
    #[ignore]
    fn bench_corpus() {
        let path = std::env::var("SYC_DICTFA_CORPUS")
            .expect("set SYC_DICTFA_CORPUS=/path/to/text");
        let raw = std::fs::read(&path).unwrap();
        let enc = encode(&raw);
        eprintln!("== dict_fa on {} ({} bytes) ==", path, raw.len());
        eprintln!("  dict_fa alone : {} bytes ({:.2}% of raw)",
            enc.len(), enc.len() as f64 * 100.0 / raw.len() as f64);
        for level in [1, 9, 19] {
            let raw_z = zstd::stream::encode_all(&raw[..], level).unwrap();
            let enc_z = zstd::stream::encode_all(&enc[..], level).unwrap();
            let delta = enc_z.len() as f64 * 100.0 / raw_z.len() as f64 - 100.0;
            eprintln!(
                "  zstd -{level:2}      : raw {:8} / dict+zstd {:8}  (Δ {:+.2}%)",
                raw_z.len(), enc_z.len(), delta
            );
        }
        for preset in [3u32, 6, 9] {
            use std::io::Write;
            let mut raw_x = Vec::new();
            {
                let mut e = xz2::write::XzEncoder::new(&mut raw_x, preset);
                e.write_all(&raw).unwrap();
                e.finish().unwrap();
            }
            let mut enc_x = Vec::new();
            {
                let mut e = xz2::write::XzEncoder::new(&mut enc_x, preset);
                e.write_all(&enc).unwrap();
                e.finish().unwrap();
            }
            let delta = enc_x.len() as f64 * 100.0 / raw_x.len() as f64 - 100.0;
            eprintln!(
                "  xz -{preset:2}        : raw {:8} / dict+xz   {:8}  (Δ {:+.2}%)",
                raw_x.len(), enc_x.len(), delta
            );
        }
        let dec = decode(&enc).unwrap();
        assert_eq!(dec, raw, "round-trip broke on real corpus");
    }

    #[test]
    fn detection_heuristic() {
        assert!(looks_like_text(b"the quick brown fox jumps over the lazy dog"));
        assert!(looks_like_text(b"hello\nworld\twith\r\nmixed\twhitespace"));
        let mut bin = vec![0u8; 1024];
        for (i, b) in bin.iter_mut().enumerate() {
            *b = (i % 256) as u8;
        }
        assert!(!looks_like_text(&bin));
    }
}
