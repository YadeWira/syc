//! Progress bar mirroring zpaqfranz's `print_progress` (`zpaqfranz.cpp:63367`).
//! Three render branches, matching the three format strings there:
//!
//!  * with total + compressed counter:
//!    `(PPP%) PCT.PP% HH:MM:SS  (   X.XX MB)->(   Y.YY MB)=>(   Z.ZZ MB)   R.RR MB/s`
//!  * with total, no compressed counter:
//!    `       PCT.PP% HH:MM:SS  (   X.XX MB)=>(   Y.YY MB)    R.RR MB/s`
//!  * no total (streaming — extract/test):
//!    `          --   HH:MM:SS  (   X.XX MB)    R.RR MB/s`
//!
//! Refreshed only when the whole-second clock ticks (zpaqfranz does the same).
//! No spinner on the main line — the byte counter and clock advance every
//! second, which is visual motion enough. A spinner only appears while
//! `flushing()` is active (encoder drain with no more byte updates).
//!
//! `flushing()` spawns a background ticker so the line keeps updating elapsed
//! time while the encoder's `finish()` runs (LZMA-MT can hold the main thread
//! for tens of seconds with no upstream writes). Stop the ticker by calling
//! `finish()`.

use std::io::{IsTerminal, Write};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

/// Spinner tick while `flushing()` is active (encoder drain).
const FLUSH_TICK: Duration = Duration::from_millis(125);
const SPINNER: &[char] = &['|', '/', '-', '\\'];

pub struct Progress {
    start: Instant,
    last_second: u64,
    total: u64,
    done: u64,
    enabled: bool,
    label: &'static str,
    dirty: bool,
    flush_stop: Option<Arc<AtomicBool>>,
    flush_thread: Option<JoinHandle<()>>,
    compressed: Option<Arc<AtomicU64>>,
}

impl Progress {
    /// `label` is kept for API compatibility but no longer rendered (zpaqfranz
    /// drops it). `total = 0` means "unknown size" — percent collapses.
    pub fn new(label: &'static str, total: u64, enabled: bool) -> Self {
        Self {
            start: Instant::now(),
            last_second: u64::MAX,
            total,
            done: 0,
            enabled,
            label,
            dirty: false,
            flush_stop: None,
            flush_thread: None,
            compressed: None,
        }
    }

    /// Hand over a counter that the writer chain increments after every byte
    /// it lands on disk. With this set + `total > 0`, render switches to the
    /// `(in)->(out)=>(projection)` format (zpaqfranz `print_progress`'s rich
    /// branch). Projection extrapolates the current ratio to the full input.
    pub fn set_compressed_counter(&mut self, c: Arc<AtomicU64>) {
        self.compressed = Some(c);
    }

    pub fn advance(&mut self, n: u64) {
        self.done = self.done.saturating_add(n);
        self.render_throttled();
    }

    fn render_throttled(&mut self) {
        if !self.enabled {
            return;
        }
        // Match zpaqfranz's `td < 1000000` guard: don't render while we haven't
        // seen even 1 MB yet. Avoids the ugly 0.01% / multi-hour ETA flash on
        // startup. Streaming (total=0) paths stay live — they're usually the
        // extract/test case where the 1 MB lead-in matters less.
        if self.total > 0 && self.done < 1_000_000 {
            return;
        }
        // zpaqfranz re-renders only when the whole-second clock ticks
        // (`ultimi_secondi != secondi`). Matching that behavior avoids tearing
        // and makes cold-cache disk bursts look like clean 1 Hz updates.
        let secs = self.start.elapsed().as_secs();
        if secs == self.last_second {
            return;
        }
        self.last_second = secs;
        self.render();
    }

