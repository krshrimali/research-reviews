//! Source: a PR and a local branch expose the same shape.

use super::git::{ChangedFile, Commit};
use super::{gh, git};

#[derive(Debug, Clone, Default)]
pub struct Caps {
    pub has_threads: bool,
    pub has_reviewers: bool,
    pub has_checks: bool,
    pub can_submit: bool,
}

#[derive(Debug, Clone)]
pub struct GhThread {
    pub id: String,
    pub resolved: bool,
    pub outdated: bool,
    pub path: String,
    pub line: i64,
    pub side: String,
    pub comments: Vec<GhComment>,
}

#[derive(Debug, Clone)]
pub struct GhComment {
    pub id: String,
    pub author: String,
    pub body: String,
    pub created_at: String,
}

/// A submitted PR review (approved / changes_requested / commented), for the timeline.
#[derive(Debug, Clone)]
pub struct Review {
    pub author: String,
    pub state: String,
    pub date: String,
    pub body: String,
}

pub struct Source {
    pub kind: &'static str, // "branch" | "pr"
    pub repo_root: String,
    pub base_sha: String,
    pub head_sha: String,
    pub head_ref: String,
    pub key: String,
    pub title: String,
    pub description: String,
    pub author: String,
    pub updated_at: String,
    pub caps: Caps,
    pub commits: Vec<Commit>,
    pub files: Vec<ChangedFile>,
    pub reviewers: Vec<String>,
    pub checks: Vec<(String, String)>, // (name, state)
    pub threads: Vec<GhThread>,
    pub review_decision: String,
    pub reviews: Vec<Review>,
    /// GitHub or GitHub Enterprise hostname for PR sources.
    pub github_host: String,
    /// HTTPS endpoint for fetching the base repository.
    pub github_repo_url: String,
    /// HTTPS endpoint and coordinates of the PR head repository (different for forks).
    pub github_head_url: String,
    pub github_head_owner: String,
    pub github_head_repo: String,
}

impl Source {
    /// (owner, repo, number) for a PR source, parsed from either legacy or host-qualified keys.
    pub fn pr_coords(&self) -> Option<(String, String, u64)> {
        let rest = self.key.strip_prefix("gh:")?;
        let (slug, num) = rest.split_once('#')?;
        let mut parts = slug.rsplit('/');
        let repo = parts.next()?;
        let owner = parts.next()?;
        Some((owner.to_string(), repo.to_string(), num.parse().ok()?))
    }

    pub fn legacy_pr_key(&self) -> Option<String> {
        let (owner, repo, number) = self.pr_coords()?;
        (!self.github_host.is_empty()).then(|| format!("gh:{owner}/{repo}#{number}"))
    }
}

fn short_hash(s: &str) -> String {
    let mut h: u32 = 2166136261;
    for b in s.bytes() {
        h ^= b as u32;
        h = h.wrapping_mul(16777619);
    }
    format!("{h:08x}")
}

impl Source {
    pub fn local(cwd: &str, base: Option<&str>, branch: Option<&str>) -> Result<Source, String> {
        let root = git::root(Some(cwd)).ok_or("not inside a git repository")?;
        let branch = branch
            .map(|s| s.to_string())
            .or_else(|| git::current_branch(Some(&root)))
            .unwrap_or_else(|| "HEAD".into());
        // A picker-selected branch may not be checked out. Resolve that branch directly so
        // refreshes and edit worktrees always target its latest commit, not the process CWD's
        // unrelated HEAD.
        let head = git::rev_parse(&branch, Some(&root)).ok_or("cannot resolve branch head")?;
        let (base_sha, base_ref) = match base {
            Some(b) if b != "auto" => {
                let r = git::rev_parse(b, Some(&root))
                    .ok_or(format!("cannot resolve base ref: {b}"))?;
                (r, b.to_string())
            }
            _ => {
                let default = git::default_branch(Some(&root));
                let mb = git::merge_base(&head, &default, Some(&root))
                    .or_else(|| git::rev_parse(&default, Some(&root)))
                    .unwrap_or_else(|| head.clone());
                (mb.clone(), mb)
            }
        };
        let commits = git::commits(&base_sha, &head, Some(&root));
        let files = git::changed_files(&base_sha, &head, Some(&root));
        let key = format!("local:{}/{}", short_hash(&root), branch);
        Ok(Source {
            kind: "branch",
            title: format!("{branch}  (local branch)"),
            description: format!(
                "{} commit(s) ahead of base {}.",
                commits.len(),
                base_ref.chars().take(12).collect::<String>()
            ),
            author: std::env::var("USER").unwrap_or_else(|_| "you".into()),
            updated_at: commits.first().map(|c| c.date.clone()).unwrap_or_default(),
            caps: Caps::default(),
            base_sha,
            head_sha: head,
            head_ref: branch.clone(),
            repo_root: root,
            key,
            commits,
            files,
            reviewers: vec![],
            checks: vec![],
            threads: vec![],
            review_decision: String::new(),
            reviews: vec![],
            github_host: String::new(),
            github_repo_url: String::new(),
            github_head_url: String::new(),
            github_head_owner: String::new(),
            github_head_repo: String::new(),
        })
    }

