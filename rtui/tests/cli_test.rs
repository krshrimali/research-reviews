use std::process::Command;

#[test]
fn help_works_without_a_tty() {
    let output = Command::new(env!("CARGO_BIN_EXE_prtui"))
        .arg("--help")
        .output()
        .expect("run prtui --help");
    assert!(output.status.success());
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("Usage: prtui"));
    assert!(stdout.contains("--cleanup-worktrees"));
}

#[test]
fn version_works_without_a_tty() {
    let output = Command::new(env!("CARGO_BIN_EXE_prtui"))
        .arg("--version")
        .output()
        .expect("run prtui --version");
    assert!(output.status.success());
    assert_eq!(
        String::from_utf8_lossy(&output.stdout).trim(),
        "prtui 0.1.0"
    );
}
