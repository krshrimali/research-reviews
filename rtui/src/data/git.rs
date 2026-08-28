//! Git queries for review data.

use super::proc;

fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

pub fn gh_credential_helper() -> String {
    let gh = std::env::var("PRTUI_GH_BIN").unwrap_or_else(|_| "gh".into());
    format!(
        "credential.helper=!{} auth git-credential",
        shell_quote(&gh)
    )
}

fn command_error(out: String, err: String, fallback: &str) -> String {
    let message = if err.trim().is_empty() { out } else { err };
    let message = message.trim();
    if message.is_empty() {
        fallback.into()
    } else {
        // Keep authentication/SSO guidance, which is commonly printed after line one,
        // while bounding what a modal/status buffer has to retain.
        message.chars().take(8192).collect()
    }
}

#[derive(Debug, Clone)]
pub struct Commit {
    pub sha: String,
    pub short: String,
    pub subject: String,
    pub body: String,
    pub author: String,
    pub date: String,
}

#[derive(Debug, Clone)]
pub struct ChangedFile {
    pub path: String,
    pub status: String, // added|modified|deleted|renamed
    pub additions: u32,
    pub deletions: u32,
    pub old_path: Option<String>,
}

pub fn root(cwd: Option<&str>) -> Option<String> {
    let (ok, out, _) = proc::git(&["rev-parse", "--show-toplevel"], cwd);
    ok.then(|| out.trim().to_string())
}

pub fn current_branch(cwd: Option<&str>) -> Option<String> {
    let (ok, out, _) = proc::git(&["symbolic-ref", "--quiet", "--short", "HEAD"], cwd);
    ok.then(|| out.trim().to_string())
}

pub fn default_branch(cwd: Option<&str>) -> String {
    let (ok, out, _) = proc::git(&["symbolic-ref", "refs/remotes/origin/HEAD"], cwd);
    if ok {
        let r = out.trim();
        if let Some(short) = r.strip_prefix("refs/remotes/") {
            return short.to_string();
        }
    }
    for name in ["origin/main", "origin/master"] {
        if proc::git(&["rev-parse", "--verify", "--quiet", name], cwd).0 {
            return name.to_string();
        }
    }
    "origin/main".to_string()
}

pub fn rev_parse(rev: &str, cwd: Option<&str>) -> Option<String> {
    let (ok, out, _) = proc::git(&["rev-parse", rev], cwd);
    ok.then(|| out.trim().to_string())
}

pub fn merge_base(a: &str, b: &str, cwd: Option<&str>) -> Option<String> {
    let (ok, out, _) = proc::git(&["merge-base", "--end-of-options", a, b], cwd);
    if ok {
        let s = out.trim().to_string();
        (!s.is_empty()).then_some(s)
    } else {
        None
    }
}

pub fn commits(base: &str, head: &str, cwd: Option<&str>) -> Vec<Commit> {
    let range = format!("{base}..{head}");
    let fmt = "--format=%H\x1f%h\x1f%s\x1f%b\x1f%an\x1f%aI\x1e";
    let (ok, out, _) = proc::git(&["log", fmt, &range], cwd);
    if !ok {
        return vec![];
    }
    let mut result = vec![];
    for record in out.split('\x1e') {
        let rec = record.trim();
        if rec.is_empty() {
            continue;
        }
        let f: Vec<&str> = rec.split('\x1f').collect();
        if f.len() >= 6 && !f[0].is_empty() {
            result.push(Commit {
                sha: f[0].to_string(),
                short: f[1].to_string(),
                subject: f[2].to_string(),
                body: f[3].trim().to_string(),
                author: f[4].to_string(),
                date: f[5].to_string(),
            });
        }
    }
    result
}

pub fn changed_files(base: &str, head: &str, cwd: Option<&str>) -> Vec<ChangedFile> {
    let range = format!("{base}...{head}");
    let (ok, name_out, _) = proc::git(&["diff", "--name-status", "-z", "-M", &range], cwd);
    if !ok {
        return vec![];
    }
    let mut files: Vec<ChangedFile> = vec![];
    let mut parts = name_out.split_terminator('\0');
    while let Some(st) = parts.next() {
        if st.is_empty() {
            continue;
        }
        let entry = if st.starts_with('R') || st.starts_with('C') {
            let old_path = parts.next().unwrap_or("").to_string();
            let path = parts.next().unwrap_or("").to_string();
            ChangedFile {
                path,
                status: if st.starts_with('R') {
                    "renamed"
                } else {
                    "copied"
                }
                .into(),
                additions: 0,
                deletions: 0,
                old_path: Some(old_path),
            }
        } else if st.starts_with('A') {
            ChangedFile {
                path: parts.next().unwrap_or("").to_string(),
                status: "added".into(),
                additions: 0,
                deletions: 0,
                old_path: None,
            }
        } else if st.starts_with('D') {
            ChangedFile {
                path: parts.next().unwrap_or("").to_string(),
                status: "deleted".into(),
                additions: 0,
                deletions: 0,
                old_path: None,
            }
        } else {
            ChangedFile {
                path: parts.next().unwrap_or("").to_string(),
                status: "modified".into(),
                additions: 0,
                deletions: 0,
                old_path: None,
            }
        };
        files.push(entry);
    }
    let (ok2, num_out, _) = proc::git(&["diff", "--numstat", "-z", "-M", &range], cwd);
    if ok2 {
        let mut records = num_out.split_terminator('\0');
        while let Some(record) = records.next() {
            let mut cols = record.splitn(3, '\t');
            let (Some(add), Some(del), Some(path)) = (cols.next(), cols.next(), cols.next()) else {
                continue;
            };
            // With -z, a rename record has an empty path followed by old and new path records.
            let path = if path.is_empty() {
                let _old_path = records.next();
                records.next().unwrap_or("")
            } else {
                path
            };
            if let Some(e) = files.iter_mut().find(|e| e.path == path) {
                e.additions = add.parse().unwrap_or(0);
                e.deletions = del.parse().unwrap_or(0);
            }
        }
    }
    files
}

