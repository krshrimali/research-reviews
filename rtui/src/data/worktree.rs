//! Managed git worktrees, so a file can be opened as it existed at a specific commit
//! (e.g. a PR head that isn't checked out locally).

use std::path::PathBuf;
use std::time::{Duration, SystemTime};

use super::proc;

fn wt_root(repo_root: &str) -> PathBuf {
    let (_, common, _) = proc::git(&["rev-parse", "--git-common-dir"], Some(repo_root));
    let common = PathBuf::from(common.trim());
    let common = if common.is_absolute() {
        common
    } else {
        PathBuf::from(repo_root).join(common)
    };
    common.join("prtui").join("worktrees")
}

/// Remove managed worktrees older than `max_age`. Only paths directly below this
/// repository's private `.git/prtui/worktrees` directory are eligible.
pub fn cleanup(repo_root: &str, max_age: Duration) -> Result<usize, String> {
    let root = wt_root(repo_root);
    let (_, porcelain, _) = proc::git(&["worktree", "list", "--porcelain"], Some(repo_root));
    let locked: std::collections::HashSet<PathBuf> = porcelain
        .split("\n\n")
        .filter(|block| block.lines().any(|line| line.starts_with("locked")))
        .filter_map(|block| {
            block
                .lines()
                .find_map(|line| line.strip_prefix("worktree ").map(PathBuf::from))
        })
        .collect();
    let Ok(entries) = std::fs::read_dir(&root) else {
        return Ok(0);
    };
    let now = SystemTime::now();
    let mut removed = 0;
    for entry in entries.flatten() {
        let path = entry.path();
        if path.parent() != Some(root.as_path()) || !path.is_dir() || locked.contains(&path) {
            continue;
        }
        let modified = entry.metadata().and_then(|m| m.modified()).ok();
        let old_enough = modified
            .and_then(|m| now.duration_since(m).ok())
            .is_some_and(|age| age >= max_age);
        if !old_enough {
            continue;
        }
        let path_s = path.to_string_lossy().to_string();
        let (ok, _, err) = proc::git(&["worktree", "remove", "--force", &path_s], Some(repo_root));
        if ok {
            removed += 1;
        } else {
            return Err(err);
        }
    }
    proc::git(&["worktree", "prune"], Some(repo_root));
    Ok(removed)
}

/// Ensure a detached worktree exists at `sha`; return its path. Reuses an existing one.
pub fn ensure(repo_root: &str, sha: &str) -> Result<PathBuf, String> {
    ensure_at(repo_root, sha, None, None)
}

/// Create an isolated worktree for a mutating task. Unlike `ensure`, this never shares a
/// checkout with read-only editor views or another Claude session.
pub fn ensure_task(repo_root: &str, sha: &str, task_id: &str) -> Result<PathBuf, String> {
    ensure_at(repo_root, sha, Some(task_id), None)
}

pub fn ensure_task_in(
    repo_root: &str,
    sha: &str,
    task_id: &str,
    root: PathBuf,
) -> Result<PathBuf, String> {
    ensure_at(repo_root, sha, Some(task_id), Some(root))
}

fn ensure_at(
    repo_root: &str,
    sha: &str,
    task_id: Option<&str>,
    root: Option<PathBuf>,
) -> Result<PathBuf, String> {
    let full = super::git::rev_parse(sha, Some(repo_root))
        .ok_or_else(|| format!("unknown commit: {sha}"))?;
    let leaf = match task_id {
        Some(id) => format!(
            "{}-{}",
            &full[..full.len().min(12)],
            id.chars()
                .filter(|c| c.is_ascii_alphanumeric())
                .take(12)
                .collect::<String>()
        ),
        None => full[..full.len().min(12)].to_string(),
    };
    let path = root.unwrap_or_else(|| wt_root(repo_root)).join(leaf);
    // Already registered at this path?
    let (ok, list, _) = proc::git(&["worktree", "list", "--porcelain"], Some(repo_root));
    if ok
        && list.lines().any(|l| {
            l.strip_prefix("worktree ")
                .map(|p| p == path.to_string_lossy())
                .unwrap_or(false)
        })
    {
        return Ok(path);
    }
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(parent, std::fs::Permissions::from_mode(0o700));
        }
    }
    let path_s = path.to_string_lossy().to_string();
    let add = |force: bool| {
        let mut args = vec!["worktree", "add", "--detach"];
        if force {
            args.push("--force");
        }
        args.push(&path_s);
        args.push(&full);
        proc::git(&args, Some(repo_root))
    };
    let (ok, _, err) = add(path.exists());
    if ok {
        return Ok(path);
    }
    // A stale directory from a killed run (not registered with git, and the porcelain
    // path check can miss it if the cache path is symlinked). Prune + remove + retry.
    proc::git(&["worktree", "prune"], Some(repo_root));
    let _ = std::fs::remove_dir_all(&path);
    let (ok2, _, err2) = add(false);
    if ok2 {
        Ok(path)
    } else {
        Err(if err2.trim().is_empty() { err } else { err2 })
    }
}
