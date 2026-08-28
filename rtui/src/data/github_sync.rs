//! Import existing GitHub review threads into the local Store so they render on the diff,
//! Conversation, and Comments views. Idempotent: comments already present (by github_id)
//! are refreshed; local replies (no github_id) are preserved.

use super::source::Source;
use super::store::{Comment, Store};

fn now() -> String {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("{secs:039}-000000000000")
}

/// Import (or refresh) all of a PR's review threads into `store`. Returns count imported.
pub fn import(store: &mut Store, source: &Source) -> usize {
    if source.threads.is_empty() {
        return 0;
    }
    // Existing GH comments by their node id.
    let seen: std::collections::HashMap<String, String> = store
        .comments
        .values()
        .filter_map(|c| c.github_id.clone().map(|g| (g, c.id.clone())))
        .collect();
    let mut imported = 0;

    for t in &source.threads {
        let side = if t.side == "LEFT" { "LEFT" } else { "RIGHT" };
        let line = if t.line > 0 { t.line as u32 } else { 1 };
        let status = if t.resolved { "resolved" } else { "draft" };
        let mut root_id: Option<String> = None;

        for (i, cm) in t.comments.iter().enumerate() {
            if let Some(existing_id) = seen.get(&cm.id) {
                // refresh upstream-authoritative fields; keep local edits/replies intact
                if let Some(c) = store.comments.get_mut(existing_id) {
                    c.body = cm.body.clone();
                    if t.resolved {
                        c.status = "resolved".into();
                    }
                    c.outdated = t.outdated;
                    if i == 0 {
                        root_id = Some(c.id.clone());
                    }
                }
                continue;
            }
            let is_root = i == 0;
            let kind = if cm.body.contains("```suggestion") {
                "suggestion"
            } else {
                "normal"
            };
            let id = super::store::new_uuid();
            let c = Comment {
                id: id.clone(),
                file: t.path.clone(),
                side: side.into(),
                line_start: line,
                line_end: line,
                body: cm.body.clone(),
                origin: "github".into(),
                status: status.into(),
                kind: kind.into(),
                suggestion_text: None,
                in_reply_to: if is_root { None } else { root_id.clone() },
                github_id: Some(cm.id.clone()),
                gh_thread_id: if is_root { Some(t.id.clone()) } else { None },
                author: if cm.author.is_empty() {
                    "github".into()
                } else {
                    cm.author.clone()
                },
                created_at: if cm.created_at.is_empty() {
                    now()
                } else {
                    cm.created_at.clone()
                },
                hidden: false,
                reactions: Default::default(),
                anchor_text: None,
                outdated: t.outdated,
                workflow_state: if t.resolved { "resolved" } else { "unresolved" }.into(),
                assessment: String::new(),
                label: String::new(),
                priority: 0,
                action_owner: "author".into(),
                implementation_commit: None,
                implementation_worktree: None,
                push_state: String::new(),
                validation: vec![],
            };
            if is_root {
                root_id = Some(id.clone());
            }
            store.comments.insert(id, c);
            imported += 1;
        }
    }
    store.save();
    imported
}
