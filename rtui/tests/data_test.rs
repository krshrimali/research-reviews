//! Integration tests for the data layer (real temp git repo + fake claude).

use std::process::Command;

use prtui::data::claude;
use prtui::data::source::Source;
use prtui::data::store::{Session, Store};

fn git(dir: &str, args: &[&str]) {
    let ok = Command::new("git")
        .args(args)
        .current_dir(dir)
        .output()
        .unwrap()
        .status
        .success();
    assert!(ok, "git {:?} failed", args);
}

fn fixture() -> String {
    let d = std::env::temp_dir().join(format!(
        "prtui-test-{}-{}",
        std::process::id(),
        prtui::data::store::new_uuid()
    ));
    std::fs::create_dir_all(&d).unwrap();
    let d = d.to_string_lossy().to_string();
    git(&d, &["init", "-q", "-b", "main"]);
    git(&d, &["config", "user.email", "t@t"]);
    git(&d, &["config", "user.name", "t"]);
    std::fs::create_dir_all(format!("{d}/src")).unwrap();
    std::fs::write(
        format!("{d}/src/auth.lua"),
        "local M = {}\nfunction M.get() return 1 end\nreturn M\n",
    )
    .unwrap();
    git(&d, &["add", "-A"]);
    git(&d, &["commit", "-qm", "base"]);
    git(&d, &["checkout", "-q", "-b", "feature/x"]);
    std::fs::write(
        format!("{d}/src/auth.lua"),
        "local M = {}\nfunction M.get_or_refresh() return 2 end\nreturn M\n",
    )
    .unwrap();
    std::fs::write(format!("{d}/src/cache.cpp"), "int cache(){return 0;}\n").unwrap();
    git(&d, &["add", "-A"]);
    git(&d, &["commit", "-qm", "add refresh + cache"]);
    d
}

fn with_state<T>(f: impl FnOnce() -> T) -> T {
    let dir = std::env::temp_dir().join(format!("prtui-state-{}", prtui::data::store::new_uuid()));
    std::env::set_var("PRTUI_STATE_DIR", &dir);
    f()
}

#[test]
fn source_parses_commits_and_files() {
    let d = fixture();
    let s = Source::local(&d, Some("main"), None).unwrap();
    assert_eq!(s.kind, "branch");
    assert_eq!(s.commits.len(), 1);
    let paths: Vec<_> = s.files.iter().map(|f| f.path.as_str()).collect();
    assert!(paths.contains(&"src/auth.lua"));
    assert!(paths.contains(&"src/cache.cpp"));
    let cache = s.files.iter().find(|f| f.path == "src/cache.cpp").unwrap();
    assert_eq!(cache.status, "added");
    assert!(cache.additions >= 1);
}

#[test]
fn source_resolves_an_unchecked_out_branch_head() {
    let d = fixture();
    let feature = prtui::data::git::rev_parse("feature/x", Some(&d)).unwrap();
    git(&d, &["checkout", "-q", "main"]);
    let source = Source::local(&d, Some("main"), Some("feature/x")).unwrap();
    assert_eq!(source.head_sha, feature);
    assert_eq!(source.commits.len(), 1);
    assert!(source.files.iter().any(|file| file.path == "src/cache.cpp"));
}

#[test]
fn source_handles_tabs_and_newlines_in_filenames() {
    let d = fixture();
    let weird = "odd\tname\nfile.txt";
    std::fs::write(std::path::Path::new(&d).join(weird), "content\n").unwrap();
    git(&d, &["add", "--", weird]);
    git(&d, &["commit", "-qm", "weird filename"]);
    let s = Source::local(&d, Some("main"), None).unwrap();
    let file = s
        .files
        .iter()
        .find(|f| f.path == weird)
        .expect("exact Git pathname");
    assert_eq!(file.status, "added");
    assert_eq!(file.additions, 1);
}

