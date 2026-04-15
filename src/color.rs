//! ANSI colors for terminal output, mirroring zpaqfranz's palette.
//!
//! zpaqfranz uses a small set of bold ANSI colors for three purposes:
//!   - bold green  — success, banner, "(all OK)", good compression tags
//!   - bold red    — errors, "(with errors)"
//!   - bold yellow — warnings, poor compression ratios
//!   - bold cyan   — section headers, info accents
//!
//! We replicate only those four. All output is gated by:
//!   - `-nocolor` / `-nc` CLI flag
//!   - `NO_COLOR` env var (honors https://no-color.org/)
//!   - whether stderr is a real TTY (most output goes to stderr)

use std::io::IsTerminal;
use std::sync::atomic::{AtomicBool, Ordering};

static ENABLED: AtomicBool = AtomicBool::new(false);

/// Initialize once at program entry. Color is enabled only when all of:
/// stderr is a TTY, `-nocolor` not set, `NO_COLOR` env var absent.
pub fn init(flag_nocolor: bool) {
    let tty = std::io::stderr().is_terminal();
    let no_color_env = std::env::var_os("NO_COLOR").is_some();
    ENABLED.store(tty && !flag_nocolor && !no_color_env, Ordering::Relaxed);
}

pub fn enabled() -> bool {
    ENABLED.load(Ordering::Relaxed)
}

pub const RESET: &str = "\x1b[0m";
pub const GREEN: &str = "\x1b[1;32m";
pub const RED: &str = "\x1b[1;31m";
pub const YELLOW: &str = "\x1b[1;33m";
#[allow(dead_code)]
pub const CYAN: &str = "\x1b[1;36m";

#[inline]
fn wrap(prefix: &str, s: &str) -> String {
    if enabled() {
        let mut out = String::with_capacity(s.len() + prefix.len() + RESET.len());
        out.push_str(prefix);
        out.push_str(s);
        out.push_str(RESET);
        out
    } else {
        s.to_string()
    }
}

pub fn g(s: &str) -> String { wrap(GREEN, s) }
pub fn r(s: &str) -> String { wrap(RED, s) }
pub fn y(s: &str) -> String { wrap(YELLOW, s) }
#[allow(dead_code)]
pub fn c(s: &str) -> String { wrap(CYAN, s) }
