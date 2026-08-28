//! GitHub access via the `gh` CLI.

use super::proc;
use serde_json::Value;

/// The `gh` binary to invoke. Overridable via `$PRTUI_GH_BIN` (config sets this too), which
/// lets tests point at a fake `gh` — mirroring how `claude_bin` fakes the Claude CLI.
fn gh_bin() -> String {
    std::env::var("PRTUI_GH_BIN").unwrap_or_else(|_| "gh".to_string())
}

pub fn available() -> bool {
    let gh = gh_bin();
    proc::run(&[gh.as_str(), "--version"], None).0
}

/// Run a `gh pr <args>` command (merge/close/reopen/ready/edit/…). Returns Ok or the
/// gh error text.
pub fn pr_command(args: &[&str], cwd: Option<&str>) -> Result<(), String> {
    let gh = gh_bin();
    let mut argv = vec![gh.as_str(), "pr"];
    argv.extend_from_slice(args);
    let (ok, out, err) = proc::run(&argv, cwd);
    if ok {
        Ok(())
    } else {
        Err(if err.trim().is_empty() { out } else { err })
    }
}

/// Add a reaction to a comment/review node via GraphQL `addReaction`. `subject_id` is the
/// GraphQL node id (what we store as `github_id`); `name` is one of `store::REACTIONS`.
/// GitHub has no single toggle mutation, so this only *adds* — removals stay local.
pub fn react_to_comment(
    _owner: &str,
    _repo: &str,
    subject_id: &str,
    name: &str,
    cwd: Option<&str>,
) -> Result<(), String> {
    let content = match name {
        "+1" => "THUMBS_UP",
        "-1" => "THUMBS_DOWN",
        "laugh" => "LAUGH",
        "hooray" => "HOORAY",
        "confused" => "CONFUSED",
        "heart" => "HEART",
        "rocket" => "ROCKET",
        "eyes" => "EYES",
        _ => return Err(format!("unknown reaction: {name}")),
    };
    let q = format!(
        "mutation($id:ID!){{addReaction(input:{{subjectId:$id,content:{content}}}){{reaction{{content}}}}}}"
    );
    let gh = gh_bin();
    let (ok, _out, err) = proc::run(
        &[
            gh.as_str(),
            "api",
            "graphql",
            "-f",
            &format!("query={q}"),
            "-f",
            &format!("id={subject_id}"),
        ],
        cwd,
    );
    if ok {
        Ok(())
    } else {
        Err(err)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RepoIdentity {
    pub host: String,
    pub owner: String,
    pub repo: String,
    /// Authenticated HTTPS transport endpoint, preserving Enterprise URL prefixes.
    pub transport_url: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HeadIdentity {
    pub owner: String,
    pub repo: String,
    pub transport_url: String,
}

pub fn pr_head_identity(pr: &Value, base: &RepoIdentity) -> HeadIdentity {
    let owner = pr["headRepositoryOwner"]["login"]
        .as_str()
        .unwrap_or(&base.owner)
        .to_string();
    let repo = pr["headRepository"]["name"]
        .as_str()
        .unwrap_or(&base.repo)
        .to_string();
    let transport_url = pr["headRepository"]["url"]
        .as_str()
        .map(|url| format!("{}.git", url.trim_end_matches('/')))
        .unwrap_or_else(|| super::git::github_https_url(&base.host, &owner, &repo));
    HeadIdentity {
        owner,
        repo,
        transport_url,
    }
}

pub fn repo_identity(cwd: Option<&str>) -> Option<RepoIdentity> {
    let gh = gh_bin();
    let (ok, out, _) = proc::run(
        &[
            gh.as_str(),
            "repo",
            "view",
            "--json",
            "owner,name,url",
            "-q",
            "[.owner.login,.name,.url] | @tsv",
        ],
        cwd,
    );
    if !ok {
        return None;
    }
    let mut fields = out.trim().split('\t');
    let owner = fields.next()?.to_string();
    let repo = fields.next()?.to_string();
    let url = fields.next()?;
    let host = url
        .strip_prefix("https://")
        .or_else(|| url.strip_prefix("http://"))
        .and_then(|rest| rest.split('/').next())?
        .to_string();
    let transport_url = format!("{}.git", url.trim_end_matches('/'));
    Some(RepoIdentity {
        host,
        owner,
        repo,
        transport_url,
    })
}

pub fn owner_repo(cwd: Option<&str>) -> Option<(String, String)> {
    repo_identity(cwd).map(|id| (id.owner, id.repo))
}

/// Lightweight PR records for the picker.
pub fn list_prs(cwd: Option<&str>) -> Vec<Value> {
    list_prs_with_state(cwd, "open")
}

/// Lightweight PR records for the picker, including closed/merged PRs when
/// `state` is `all`.
pub fn list_prs_with_state(cwd: Option<&str>, state: &str) -> Vec<Value> {
    let gh = gh_bin();
    let (ok, out, _) = proc::run(
        &[
            gh.as_str(),
            "pr",
            "list",
            "--json",
            "number,title,author,state,isDraft,updatedAt,reviewDecision,labels,\
headRefName,baseRefName,assignees",
            "--limit",
            "200",
            "--state",
            state,
        ],
        cwd,
    );
    if !ok {
        return vec![];
    }
    serde_json::from_str::<Vec<Value>>(&out).unwrap_or_default()
}

pub fn pr_view(number: u64, cwd: Option<&str>) -> Option<Value> {
    let fields = "number,title,body,author,state,updatedAt,headRefName,baseRefName,\
headRefOid,baseRefOid,headRepository,headRepositoryOwner,isCrossRepository,labels,assignees,\
reviewRequests,reviews,reviewDecision,statusCheckRollup";
    let n = number.to_string();
    let gh = gh_bin();
    let (ok, out, _) = proc::run(&[gh.as_str(), "pr", "view", &n, "--json", fields], cwd);
    if !ok {
        return None;
    }
    serde_json::from_str::<Value>(&out).ok()
}

const THREADS_QUERY: &str = r#"
query($owner:String!, $repo:String!, $number:Int!) {
  repository(owner:$owner, name:$repo) {
    pullRequest(number:$number) {
      reviewThreads(first:100) { nodes {
        id isResolved isOutdated path line originalLine diffSide
        comments(first:100) { nodes {
          id author { login } body createdAt path originalLine line
        } }
      } }
    }
  }
}"#;

/// Submit a PR review (create-review REST endpoint) with a JSON payload on stdin.
/// Returns the response JSON on success, or the gh error text.
pub fn submit_review(
    owner: &str,
    repo: &str,
    number: u64,
    payload: &str,
    cwd: Option<&str>,
) -> Result<Value, String> {
    let path = format!("repos/{owner}/{repo}/pulls/{number}/reviews");
    let gh = gh_bin();
    let (ok, out, err) = proc::run_stdin(
        &[
            gh.as_str(),
            "api",
            &path,
            "--method",
            "POST",
            "--input",
            "-",
        ],
        cwd,
        Some(payload),
    );
    if ok {
        serde_json::from_str(&out).map_err(|e| format!("bad response JSON: {e}"))
    } else {
        Err(if err.trim().is_empty() { out } else { err })
    }
}

/// Reply to an existing review thread (GraphQL). `thread_id` is the thread node id.
/// Returns the new comment's node id so the local mirror can dedupe on re-import.
pub fn reply_to_thread(thread_id: &str, body: &str, cwd: Option<&str>) -> Result<String, String> {
    let q = "mutation($tid:ID!,$body:String!){addPullRequestReviewThreadReply(input:{pullRequestReviewThreadId:$tid,body:$body}){comment{id}}}";
    let gh = gh_bin();
    let (ok, out, err) = proc::run(
        &[
            gh.as_str(),
            "api",
            "graphql",
            "-f",
            &format!("query={q}"),
            "-f",
            &format!("tid={thread_id}"),
            "-f",
            &format!("body={body}"),
        ],
        cwd,
    );
    if !ok {
        return Err(err);
    }
    let id = serde_json::from_str::<Value>(&out)
        .ok()
        .and_then(|v| {
            v.pointer("/data/addPullRequestReviewThreadReply/comment/id")
                .and_then(|x| x.as_str())
                .map(String::from)
        })
        .unwrap_or_default();
    Ok(id)
}

/// Resolve or unresolve a review thread (GraphQL).
pub fn set_thread_resolved(
    thread_id: &str,
    resolved: bool,
    cwd: Option<&str>,
) -> Result<(), String> {
    let mutation = if resolved {
        "resolveReviewThread"
    } else {
        "unresolveReviewThread"
    };
    let q = format!(
        "mutation($tid:ID!){{{mutation}(input:{{threadId:$tid}}){{thread{{id isResolved}}}}}}"
    );
    let gh = gh_bin();
    let (ok, _out, err) = proc::run(
        &[
            gh.as_str(),
            "api",
            "graphql",
            "-f",
            &format!("query={q}"),
            "-f",
            &format!("tid={thread_id}"),
        ],
        cwd,
    );
    if ok {
        Ok(())
    } else {
        Err(err)
    }
}

pub fn review_threads(owner: &str, repo: &str, number: u64, cwd: Option<&str>) -> Vec<Value> {
    let num = format!("number={number}");
    let ov = format!("owner={owner}");
    let rv = format!("repo={repo}");
    let q = format!("query={THREADS_QUERY}");
    let gh = gh_bin();
    let (ok, out, _) = proc::run(
        &[
            gh.as_str(),
            "api",
            "graphql",
            "-f",
            &q,
            "-f",
            &ov,
            "-f",
            &rv,
            "-F",
            &num,
        ],
        cwd,
    );
    if !ok {
        return vec![];
    }
    serde_json::from_str::<Value>(&out)
        .ok()
        .and_then(|v| {
            v.pointer("/data/repository/pullRequest/reviewThreads/nodes")
                .and_then(|n| n.as_array().cloned())
        })
        .unwrap_or_default()
}