#[test]
fn store_crud_and_persist() {
    with_state(|| {
        let d = fixture();
        let s = Source::local(&d, Some("main"), None).unwrap();
        let mut store = Store::for_source(&s);
        let id = store.add(
            "src/auth.lua",
            "RIGHT",
            2,
            "why rename?",
            "local",
            "normal",
            None,
        );
        store.reply(&id, "a reply", "local");
        assert_eq!(store.replies(&id).len(), 1);

        let store2 = Store::for_source(&s);
        assert_eq!(store2.threads_for_file("src/auth.lua").len(), 1);

        let mut store3 = Store::for_source(&s);
        store3.delete(&id);
        let store4 = Store::for_source(&s);
        assert!(
            store4.get(&id).is_none(),
            "deletion must persist (tombstone)"
        );
    });
}

#[test]
fn reactions_toggle_and_persist() {
    with_state(|| {
        let d = fixture();
        let s = Source::local(&d, Some("main"), None).unwrap();
        let mut store = Store::for_source(&s);
        let id = store.add("src/auth.lua", "RIGHT", 2, "nice", "local", "normal", None);

        // First toggle adds; count is 1 and it persists.
        assert!(
            store.toggle_reaction(&id, "+1", "alice"),
            "first toggle adds"
        );
        assert_eq!(
            store.get(&id).unwrap().reactions.get("+1").unwrap().len(),
            1
        );
        let store2 = Store::for_source(&s);
        assert_eq!(
            store2.get(&id).unwrap().reactions.get("+1").unwrap().len(),
            1,
            "reaction persisted"
        );

        // A different reactor accumulates.
        store.toggle_reaction(&id, "+1", "bob");
        assert_eq!(
            store.get(&id).unwrap().reactions.get("+1").unwrap().len(),
            2
        );

        // Same reactor toggling again removes; empty bucket is pruned.
        assert!(
            !store.toggle_reaction(&id, "+1", "alice"),
            "second toggle removes"
        );
        assert_eq!(
            store.get(&id).unwrap().reactions.get("+1").unwrap().len(),
            1
        );
        store.toggle_reaction(&id, "+1", "bob");
        assert!(
            !store.get(&id).unwrap().reactions.contains_key("+1"),
            "empty bucket pruned"
        );
    });
}

#[test]
fn workflow_metadata_persists() {
    with_state(|| {
        let d = fixture();
        let s = Source::local(&d, Some("main"), None).unwrap();
        let mut store = Store::for_source(&s);
        let id = store.add("src/auth.lua", "RIGHT", 2, "fix", "local", "normal", None);
        store.update_workflow(&id, "needs_clarification", Some("needs clarification"));
        store.set_thread_metadata(
            &id,
            Some("abcdef123456"),
            Some("/tmp/wt"),
            "push_failed",
            vec!["PASS test".into()],
        );
        let loaded = Store::for_source(&s);
        let c = loaded.get(&id).unwrap();
        assert_eq!(c.workflow_state, "committed");
        assert_eq!(c.implementation_commit.as_deref(), Some("abcdef123456"));
        assert_eq!(c.validation, vec!["PASS test"]);
    });
}

#[test]
fn new_uuid_is_valid_v4_format() {
    let u = prtui::data::store::new_uuid();
    assert_eq!(u.len(), 36, "uuid length");
    let parts: Vec<&str> = u.split('-').collect();
    assert_eq!(
        parts.iter().map(|p| p.len()).collect::<Vec<_>>(),
        vec![8, 4, 4, 4, 12]
    );
    assert!(
        u.chars().all(|c| c == '-' || c.is_ascii_hexdigit()),
        "hex only"
    );
    assert_eq!(&u[14..15], "4", "version 4 nibble");
    assert!(
        matches!(&u[19..20], "8" | "9" | "a" | "b"),
        "variant nibble"
    );
    // uniqueness
    assert_ne!(
        prtui::data::store::new_uuid(),
        prtui::data::store::new_uuid()
    );
}

