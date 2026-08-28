//! A read-only activity feed for the PR / branch: commits pushed and reviews
//! submitted, merged into one chronological list. Pure over `Source`, so it renders
//! the same for PRs (commits + reviews) and local branches (commits only).

use crate::data::git::Commit;
use crate::data::source::{Review, Source};

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum EventKind {
    Commit,
    ReviewApproved,
    ReviewChangesRequested,
    ReviewCommented,
}

pub struct Event {
    pub kind: EventKind,
    pub actor: String,
    pub text: String,
    pub date: String, // ISO8601 or epoch string; used only for sorting + display
}

/// Build the chronological (oldest-first) event feed for a source.
pub fn build(source: &Source) -> Vec<Event> {
    build_from(&source.commits, &source.reviews)
}

/// Pure builder over commit + review slices (unit-testable without a live Source).
pub fn build_from(commits: &[Commit], reviews: &[Review]) -> Vec<Event> {
    let mut events: Vec<Event> = Vec::new();

    // Commits are returned newest-first by `git log`; keep their own dates for sorting.
    for c in commits {
        events.push(Event {
            kind: EventKind::Commit,
            actor: c.author.clone(),
            text: format!("{}  {}", c.short, c.subject),
            date: c.date.clone(),
        });
    }

    for r in reviews {
        let kind = match r.state.as_str() {
            "APPROVED" => EventKind::ReviewApproved,
            "CHANGES_REQUESTED" => EventKind::ReviewChangesRequested,
            _ => EventKind::ReviewCommented,
        };
        let verb = match kind {
            EventKind::ReviewApproved => "approved these changes",
            EventKind::ReviewChangesRequested => "requested changes",
            _ => "reviewed",
        };
        let text = if r.body.trim().is_empty() {
            verb.to_string()
        } else {
            format!("{verb} — {}", first_line(&r.body))
        };
        events.push(Event {
            kind,
            actor: r.author.clone(),
            text,
            date: r.date.clone(),
        });
    }

    // Stable sort by date ascending; empty dates sort first (unknown / earliest).
    events.sort_by(|a, b| a.date.cmp(&b.date));
    events
}

fn first_line(s: &str) -> String {
    s.lines().next().unwrap_or("").trim().to_string()
}
