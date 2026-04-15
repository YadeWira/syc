//! Progress bar mirroring zpaqfranz's pack-mode line
//! (`zpaqfranz.cpp:63480`):
//!
//!     `       PCT.PP% HH:MM:SS  (   X.XX MB)=>(   Y.YY MB)    Z.ZZ MB/s |`
//!
//! Refreshed every 125 ms (8 Hz) on stderr — slightly faster than zpaqfranz
//! (1 Hz) so sub-second jobs feel alive. A 4-frame ASCII spinner rotates each
//! tick to confirm motion even when the byte counter looks stuck.
//!
//! When `total == 0` (extract/test streams — syc has no central index, so we
//! don't know up front), the percent slot collapses to dashes.
//!
//! `flushing()` spawns a background ticker so the line keeps updating elapsed
//! time + spinner while the encoder's `finish()` runs (LZMA-MT can hold the
//! main thread for tens of seconds with no upstream writes). Stop the ticker
//! by calling `finish()`.

use std::io::{IsTerminal, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

const MIN_INTERVAL: Duration = Duration::from_millis(125);
const SPINNER: &[char] = &['|', '/', '-', '\\'];

pub struct Progress {
    start: Instant,
    last_print: Instant,
    total: u64,
    done: u64,
    enabled: bool,
    label: &'static str,
    dirty: bool,
    spin: usize,
    flush_stop: Option<Arc<AtomicBool>>,
    flush_thread: Option<JoinHandle<()>>,
}

impl Progress {
    /// `label` is kept for API compatibility but no longer rendered (zpaqfranz
    /// drops it). `total = 0` means "unknown size" — percent collapses.
    pub fn new(label: &'static str, total: u64, enabled: bool) -> Self {
        let now = Instant::now();
        Self {
            start: now,
            last_print: now - MIN_INTERVAL,
            total,
            done: 0,
            enabled,
            label,
            dirty: false,
            spin: 0,
            flush_stop: None,
            flush_thread: None,
        }
    }

    pub fn advance(&mut self, n: u64) {
        self.done = self.done.saturating_add(n);
        self.render_throttled();
    }

    fn render_throttled(&mut self) {
        if !self.enabled {
            return;
        }
        let now = Instant::now();
        if now.duration_since(self.last_print) < MIN_INTERVAL {
            return;
        }
        self.last_print = now;
        self.spin = (self.spin + 1) % SPINNER.len();
        self.render();
    }

    fn render(&mut self) {
        let elapsed = self.start.elapsed().as_secs_f64().max(0.001);
        let rate = self.done as f64 / elapsed;
        let rate_u = rate as u64;
        let spin = SPINNER[self.spin];
        if self.total > 0 {
            let pct = (self.done.min(self.total) as f64) * 100.0 / (self.total as f64);
            let remaining = self.total.saturating_sub(self.done);
            let eta_secs = if rate > 0.0 {
                (remaining as f64 / rate) as u64
            } else {
                0
            };
            let (h, m, s) = hms(eta_secs);
            eprint!(
                "\r       {pct:6.2}% {h:02}:{m:02}:{s:02}  ({done})=>({total}) {rate}/s {spin}   ",
                pct = pct,
                h = h, m = m, s = s,
                done = human(self.done),
                total = human(self.total),
                rate = human(rate_u),
                spin = spin,
            );
        } else {
            let (h, m, s) = hms(self.start.elapsed().as_secs());
            eprint!(
                "\r          --   {h:02}:{m:02}:{s:02}  ({done}) {rate}/s {spin}   ",
                h = h, m = m, s = s,
                done = human(self.done),
                rate = human(rate_u),
                spin = spin,
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
        let handle = std::thread::spawn(move || {
            let mut spin = 0usize;
            while !stop_t.load(Ordering::Relaxed) {
                let (h, m, s) = hms(start.elapsed().as_secs());
                let c = SPINNER[spin % SPINNER.len()];
                eprint!(
                    "\r       flushing... {h:02}:{m:02}:{s:02}  ({done}) {c}                              ",
                    h = h, m = m, s = s,
                    done = human(done),
                    c = c,
                );
                let _ = std::io::stderr().flush();
                spin = spin.wrapping_add(1);
                std::thread::sleep(Duration::from_millis(125));
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
