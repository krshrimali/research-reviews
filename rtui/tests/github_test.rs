//! Importing existing GitHub review threads into the Store (idempotent).

use std::process::Command;

use prtui::data::github_sync::import;
use prtui::data::source::{GhComment, GhThread, Source};
use prtui::data::store::{new_uuid, Store};

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
    let d = std::env::temp_dir().join(format!("prtui-gh-{}-{}", std::process::id(), new_uuid()));
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

fn thread(id: &str, resolved: bool, comments: Vec<(&str, &str, &str)>) -> GhThread {
    GhThread {
        id: id.into(),
        resolved,
        outdated: false,
        path: "a.txt".into(),
        line: 1,
        side: "RIGHT".into(),
        comments: comments
            .into_iter()
            .map(|(id, author, body)| GhComment {
                id: id.into(),
                author: author.into(),
                body: body.into(),
                created_at: String::new(),
            })
            .collect(),
    }
}

#[test]
fn imports_threads_as_comments_idempotently() {
    std::env::set_var(
        "PRTUI_STATE_DIR",
        std::env::temp_dir().join(format!("prtui-ghstate-{}", new_uuid())),
    );
    let d = fixture();
    let mut src = Source::local(&d, Some("main"), None).unwrap();
    src.threads = vec![
        thread(
            "T1",
            false,
            vec![("C1", "alice", "why rename?"), ("C2", "bob", "agreed")],
        ),
        thread("T2", true, vec![("C3", "carol", "resolved one")]),
    ];
    let mut store = Store::for_source(&src);

    assert_eq!(import(&mut store, &src), 3, "3 comments imported");
    let roots = store.threads_for_file("a.txt");
    assert_eq!(roots.len(), 2, "two threads");
    let t1 = roots
        .iter()
        .find(|r| r.github_id.as_deref() == Some("C1"))
        .unwrap();
    assert_eq!(t1.origin, "github");
    assert_eq!(
        t1.gh_thread_id.as_deref(),
        Some("T1"),
        "root carries the thread node id"
    );
    assert_eq!(
        store.replies(&t1.id).len(),
        1,
        "reply imported under the root"
    );
    let t2 = roots
        .iter()
        .find(|r| r.github_id.as_deref() == Some("C3"))
        .unwrap();
    assert_eq!(
        t2.status, "resolved",
        "resolved upstream -> resolved locally"
    );

    // Re-import: nothing new (dedupe by github_id).
    assert_eq!(import(&mut store, &src), 0, "re-import is idempotent");

    // A local reply is preserved across re-import.
    store.reply(&t1.id, "my local reply", "local");
    assert_eq!(import(&mut store, &src), 0);
    assert_eq!(
        store.replies(&t1.id).len(),
        2,
        "local reply survives re-import"
    );
}
