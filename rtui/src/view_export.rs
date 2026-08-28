//! Plain Markdown exports for the read-only main views. These are intentionally built
//! from the model rather than terminal cells, so editors get complete, unwrapped text.

use crate::app::MainTab;
use crate::data::source::Source;
use crate::data::store::{Comment, Session, Store};
use crate::timeline::{self, EventKind};

pub fn markdown(tab: MainTab, source: &Source, store: &Store) -> Option<String> {
    match tab {
        MainTab::Conversation => Some(conversation(source, store)),
        MainTab::Timeline => Some(activity(source)),
        MainTab::Claude => Some(claude(store)),
        MainTab::Comments => Some(comments(store)),
        MainTab::Diff => None,
    }
}

pub fn slug(tab: MainTab) -> &'static str {
    match tab {
        MainTab::Conversation => "conversation",
        MainTab::Timeline => "timeline",
        MainTab::Claude => "claude",
        MainTab::Comments => "comments",
        MainTab::Diff => "diff",
    }
}

fn conversation(source: &Source, store: &Store) -> String {
    let mut out = format!("# {}\n\n", source.title);
    if !source.description.trim().is_empty() {
        out.push_str(&source.description);
        out.push_str("\n\n");
    }
    if !source.checks.is_empty() {
        out.push_str("## Checks\n\n");
        for (name, state) in &source.checks {
            out.push_str(&format!("- [{state}] {name}\n"));
        }
        out.push('\n');
    }
    out.push_str("## Review threads\n\n");
    append_threads(&mut out, store, store.all_threads());
    out
}

fn comments(store: &Store) -> String {
    let mut out = String::from("# Comments\n\n");
    let roots = store.all_threads();
    for (title, predicate) in [
        ("Unresolved", 0_u8),
        ("Resolved", 1_u8),
        ("Outdated", 2_u8),
        ("Hidden", 3_u8),
    ] {
        let group: Vec<Comment> = roots
            .iter()
            .filter(|c| match predicate {
                0 => !c.hidden && !c.outdated && c.status != "resolved",
                1 => !c.hidden && !c.outdated && c.status == "resolved",
                2 => !c.hidden && c.outdated,
                _ => c.hidden,
            })
            .cloned()
            .collect();
        out.push_str(&format!("## {title} ({})\n\n", group.len()));
        append_threads(&mut out, store, group);
    }
    out
}

fn append_threads(out: &mut String, store: &Store, mut roots: Vec<Comment>) {
    roots.sort_by(|a, b| a.file.cmp(&b.file).then(a.line_start.cmp(&b.line_start)));
    if roots.is_empty() {
        out.push_str("_None._\n\n");
        return;
    }
    for root in roots {
        let state = if root.outdated {
            "outdated"
        } else if root.hidden {
            "hidden"
        } else {
            root.status.as_str()
        };
        out.push_str(&format!(
            "### {}:{} — {} ({state})\n\n{}\n\n",
            root.file, root.line_start, root.author, root.body
        ));
        if root.outdated {
            if let Some(anchor) = root.anchor_text.as_deref().filter(|s| !s.is_empty()) {
                out.push_str(&format!("Original code:\n\n```\n{anchor}\n```\n\n"));
            }
        }
        for reply in store.replies(&root.id) {
            out.push_str(&format!(
                "> **{}:** {}\n\n",
                reply.author,
                reply.body.replace('\n', "\n> ")
            ));
        }
    }
}

fn activity(source: &Source) -> String {
    let mut out = String::from("# Timeline\n\n");
    let events = timeline::build(source);
    if events.is_empty() {
        out.push_str("_No activity yet._\n");
    }
    for event in events {
        let kind = match event.kind {
            EventKind::Commit => "commit",
            EventKind::ReviewApproved => "approved",
            EventKind::ReviewChangesRequested => "changes requested",
            EventKind::ReviewCommented => "review",
        };
        out.push_str(&format!(
            "- **{}** · {} · {} — {}\n",
            event.actor, event.date, kind, event.text
        ));
    }
    out
}

fn claude(store: &Store) -> String {
    let mut out = String::from("# Claude reviews\n\n");
    let mut sessions: Vec<&Session> = store.sessions.values().collect();
    sessions.sort_by(|a, b| b.started_at.cmp(&a.started_at));
    if sessions.is_empty() {
        out.push_str("_No Claude review sessions yet._\n");
    }
    for session in sessions {
        out.push_str(&format!(
            "## {}\n\n",
            session.verdict.as_deref().unwrap_or(&session.state)
        ));
        if !session.instruction.is_empty() {
            out.push_str(&format!("**Instruction:** {}\n\n", session.instruction));
        }
        if !session.summary.is_empty() {
            out.push_str(&format!("{}\n\n", session.summary));
        }
        if let Some(error) = &session.error {
            out.push_str(&format!("**Error:** {error}\n\n"));
        }
        if !session.notes.is_empty() {
            out.push_str("### Notes\n\n");
            for note in &session.notes {
                out.push_str(&format!("- {note}\n"));
            }
            out.push('\n');
        }
        if !session.log.is_empty() {
            out.push_str("<details><summary>Progress log</summary>\n\n```text\n");
            out.push_str(&session.log.join("\n"));
            out.push_str("\n```\n</details>\n\n");
        }
    }
    out
}