#[test]
fn extract_findings_takes_last_block() {
    let txt = "intro\n```json\n{\"verdict\":\"comment\"}\n```\nmore\n```json\n{\"verdict\":\"request_changes\"}\n```";
    let f = claude::extract_findings(txt).unwrap();
    assert_eq!(f["verdict"], "request_changes");
}

#[test]
fn replies_keep_chronological_order_and_author() {
    with_state(|| {
        let d = fixture();
        let s = Source::local(&d, Some("main"), None).unwrap();
        let mut store = Store::for_source(&s);
        let root = store.add(
            "src/auth.lua",
            "RIGHT",
            2,
            "why rename?",
            "local",
            "normal",
            None,
        );
        // Three replies created in the same instant, alternating authors.
        store.reply(&root, "claude first", "claude");
        store.reply(&root, "reviewer second", "local");
        store.reply(&root, "claude third", "claude");
        let replies = store.replies(&root);
        let bodies: Vec<&str> = replies.iter().map(|r| r.body.as_str()).collect();
        assert_eq!(
            bodies,
            vec!["claude first", "reviewer second", "claude third"],
            "replies stay in chronological order even within the same second"
        );
        assert_eq!(
            replies[0].author, "claude",
            "claude replies are authored 'claude'"
        );
        assert_ne!(
            replies[1].author, "claude",
            "human reply keeps the user's name"
        );
        assert_eq!(replies[2].author, "claude");
    });
}

#[test]
fn followup_prompt_includes_thread_replies() {
    with_state(|| {
        let d = fixture();
        let s = Source::local(&d, Some("main"), None).unwrap();
        let mut store = Store::for_source(&s);
        let root = store.add(
            "src/auth.lua",
            "RIGHT",
            2,
            "claude: cache this",
            "claude",
            "normal",
            None,
        );
        store.reply(&root, "reviewer: but the cache can go stale", "local");
        let opts = claude::ClaudeOpts {
            claude_bin: "claude".into(),
            instruction: String::new(),
            allow_edits: false,
            auto_resolve: false,
            address_comments: false,
            test_commands: vec![],
            protected_paths: vec![],
            commit_strategy: "single".into(),
            push_changes: false,
        };
        let prompt = claude::user_prompt(&s, "", &store, &store.all_threads(), &opts);
        assert!(
            prompt.contains("reviewer: but the cache can go stale"),
            "follow-up prompt must include the reviewer's reply so Claude can respond"
        );
        assert!(
            prompt.contains(&root),
            "prompt references the thread's comment_id"
        );
    });
}

#[test]
fn address_mode_prompt_requires_implementation_commit() {
    with_state(|| {
        let d = fixture();
        let s = Source::local(&d, Some("main"), None).unwrap();
        let store = Store::for_source(&s);
        let opts = claude::ClaudeOpts {
            claude_bin: "claude".into(),
            instruction: "Address every comment".into(),
            allow_edits: true,
            auto_resolve: false,
            address_comments: true,
            test_commands: vec!["cargo test".into()],
            protected_paths: vec!["vendor/".into()],
            commit_strategy: "single".into(),
            push_changes: false,
        };
        let prompt = claude::user_prompt(&s, "", &store, &[], &opts);
        assert!(prompt.contains("address_comments: true"));
    });
}

#[test]
fn mutating_worktrees_are_isolated_by_task() {
    let d = fixture();
    let s = Source::local(&d, Some("main"), None).unwrap();
    let root =
        std::env::temp_dir().join(format!("prtui-wt-test-{}", prtui::data::store::new_uuid()));
    let a = prtui::data::worktree::ensure_task_in(&d, &s.head_sha, "task-a", root.clone()).unwrap();
    let b = prtui::data::worktree::ensure_task_in(&d, &s.head_sha, "task-b", root).unwrap();
    assert_ne!(a, b);
    assert_eq!(
        prtui::data::git::rev_parse("HEAD", a.to_str()),
        Some(s.head_sha.clone())
    );
    assert_eq!(
        prtui::data::git::rev_parse("HEAD", b.to_str()),
        Some(s.head_sha)
    );
}

