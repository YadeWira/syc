//! Progress bar inspired by zpaqfranz: `PPP% HH:MM:SS (done) of (total) rate/s`
//! printed to stderr on a single line, refreshed at up to 4 Hz, cleared with a
//! newline on `finish`. Auto-disabled when stderr isn't a TTY.
//!
//! When `total == 0` (e.g. extract/test streams — we don't know the total up
//! front because syc has no central index), the bar drops percent + ETA and
//! prints `HH:MM:SS (done) rate/s` instead.

use std::io::{IsTerminal, Write};
use std::time::{Duration, Instant};

const MIN_INTERVAL: Duration = Duration::from_millis(250);

pub struct Progress {
    start: Instant,
    last_print: Instant,
    total: u64,
    done: u64,
    enabled: bool,
    label: &'static str,
    dirty: bool,
}

impl Progress {
    /// `label` is a short prefix (e.g. `"pack"` / `"extract"`). `total=0` means
    /// "unknown size" — percent and ETA are omitted.
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
        self.render();
    }

    fn render(&mut self) {
        let elapsed = self.start.elapsed().as_secs_f64().max(0.001);
        let rate = self.done as f64 / elapsed;
        let rate_u = rate as u64;
        if self.total > 0 {
            let pct = ((self.done.min(self.total)) * 100 / self.total) as u32;
            let remaining = self.total.saturating_sub(self.done);
            let eta_secs = if rate > 0.0 {
                (remaining as f64 / rate) as u64
            } else {
                0
            };
            let (h, m, s) = hms(eta_secs);
            eprint!(
                "\r{label} {pct:>3}% {h:02}:{m:02}:{s:02}  {done}  of  {total}  {rate}/s   ",
                label = self.label,
                pct = pct,
                h = h,
                m = m,
                s = s,
                done = human(self.done),
                total = human(self.total),
                rate = human(rate_u),
            );
        } else {
            let (h, m, s) = hms(self.start.elapsed().as_secs());
            eprint!(
                "\r{label}       {h:02}:{m:02}:{s:02}  {done}  {rate}/s   ",
                label = self.label,
                h = h,
                m = m,
                s = s,
                done = human(self.done),
                rate = human(rate_u),
            );
        }
        let _ = std::io::stderr().flush();
        self.dirty = true;
    }

    /// Force a final render and drop to a new line.
    pub fn finish(&mut self) {
        if !self.enabled {
            return;
        }
        self.render();
        eprintln!();
        self.dirty = false;
    }

    /// Overwrite the current progress line with a "flushing..." hint so the
    /// user can tell the compressor is still working after the counter hits
    /// 100%. LZMA multi-thread finish() can take tens of seconds on a big
    /// archive — without this the bar appears frozen.
    pub fn flushing(&mut self) {
        if !self.enabled {
            return;
        }
        let (h, m, s) = hms(self.start.elapsed().as_secs());
        eprint!(
            "\r{label} flushing... {h:02}:{m:02}:{s:02}  {done}                              ",
            label = self.label,
            h = h, m = m, s = s,
            done = human(self.done),
        );
        let _ = std::io::stderr().flush();
        self.dirty = true;
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