pub fn file_diff(base: &str, head: &str, path: &str, cwd: Option<&str>) -> String {
    file_diff_ctx(base, head, path, 3, cwd)
}

/// File diff with a specific number of context lines (`-U<ctx>`) — used to expand context.
pub fn file_diff_ctx(base: &str, head: &str, path: &str, ctx: usize, cwd: Option<&str>) -> String {
    let range = format!("{base}...{head}");
    let uarg = format!("-U{ctx}");
    let (ok, out, _) = proc::git(&["diff", &uarg, &range, "--", path], cwd);
    if ok {
        out
    } else {
        String::new()
    }
}

pub fn full_diff(base: &str, head: &str, cwd: Option<&str>) -> String {
    let range = format!("{base}...{head}");
    let (ok, out, _) = proc::git(&["diff", &range], cwd);
    if ok {
        out
    } else {
        String::new()
    }
}

/// Fetch only the selected GitHub PR and its base over HTTPS. Authentication is delegated
/// to the already-configured `gh` CLI, and prompts are disabled so a background fetch can
/// never steal the terminal from the TUI (notably for encrypted SSH keys).
pub fn fetch_pr(
    repo_url: &str,
    number: u64,
    base_ref: &str,
    cwd: Option<&str>,
) -> Result<(), String> {
    let pr_ref = format!("+refs/pull/{number}/head:refs/prtui/pull/{number}/head");
    let base_refspec = format!("+refs/heads/{base_ref}:refs/prtui/pull/{number}/base");
    let helper = gh_credential_helper();
    let argv = [
        "git",
        "-c",
        "credential.helper=",
        "-c",
        &helper,
        "fetch",
        "--quiet",
        "--no-tags",
        repo_url,
        &pr_ref,
        &base_refspec,
    ];
    let (ok, out, err) = proc::run_stdin_env(
        &argv,
        cwd,
        None,
        &[
            ("GIT_TERMINAL_PROMPT", "0"),
            ("GIT_SSH_COMMAND", "ssh -o BatchMode=yes"),
        ],
    );
    if ok {
        Ok(())
    } else {
        Err(command_error(out, err, "git fetch failed"))
    }
}

pub fn push_head_github(repo_url: &str, branch: &str, cwd: Option<&str>) -> Result<(), String> {
    let refspec = format!("HEAD:refs/heads/{branch}");
    let helper = gh_credential_helper();
    let argv = [
        "git",
        "-c",
        "credential.helper=",
        "-c",
        &helper,
        "push",
        repo_url,
        &refspec,
    ];
    let (ok, out, err) = proc::run_stdin_env(
        &argv,
        cwd,
        None,
        &[
            ("GIT_TERMINAL_PROMPT", "0"),
            ("GIT_SSH_COMMAND", "ssh -o BatchMode=yes"),
        ],
    );
    if ok {
        Ok(())
    } else {
        Err(command_error(out, err, "push failed"))
    }
}

pub fn github_https_url(host: &str, owner: &str, repo: &str) -> String {
    let host = host.trim().trim_end_matches('/');
    format!("https://{host}/{owner}/{repo}.git")
}

pub fn push_head_origin(branch: &str, cwd: Option<&str>) -> Result<(), String> {
    let refspec = format!("HEAD:refs/heads/{branch}");
    let (ok, out, err) = proc::run_stdin_env(
        &["git", "push", "origin", &refspec],
        cwd,
        None,
        &[
            ("GIT_TERMINAL_PROMPT", "0"),
            ("GIT_SSH_COMMAND", "ssh -o BatchMode=yes"),
        ],
    );
    if ok {
        Ok(())
    } else {
        Err(command_error(out, err, "push failed"))
    }
}

/// Unified diff for a single commit (`git show <sha>`).
pub fn commit_diff(sha: &str, cwd: Option<&str>) -> String {
    let (ok, out, _) = proc::git(&["show", "--format=", sha], cwd);
    if ok {
        out
    } else {
        String::new()
    }
}