#[test]
fn automatic_worktrees_stay_inside_repository_git_metadata() {
    let d = fixture();
    let source = Source::local(&d, Some("main"), None).unwrap();
    let path = prtui::data::worktree::ensure_task(&d, &source.head_sha, "privacy-test").unwrap();
    let git_dir = std::fs::canonicalize(std::path::Path::new(&d).join(".git")).unwrap();
    let path = std::fs::canonicalize(path).unwrap();
    assert!(path.starts_with(git_dir));
}

#[test]
fn managed_worktrees_can_be_cleaned_by_age() {
    let d = fixture();
    let source = Source::local(&d, Some("main"), None).unwrap();
    let path = prtui::data::worktree::ensure_task(&d, &source.head_sha, "cleanup-test").unwrap();
    let removed = prtui::data::worktree::cleanup(&d, std::time::Duration::ZERO).unwrap();
    assert!(removed >= 1);
    assert!(!path.exists());
}

#[test]
fn host_qualified_store_loads_legacy_pr_state() {
    let d = fixture();
    let state = std::path::PathBuf::from(&d).join("state-migration");
    let mut source = Source::local(&d, Some("main"), None).unwrap();
    source.key = "gh:acme/prtui#42".into();
    let mut legacy = Store::for_source_in(&source, state.clone());
    let id = legacy.add(
        "src/auth.lua",
        "RIGHT",
        2,
        "legacy",
        "local",
        "normal",
        None,
    );

    source.github_host = "github.corp.example".into();
    source.key = "gh:github.corp.example/acme/prtui#42".into();
    let migrated = Store::for_source_in(&source, state);
    assert_eq!(migrated.get(&id).map(|c| c.body.as_str()), Some("legacy"));
}

#[test]
fn fake_claude_end_to_end() {
    with_state(|| {
        let d = fixture();
        let s = Source::local(&d, Some("main"), None).unwrap();
        let mut store = Store::for_source(&s);
        let root = store.add(
            "src/auth.lua",
            "RIGHT",
            2,
            "why rename?",
            "local",
            "normal",
            None,
        );

        let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.sh");
        if !std::path::Path::new(fake).exists() {
            return; // fake unavailable; skip
        }
        let opts = claude::ClaudeOpts {
            claude_bin: fake.into(),
            instruction: "Critical".into(),
            allow_edits: false,
            auto_resolve: false,
            address_comments: false,
            test_commands: vec![],
            protected_paths: vec![],
            commit_strategy: "single".into(),
            push_changes: false,
        };
        let diff = prtui::data::git::full_diff(&s.base_sha, &s.head_sha, Some(&s.repo_root));
        let threads = store.all_threads();
        let prompt = claude::user_prompt(&s, &diff, &store, &threads, &opts);
        let sid = prtui::data::store::new_uuid();
        let rx = claude::start(
            fake.into(),
            s.repo_root.clone(),
            prompt,
            sid.clone(),
            false,
            false,
        );

        // Block until a Result/Error.
        let findings = loop {
            match rx.recv().unwrap() {
                claude::ClaudeEvent::Result(v) => break v,
                claude::ClaudeEvent::Error(e) => panic!("claude error: {e}"),
                _ => {}
            }
        };
        let session = Session {
            id: sid,
            state: "running".into(),
            ..Default::default()
        };
        let done = claude::apply(&mut store, &s, session, &findings);
        assert_eq!(done.verdict.as_deref(), Some("request_changes"));
        assert_eq!(
            store.replies(&root).len(),
            1,
            "claude replied to the thread"
        );
        let claude_new = store
            .comments
            .values()
            .filter(|c| c.origin == "claude" && c.in_reply_to.is_none())
            .count();
        assert_eq!(claude_new, 1, "claude added a new comment");
    });
}
