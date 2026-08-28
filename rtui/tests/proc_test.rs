use prtui::data::proc;
use std::sync::Mutex;

static PROC_LOCK: Mutex<()> = Mutex::new(());

#[test]
fn stdin_and_large_stdout_do_not_deadlock() {
    let _guard = PROC_LOCK.lock().unwrap_or_else(|p| p.into_inner());
    let input = "x".repeat(256 * 1024);
    let script = "dd if=/dev/zero bs=1024 count=256 2>/dev/null; wc -c";
    let (ok, out, err) = proc::run_stdin(&["sh", "-c", script], None, Some(&input));
    assert!(ok, "child failed: {err}");
    assert!(out.ends_with("262144\n"), "child did not receive all stdin");
}

#[test]
fn explicit_environment_is_passed_to_child() {
    let _guard = PROC_LOCK.lock().unwrap_or_else(|p| p.into_inner());
    let (ok, out, err) = proc::run_stdin_env(
        &["sh", "-c", "printf %s \"$PRTUI_TEST_VALUE\""],
        None,
        None,
        &[("PRTUI_TEST_VALUE", "non-interactive")],
    );
    assert!(ok, "child failed: {err}");
    assert_eq!(out, "non-interactive");
}

#[test]
fn commands_are_killed_after_the_configured_timeout() {
    let _guard = PROC_LOCK.lock().unwrap_or_else(|p| p.into_inner());
    std::env::set_var("PRTUI_COMMAND_TIMEOUT_SECS", "0");
    let (ok, _out, err) = proc::run(&["sh", "-c", "sleep 10"], None);
    std::env::remove_var("PRTUI_COMMAND_TIMEOUT_SECS");
    assert!(!ok);
    assert!(err.contains("timed out"), "{err}");
}
