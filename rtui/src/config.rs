//! User configuration loaded from `~/.config/prtui/config.json` (JSON because the `toml`
//! crate isn't available offline). All fields are optional and merged over the defaults;
//! command-line flags still win over the file.

use std::collections::BTreeMap;
use std::path::PathBuf;

use serde::Deserialize;

use crate::app::Config;

#[derive(Deserialize, Default)]
pub struct FileConfig {
    pub theme: Option<String>,
    pub claude_bin: Option<String>,
    /// Override the `gh` binary (exported to `$PRTUI_GH_BIN`, which `data::gh` reads).
    pub gh_bin: Option<String>,
    pub base: Option<String>,
    #[serde(default)]
    pub saved_instructions: BTreeMap<String, String>,
    #[serde(default)]
    pub address_test_commands: Vec<String>,
    #[serde(default)]
    pub protected_paths: Vec<String>,
    pub commit_strategy: Option<String>,
}

/// Path to the config file, honoring `$XDG_CONFIG_HOME`.
pub fn path() -> PathBuf {
    let base = std::env::var("XDG_CONFIG_HOME")
        .unwrap_or_else(|_| format!("{}/.config", std::env::var("HOME").unwrap_or_default()));
    PathBuf::from(base).join("prtui").join("config.json")
}

/// Load the config file (or defaults if missing/invalid).
pub fn load() -> FileConfig {
    match std::fs::read_to_string(path()) {
        Ok(text) => serde_json::from_str(&text).unwrap_or_default(),
        Err(_) => FileConfig::default(),
    }
}

/// Apply a FileConfig onto a Config: sets the theme, and fills claude_bin/base/instructions
/// where the file provides them. Returns the merged Config. CLI overrides are applied by the
/// caller afterwards.
pub fn apply(mut cfg: Config, file: &FileConfig) -> Config {
    if let Some(theme) = &file.theme {
        crate::theme::set_by_name(theme);
    }
    if let Some(bin) = &file.claude_bin {
        cfg.claude_bin = bin.clone();
    }
    if let Some(bin) = &file.gh_bin {
        std::env::set_var("PRTUI_GH_BIN", bin);
    }
    if let Some(base) = &file.base {
        cfg.base = base.clone();
    }
    // File instructions extend/override the built-in ones (file wins on a key match).
    for (k, v) in &file.saved_instructions {
        if let Some(existing) = cfg
            .saved_instructions
            .iter_mut()
            .find(|(name, _)| name == k)
        {
            existing.1 = v.clone();
        } else {
            cfg.saved_instructions.push((k.clone(), v.clone()));
        }
    }
    if !file.address_test_commands.is_empty() {
        cfg.address_test_commands = file.address_test_commands.clone();
    }
    if !file.protected_paths.is_empty() {
        cfg.protected_paths = file.protected_paths.clone();
    }
    if let Some(v) = &file.commit_strategy {
        cfg.commit_strategy = v.clone();
    }
    cfg
}
