//! Exercise the whole `src/data/gh.rs` layer offline via a fake `gh` (tests/fake_gh.sh),
//! pointed at through $PRTUI_GH_BIN. Asserts the parsing of each command's JSON/GraphQL
//! response and (via $PRTUI_GH_LOG) the argv that was built.

use std::sync::{Mutex, MutexGuard};

use prtui::data::gh;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_gh.sh");

// These tests mutate process-global env vars ($PRTUI_GH_BIN / $PRTUI_GH_LOG), so they must
// not run concurrently — serialize the whole suite behind one lock.
static GH_LOCK: Mutex<()> = Mutex::new(());

/// Acquire the serialization lock, point gh at the fake, and start a fresh argv log.
/// Returns the guard (held for the test) + the log path, or None if the fake is missing.
fn setup() -> Option<(MutexGuard<'static, ()>, String)> {
    if !std::path::Path::new(FAKE).exists() {
        return None; // fake unavailable; caller skips
    }
    let guard = GH_LOCK.lock().unwrap_or_else(|p| p.into_inner());
    std::env::set_var("PRTUI_GH_BIN", FAKE);
    let log = std::env::temp_dir().join(format!(
        "prtui-ghlog-{}.txt",
        prtui::data::store::new_uuid()
    ));
    std::env::set_var("PRTUI_GH_LOG", &log);
    let _ = std::fs::remove_file(&log);
    Some((guard, log.to_string_lossy().to_string()))
}

fn log(path: &str) -> String {
    std::fs::read_to_string(path).unwrap_or_default()
}

#[test]
fn available_reports_true_with_fake_gh() {
    let Some((_g, _log)) = setup() else { return };
    assert!(gh::available(), "fake gh --version succeeds");
}

#[test]
fn owner_repo_parses_slug() {
    let Some((_g, _log)) = setup() else { return };
    assert_eq!(gh::owner_repo(None), Some(("acme".into(), "prtui".into())));
}

#[test]
fn repository_identity_preserves_enterprise_host() {
    let Some((_g, _log)) = setup() else { return };
    let identity = gh::repo_identity(None).expect("identity");
    assert_eq!(identity.host, "github.corp.example");
    assert_eq!(identity.owner, "acme");
    assert_eq!(identity.repo, "prtui");
    assert_eq!(
        identity.transport_url,
        "https://github.corp.example/acme/prtui.git"
    );
    assert_eq!(
        prtui::data::git::github_https_url("github.corp.example", "acme", "prtui"),
        "https://github.corp.example/acme/prtui.git"
    );
}

#[test]
fn list_prs_parses_records() {
    let Some((_g, logp)) = setup() else { return };
    let prs = gh::list_prs(None);
    assert_eq!(prs.len(), 1);
    assert_eq!(prs[0]["number"], 42);
    assert_eq!(prs[0]["author"]["login"], "octocat");
    assert!(
        log(&logp).contains("pr list"),
        "argv logged the pr list command"
    );
    assert!(log(&logp).contains("--state open"));
}

#[test]
fn list_prs_can_include_closed_and_merged() {
    let Some((_g, logp)) = setup() else { return };
    let _ = gh::list_prs_with_state(None, "all");
    assert!(log(&logp).contains("--state all"));
}

#[test]
fn pr_view_parses_object() {
    let Some((_g, logp)) = setup() else { return };
    let v = gh::pr_view(42, None).expect("some");
    assert_eq!(v["title"], "Add token refresh");
    assert_eq!(v["reviews"][0]["state"], "APPROVED");
    assert_eq!(v["headRepositoryOwner"]["login"], "contributor");
    assert_eq!(v["headRepository"]["name"], "prtui-fork");
    let base = gh::repo_identity(None).expect("base identity");
    let head = gh::pr_head_identity(&v, &base);
    assert_eq!(head.owner, "contributor");
    assert_eq!(head.repo, "prtui-fork");
    assert_eq!(
        head.transport_url,
        "https://github.corp.example/contributor/prtui-fork.git"
    );
    assert!(
        log(&logp).contains("pr view 42"),
        "argv passed the PR number"
    );
}

#[test]
fn configured_gh_binary_is_used_for_git_credentials() {
    let Some((_g, _log)) = setup() else { return };
    let helper = prtui::data::git::gh_credential_helper();
    assert!(helper.contains(FAKE));
    assert!(!helper.contains("!gh auth"));
}

#[test]
fn review_threads_parses_nodes_including_outdated() {
    let Some((_g, _log)) = setup() else { return };
    let threads = gh::review_threads("acme", "prtui", 42, None);
    assert_eq!(threads.len(), 2);
    assert_eq!(
        threads[1]["isOutdated"], true,
        "the second thread is outdated"
    );
    assert_eq!(
        threads[0]["comments"]["nodes"][0]["author"]["login"],
        "octocat"
    );
}

#[test]
fn submit_review_sends_payload_and_parses_response() {
    let Some((_g, logp)) = setup() else { return };
    let payload = r#"{"event":"COMMENT","body":"looks good"}"#;
    let resp = gh::submit_review("acme", "prtui", 42, payload, None).expect("ok");
    assert_eq!(resp["id"], 12345);
    let l = log(&logp);
    assert!(
        l.contains("repos/acme/prtui/pulls/42/reviews"),
        "REST path built correctly"
    );
    assert!(l.contains("--input -"), "payload piped via --input -");
}

#[test]
fn reply_to_thread_returns_new_comment_id() {
    let Some((_g, _log)) = setup() else { return };
    let id = gh::reply_to_thread("T_123", "thanks", None).expect("ok");
    assert_eq!(
        id, "RC_new123",
        "parses the new comment node id from the mutation"
    );
}

#[test]
fn set_thread_resolved_succeeds() {
    let Some((_g, logp)) = setup() else { return };
    assert!(gh::set_thread_resolved("T_123", true, None).is_ok());
    assert!(
        log(&logp).contains("resolveReviewThread"),
        "used the resolve mutation"
    );
    assert!(gh::set_thread_resolved("T_123", false, None).is_ok());
    assert!(
        log(&logp).contains("unresolveReviewThread"),
        "used the unresolve mutation"
    );
}

#[test]
fn react_to_comment_maps_names_and_succeeds() {
    let Some((_g, logp)) = setup() else { return };
    assert!(gh::react_to_comment("o", "r", "C1", "+1", None).is_ok());
    assert!(
        log(&logp).contains("THUMBS_UP"),
        "+1 maps to THUMBS_UP in the mutation"
    );
    assert!(gh::react_to_comment("o", "r", "C1", "rocket", None).is_ok());
    assert!(log(&logp).contains("ROCKET"), "rocket maps to ROCKET");
    // An unknown reaction is rejected before any gh call.
    assert!(gh::react_to_comment("o", "r", "C1", "bogus", None).is_err());
}

#[test]
fn pr_command_runs_lifecycle_verbs() {
    let Some((_g, logp)) = setup() else { return };
    assert!(gh::pr_command(&["merge", "42", "--squash"], None).is_ok());
    assert!(gh::pr_command(&["close", "42"], None).is_ok());
    let l = log(&logp);
    assert!(l.contains("pr merge 42 --squash"));
    assert!(l.contains("pr close 42"));
}
