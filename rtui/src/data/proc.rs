//! Process helpers — argv-style only (never a shell), so untrusted data (branch
//! names, titles, paths, comment bodies) can never be interpreted as a command.

use std::io::{Read, Write};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

/// Run a command to completion. Returns (ok, stdout, stderr).
pub fn run(argv: &[&str], cwd: Option<&str>) -> (bool, String, String) {
    run_stdin_env(argv, cwd, None, &[])
}

/// Run with optional stdin.
pub fn run_stdin(argv: &[&str], cwd: Option<&str>, stdin: Option<&str>) -> (bool, String, String) {
    run_stdin_env(argv, cwd, stdin, &[])
}

/// Run with optional stdin and explicit environment overrides.
pub fn run_stdin_env(
    argv: &[&str],
    cwd: Option<&str>,
    stdin: Option<&str>,
    env: &[(&str, &str)],
) -> (bool, String, String) {
    if argv.is_empty() {
        return (false, String::new(), "empty argv".into());
    }
    let mut cmd = Command::new(argv[0]);
    cmd.args(&argv[1..]);
    cmd.envs(env.iter().copied());
    if let Some(dir) = cwd {
        cmd.current_dir(dir);
    }
    cmd.stdin(if stdin.is_some() {
        Stdio::piped()
    } else {
        Stdio::null()
    });
    cmd.stdout(Stdio::piped());
    cmd.stderr(Stdio::piped());

    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => return (false, String::new(), e.to_string()),
    };
    let stdout = child.stdout.take().map(|mut stream| {
        std::thread::spawn(move || {
            let mut bytes = Vec::new();
            let _ = stream.read_to_end(&mut bytes);
            bytes
        })
    });
    let stderr = child.stderr.take().map(|mut stream| {
        std::thread::spawn(move || {
            let mut bytes = Vec::new();
            let _ = stream.read_to_end(&mut bytes);
            bytes
        })
    });
    let writer = match (stdin, child.stdin.take()) {
        (Some(input), Some(mut sink)) => {
            let input = input.as_bytes().to_vec();
            Some(std::thread::spawn(move || sink.write_all(&input)))
        }
        _ => None,
    };
    let timeout = std::env::var("PRTUI_COMMAND_TIMEOUT_SECS")
        .ok()
        .and_then(|v| v.parse::<u64>().ok())
        .map(Duration::from_secs)
        .unwrap_or(Duration::from_secs(60));
    let started = Instant::now();
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break Ok(status),
            Ok(None) if started.elapsed() < timeout => {
                std::thread::sleep(Duration::from_millis(20));
            }
            Ok(None) => {
                let _ = child.kill();
                let _ = child.wait();
                break Err(format!("command timed out after {}s", timeout.as_secs()));
            }
            Err(e) => break Err(e.to_string()),
        }
    };
    if let Some(writer) = writer {
        let _ = writer.join();
    }
    let out = stdout
        .and_then(|h| h.join().ok())
        .map(|b| String::from_utf8_lossy(&b).into_owned())
        .unwrap_or_default();
    let err = stderr
        .and_then(|h| h.join().ok())
        .map(|b| String::from_utf8_lossy(&b).into_owned())
        .unwrap_or_default();
    match status {
        Ok(status) => (status.success(), out, err),
        Err(timeout_or_wait) => (false, out, timeout_or_wait),
    }
}

/// Convenience for git.
pub fn git(args: &[&str], cwd: Option<&str>) -> (bool, String, String) {
    let mut argv = vec!["git"];
    argv.extend_from_slice(args);
    run(&argv, cwd)
}
