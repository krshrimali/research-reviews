//! Config file loading + merge.

use std::sync::Mutex;

use prtui::app::Config;
use prtui::config::{apply, load, path, FileConfig};

// `load()`/`path()` read $XDG_CONFIG_HOME (process-global) — serialize the tests that set it.
static ENV_LOCK: Mutex<()> = Mutex::new(());

#[test]
fn file_config_overrides_and_extends() {
    let file: FileConfig = serde_json::from_str(
        r#"{
        "theme": "dracula",
        "claude_bin": "/custom/claude",
        "base": "develop",
        "address_test_commands": ["cargo test", "cargo clippy"],
        "protected_paths": ["vendor/", "fixtures/"],
        "commit_strategy": "per-thread",
        "saved_instructions": { "Critical review": "OVERRIDDEN", "Perf review": "focus on perf" }
    }"#,
    )
    .unwrap();

    let cfg = apply(Config::default(), &file);
    assert_eq!(cfg.claude_bin, "/custom/claude");
    assert_eq!(cfg.base, "develop");
    assert_eq!(cfg.address_test_commands, ["cargo test", "cargo clippy"]);
    assert_eq!(cfg.protected_paths, ["vendor/", "fixtures/"]);
    assert_eq!(cfg.commit_strategy, "per-thread");
    // Theme was applied globally.
    assert_eq!(prtui::theme::name(), "dracula");
    // Existing instruction overridden, new one appended.
    let map: std::collections::HashMap<_, _> = cfg.saved_instructions.iter().cloned().collect();
    assert_eq!(
        map.get("Critical review").map(String::as_str),
        Some("OVERRIDDEN")
    );
    assert_eq!(
        map.get("Perf review").map(String::as_str),
        Some("focus on perf")
    );
    assert!(
        map.contains_key("InfoSec review"),
        "built-in instruction preserved"
    );

    prtui::theme::set_by_name("github-dark"); // restore global
}

#[test]
fn missing_or_empty_config_is_default() {
    let cfg = apply(Config::default(), &FileConfig::default());
    assert_eq!(cfg.claude_bin, "claude");
    assert!(cfg
        .saved_instructions
        .iter()
        .any(|(k, _)| k == "Critical review"));
}

#[test]
fn load_reads_a_valid_file_at_the_xdg_path() {
    let _g = ENV_LOCK.lock().unwrap_or_else(|p| p.into_inner());
    let dir = std::env::temp_dir().join(format!("prtui-cfg-{}", prtui::data::store::new_uuid()));
    std::env::set_var("XDG_CONFIG_HOME", &dir);
    // path() must honor XDG_CONFIG_HOME.
    assert!(
        path().starts_with(&dir),
        "config path honors XDG_CONFIG_HOME"
    );
    std::fs::create_dir_all(dir.join("prtui")).unwrap();
    std::fs::write(
        path(),
        r#"{"claude_bin":"/x/claude","gh_bin":"/x/gh","base":"main"}"#,
    )
    .unwrap();
    let fc = load();
    assert_eq!(fc.claude_bin.as_deref(), Some("/x/claude"));
    assert_eq!(fc.gh_bin.as_deref(), Some("/x/gh"));
    std::env::remove_var("XDG_CONFIG_HOME");
}

#[test]
fn load_falls_back_to_default_on_malformed_json() {
    let _g = ENV_LOCK.lock().unwrap_or_else(|p| p.into_inner());
    let dir = std::env::temp_dir().join(format!("prtui-cfg-{}", prtui::data::store::new_uuid()));
    std::env::set_var("XDG_CONFIG_HOME", &dir);
    std::fs::create_dir_all(dir.join("prtui")).unwrap();
    std::fs::write(path(), "{ not valid json ]").unwrap();
    let fc = load(); // must not panic; returns defaults
    assert!(fc.claude_bin.is_none() && fc.gh_bin.is_none() && fc.base.is_none());
    std::env::remove_var("XDG_CONFIG_HOME");
}

#[test]
fn gh_bin_from_config_is_exported_to_env() {
    let _g = ENV_LOCK.lock().unwrap_or_else(|p| p.into_inner());
    std::env::remove_var("PRTUI_GH_BIN");
    let file = FileConfig {
        gh_bin: Some("/opt/gh".into()),
        ..Default::default()
    };
    let _ = apply(Config::default(), &file);
    assert_eq!(
        std::env::var("PRTUI_GH_BIN").ok().as_deref(),
        Some("/opt/gh")
    );
    std::env::remove_var("PRTUI_GH_BIN");
}
