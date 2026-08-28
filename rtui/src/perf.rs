//! Opt-in, low-overhead timing diagnostics.
//!
//! Set `PRTUI_PERF=1` to append timings to `$PRTUI_PERF_LOG` or
//! `/tmp/prtui-perf-<pid>.log`. Logging is disabled by default.

use std::io::Write;
use std::sync::OnceLock;
use std::time::Duration;

fn path() -> Option<&'static str> {
    static PATH: OnceLock<Option<String>> = OnceLock::new();
    PATH.get_or_init(|| {
        std::env::var_os("PRTUI_PERF").map(|_| {
            std::env::var("PRTUI_PERF_LOG")
                .unwrap_or_else(|_| format!("/tmp/prtui-perf-{}.log", std::process::id()))
        })
    })
    .as_deref()
}

pub fn record(operation: &str, elapsed: Duration) {
    let Some(path) = path() else { return };
    if let Ok(mut file) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
    {
        let _ = writeln!(
            file,
            "{} {:.3}ms",
            operation,
            elapsed.as_secs_f64() * 1000.0
        );
    }
}
