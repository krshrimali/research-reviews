//! Publish payload + item-selection logic (no gh calls).

use std::process::Command;

use prtui::data::source::Source;
use prtui::data::store::{new_uuid, Store};
use prtui::publish::{build_payload, PubItem, PublishView, Verdict};

fn git(dir: &str, args: &[&str]) {
    assert!(Command::new("git")
        .args(args)
        .current_dir(dir)
        .output()
        .unwrap()
        .status
        .success());
}

fn fixture() -> String {
    let d = std::env::temp_dir().join(format!("prtui-pub-{}-{}", std::process::id(), new_uuid()));
    std::fs::create_dir_all(&d).unwrap();
    let d = d.to_string_lossy().to_string();
    git(&d, &["init", "-q", "-b", "main"]);
    git(&d, &["config", "user.email", "t@t"]);
    git(&d, &["config", "user.name", "t"]);
    std::fs::write(format!("{d}/a.txt"), "x\n").unwrap();
    git(&d, &["add", "-A"]);
    git(&d, &["commit", "-qm", "base"]);
    git(&d, &["checkout", "-q", "-b", "feature/x"]);
    std::fs::write(format!("{d}/a.txt"), "y\n").unwrap();
    git(&d, &["add", "-A"]);
    git(&d, &["commit", "-qm", "work"]);
    d
}

fn with_state<T>(f: impl FnOnce() -> T) -> T {
    std::env::set_var(
        "PRTUI_STATE_DIR",
        std::env::temp_dir().join(format!("prtui-pubstate-{}", new_uuid())),
    );
    f()
}

#[test]
fn build_payload_shapes_review_correctly() {
    let single = PubItem {
        include: true,
        path: "src/a.rs".into(),
        line_start: 5,
        line_end: 5,
        side: "RIGHT".into(),
        body: "fix this".into(),
        root_id: "r1".into(),
    };
    let range = PubItem {
        include: true,
        path: "src/b.rs".into(),
        line_start: 10,
        line_end: 14,
        side: "RIGHT".into(),
        body: "this block".into(),
        root_id: "r2".into(),
    };
    let items = vec![&single, &range];
    let p = build_payload("abc123", Verdict::RequestChanges, "please fix", &items);

    assert_eq!(p["commit_id"], "abc123");
    assert_eq!(p["event"], "REQUEST_CHANGES");
    assert_eq!(p["body"], "please fix");
    let comments = p["comments"].as_array().unwrap();
    assert_eq!(comments.len(), 2);
    assert_eq!(comments[0]["path"], "src/a.rs");
    assert_eq!(comments[0]["line"], 5);
    assert_eq!(comments[0]["side"], "RIGHT");
    assert!(
        comments[0].get("start_line").is_none(),
        "single-line comment has no start_line"
    );
    assert_eq!(comments[1]["line"], 14);
    assert_eq!(
        comments[1]["start_line"], 10,
        "range comment carries start_line"
    );
    assert_eq!(comments[1]["start_side"], "RIGHT");
}

#[test]
fn verdict_events_map() {
    assert_eq!(Verdict::Approve.event(), "APPROVE");
    assert_eq!(Verdict::RequestChanges.event(), "REQUEST_CHANGES");
    assert_eq!(Verdict::Comment.event(), "COMMENT");
}

#[test]
fn publish_view_includes_only_publishable_drafts() {
    with_state(|| {
        let d = fixture();
        let src = Source::local(&d, Some("main"), None).unwrap();
        let mut store = Store::for_source(&src);
        let keep = store.add("a.txt", "RIGHT", 1, "please fix", "local", "normal", None);
        let resolved = store.add("a.txt", "RIGHT", 1, "done", "local", "normal", None);
        store.set_resolved(&resolved, true);
        let hidden = store.add("a.txt", "RIGHT", 1, "noise", "local", "normal", None);
        store.set_hidden(&hidden, true);
        let published = store.add("a.txt", "RIGHT", 1, "already up", "local", "normal", None);
        store.mark_published(&published);
        // A reply on the kept thread should be flattened into its body.
        store.reply(&keep, "and also this", "local");

        let view = PublishView::new(&store, "summary");
        assert_eq!(
            view.items.len(),
            1,
            "only the unresolved, unhidden, unpublished draft is included"
        );
        assert_eq!(view.items[0].root_id, keep);
        assert!(
            view.items[0].body.contains("please fix")
                && view.items[0].body.contains("and also this"),
            "thread flattened (root + reply) into the comment body"
        );
        assert_eq!(
            view.verdict.event(),
            "COMMENT",
            "defaults to a plain comment"
        );
    });
}
