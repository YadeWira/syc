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
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};

static ENABLED: AtomicBool = AtomicBool::new(false);
/// Global, monotonically-increasing error counter. zpaqfranz prefixes every
/// error line with a zero-padded 5-digit count + `!`, so users can eyeball
/// how many fault lines scrolled by without counting them manually. Wraps
/// back to 0 at u32::MAX, which in practice never happens.
static ERR_COUNT: AtomicU32 = AtomicU32::new(0);

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

/// Increment the global error counter and return a zpaqfranz-style red
/// prefixed error line: `00042! {msg}`. The counter ticks even when color is
/// off — only the ANSI wrapping is gated.
pub fn err_line(msg: &str) -> String {
    let n = ERR_COUNT.fetch_add(1, Ordering::Relaxed) + 1;
    let body = format!("{:05}! {}", n, msg);
    if enabled() {
        format!("{}{}{}", RED, body, RESET)
    } else {
        body
    }
}

pub fn err_count() -> u32 { ERR_COUNT.load(Ordering::Relaxed) }