    pub fn pr(number: u64, cwd: &str) -> Result<Source, String> {
        let root = git::root(Some(cwd)).ok_or("not inside a git repository")?;
        if !gh::available() {
            return Err("gh CLI not available".into());
        }
        let identity =
            gh::repo_identity(Some(&root)).ok_or("cannot determine GitHub repository host")?;
        let host = identity.host.clone();
        let owner = identity.owner.clone();
        let repo = identity.repo.clone();
        let pr = gh::pr_view(number, Some(&root)).ok_or("gh pr view failed")?;
        let base_ref_name = pr["baseRefName"].as_str().unwrap_or("main");
        let fetch_error =
            git::fetch_pr(&identity.transport_url, number, base_ref_name, Some(&root)).err();

        let head = pr["headRefOid"].as_str().unwrap_or("").to_string();
        let head_ref = pr["headRefName"].as_str().unwrap_or("HEAD").to_string();
        let base_ref_oid = pr["baseRefOid"].as_str().unwrap_or("").to_string();
        let base = git::merge_base(&base_ref_oid, &head, Some(&root)).unwrap_or(base_ref_oid);

        let commits = git::commits(&base, &head, Some(&root));
        let files = git::changed_files(&base, &head, Some(&root));
        if (commits.is_empty() && files.is_empty()) && fetch_error.is_some() {
            return Err(format!(
                "cannot fetch PR #{number} without prompting: {}",
                fetch_error.unwrap_or_default()
            ));
        }

        let mut reviewers = vec![];
        if let Some(arr) = pr["reviewRequests"].as_array() {
            for r in arr {
                if let Some(l) = r["login"].as_str() {
                    reviewers.push(l.to_string());
                }
            }
        }
        let mut reviews = vec![];
        if let Some(arr) = pr["reviews"].as_array() {
            for r in arr {
                if let Some(l) = r["author"]["login"].as_str() {
                    let state = r["state"].as_str().unwrap_or("").to_string();
                    reviewers.push(format!("{l} ({state})"));
                    reviews.push(Review {
                        author: l.to_string(),
                        state,
                        date: r["submittedAt"].as_str().unwrap_or("").to_string(),
                        body: r["body"].as_str().unwrap_or("").to_string(),
                    });
                }
            }
        }
        let mut checks = vec![];
        if let Some(arr) = pr["statusCheckRollup"].as_array() {
            for c in arr {
                let name = c["name"]
                    .as_str()
                    .or(c["context"].as_str())
                    .unwrap_or("check");
                let state = c["state"]
                    .as_str()
                    .or(c["conclusion"].as_str())
                    .unwrap_or("");
                checks.push((name.to_string(), state.to_string()));
            }
        }

        let raw = gh::review_threads(&owner, &repo, number, Some(&root));
        let mut threads = vec![];
        for t in raw {
            let mut comments = vec![];
            if let Some(nodes) = t.pointer("/comments/nodes").and_then(|n| n.as_array()) {
                for cm in nodes {
                    comments.push(GhComment {
                        id: cm["id"].as_str().unwrap_or("").to_string(),
                        author: cm["author"]["login"]
                            .as_str()
                            .unwrap_or("github")
                            .to_string(),
                        body: cm["body"].as_str().unwrap_or("").to_string(),
                        created_at: cm["createdAt"].as_str().unwrap_or("").to_string(),
                    });
                }
            }
            threads.push(GhThread {
                id: t["id"].as_str().unwrap_or("").to_string(),
                resolved: t["isResolved"].as_bool().unwrap_or(false),
                outdated: t["isOutdated"].as_bool().unwrap_or(false),
                path: t["path"].as_str().unwrap_or("").to_string(),
                line: t["line"]
                    .as_i64()
                    .or(t["originalLine"].as_i64())
                    .unwrap_or(1),
                side: t["diffSide"].as_str().unwrap_or("RIGHT").to_string(),
                comments,
            });
        }

        let head_identity = gh::pr_head_identity(&pr, &identity);
        // Include the host so identically named public and Enterprise PRs cannot share state.
        let key = format!("gh:{host}/{owner}/{repo}#{number}");
        Ok(Source {
            kind: "pr",
            title: format!("#{number}  {}", pr["title"].as_str().unwrap_or("")),
            description: pr["body"].as_str().unwrap_or("").to_string(),
            author: pr["author"]["login"]
                .as_str()
                .unwrap_or("unknown")
                .to_string(),
            updated_at: pr["updatedAt"].as_str().unwrap_or("").to_string(),
            caps: Caps {
                has_threads: true,
                has_reviewers: true,
                has_checks: true,
                can_submit: true,
            },
            base_sha: base,
            head_sha: head,
            head_ref,
            repo_root: root,
            key,
            commits,
            files,
            reviewers,
            checks,
            threads,
            review_decision: pr["reviewDecision"].as_str().unwrap_or("").to_string(),
            reviews,
            github_host: host.clone(),
            github_repo_url: identity.transport_url,
            github_head_url: head_identity.transport_url,
            github_head_owner: head_identity.owner,
            github_head_repo: head_identity.repo,
        })
    }
}