    fn render(&mut self) {
        let elapsed_secs = self.start.elapsed().as_secs().max(1);
        let rate_u = self.done / elapsed_secs;
        let rate_f = self.done as f64 / (elapsed_secs as f64);
        if self.total > 0 {
            // Cap done at total so a final-flush overshoot can't render > 100%.
            let done_capped = self.done.min(self.total);
            let pct = (done_capped as f64) * 100.0 / (self.total as f64);
            let pct_int = pct as u32;
            let remaining = self.total.saturating_sub(done_capped);
            let eta_secs = if rate_f > 0.0 {
                (remaining as f64 / rate_f) as u64
            } else {
                0
            };
            // zpaqfranz skips the line when ETA looks unreasonable (~4 days);
            // usually that's the first few ticks on a slow spinup. Keep the
            // previous frame on screen instead of showing "99:59:59".
            if eta_secs >= 350_000 {
                return;
            }
            let (h, m, s) = hms(eta_secs);
            if let Some(c) = &self.compressed {
                let comp = c.load(Ordering::Relaxed);
                // proj = comp * total / done : extrapolate current ratio to the
                // full input. u128 keeps the multiply from wrapping when comp
                // is huge and done is small early on.
                let proj = if done_capped > 0 {
                    ((comp as u128) * (self.total as u128) / (done_capped as u128)) as u64
                } else {
                    0
                };
                // Exact zpaqfranz format #1 (case i_percentuale > 0):
                //   "(%03d%%) %6.2f%% %02d:%02d:%02d  (%10s)->(%10s)=>(%10s) %10s/s"
                eprint!(
                    "\r({pi:03}%) {pct:6.2}% {h:02}:{m:02}:{s:02}  ({done:>10})->({comp:>10})=>({proj:>10}) {rate:>10}/s  ",
                    pi = pct_int.min(999),
                    pct = pct,
                    h = h, m = m, s = s,
                    done = human(done_capped),
                    comp = human(comp),
                    proj = human(proj),
                    rate = human(rate_u),
                );
            } else {
                // Exact zpaqfranz format #3 (base case):
                //   "       %6.2f%% %02d:%02d:%02d  (%10s)=>(%10s) %10s/s         "
                eprint!(
                    "\r       {pct:6.2}% {h:02}:{m:02}:{s:02}  ({done:>10})=>({total:>10}) {rate:>10}/s         ",
                    pct = pct,
                    h = h, m = m, s = s,
                    done = human(done_capped),
                    total = human(self.total),
                    rate = human(rate_u),
                );
            }
        } else {
            let (h, m, s) = hms(self.start.elapsed().as_secs());
            eprint!(
                "\r          --   {h:02}:{m:02}:{s:02}  ({done:>10}) {rate:>10}/s         ",
                h = h, m = m, s = s,
                done = human(self.done),
                rate = human(rate_u),
            );
        }
        let _ = std::io::stderr().flush();
        self.dirty = true;
    }

    /// Force a final render and drop to a new line. Also stops the flushing
    /// ticker if one is running.
    pub fn finish(&mut self) {
        self.stop_flushing();
        if !self.enabled {
            return;
        }
        self.render();
        eprintln!();
        self.dirty = false;
    }

    /// Switch the bar to a "flushing" indicator and spawn a background ticker
    /// that re-renders the elapsed time + spinner every 125 ms. This is what
    /// keeps the line alive while the encoder's `finish()` drains its internal
    /// buffers (LZMA MT in particular can hold the main thread for minutes).
    pub fn flushing(&mut self) {
        if !self.enabled {
            return;
        }
        self.stop_flushing();
        let stop = Arc::new(AtomicBool::new(false));
        let stop_t = Arc::clone(&stop);
        let start = self.start;
        let done = self.done;
        let comp_arc = self.compressed.clone();
        let handle = std::thread::spawn(move || {
            let mut spin = 0usize;
            while !stop_t.load(Ordering::Relaxed) {
                let (h, m, s) = hms(start.elapsed().as_secs());
                let c = SPINNER[spin % SPINNER.len()];
                // Pad to ≥ the regular render width (~82 chars) so no leftover
                // pixels from the prior `… rate/s spin   ` line bleed out the
                // right edge. Building the line then `{:<82}` is the cleanest
                // way to guarantee it.
                let line = if let Some(ca) = &comp_arc {
                    // Compressed counter keeps moving while encoder.finish()
                    // drains internal buffers — that's the whole point of
                    // showing it here.
                    let comp = ca.load(Ordering::Relaxed);
                    format!(
                        "       flushing... {h:02}:{m:02}:{s:02}  ({done})->({comp}) {c}",
                        h = h, m = m, s = s,
                        done = human(done),
                        comp = human(comp),
                        c = c,
                    )
                } else {
                    format!(
                        "       flushing... {h:02}:{m:02}:{s:02}  ({done}) {c}",
                        h = h, m = m, s = s,
                        done = human(done),
                        c = c,
                    )
                };
                eprint!("\r{:<82}", line);
                let _ = std::io::stderr().flush();
                spin = spin.wrapping_add(1);
                std::thread::sleep(FLUSH_TICK);
            }
        });
        self.flush_stop = Some(stop);
        self.flush_thread = Some(handle);
    }

    fn stop_flushing(&mut self) {
        if let Some(s) = self.flush_stop.take() {
            s.store(true, Ordering::Relaxed);
        }
        if let Some(h) = self.flush_thread.take() {
            let _ = h.join();
        }
    }
}

impl Drop for Progress {
    fn drop(&mut self) {
        self.stop_flushing();
    }
}

fn hms(secs: u64) -> (u64, u64, u64) {
    (secs / 3600, (secs / 60) % 60, secs % 60)
}

fn human(bytes: u64) -> String {
    const UNITS: &[&str] = &[" B", "KB", "MB", "GB", "TB", "PB"];
    let mut v = bytes as f64;
    let mut i = 0;
    while v >= 1024.0 && i < UNITS.len() - 1 {
        v /= 1024.0;
        i += 1;
    }
    format!("{:>7.2} {}", v, UNITS[i])
}

/// Enable progress by default when stderr is interactive.
pub fn stderr_is_tty() -> bool {
    std::io::stderr().is_terminal()
}
