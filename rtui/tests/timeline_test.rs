//! Unit tests for the Timeline / activity feed builder.

use prtui::data::git::Commit;
use prtui::data::source::Review;
use prtui::timeline::{build_from, EventKind};

fn commit(short: &str, subject: &str, date: &str) -> Commit {
    Commit {
        sha: format!("{short}000"),
        short: short.into(),
        subject: subject.into(),
        body: String::new(),
        author: "dev".into(),
        date: date.into(),
    }
}
fn review(state: &str, date: &str, body: &str) -> Review {
    Review {
        author: "octocat".into(),
        state: state.into(),
        date: date.into(),
        body: body.into(),
    }
}

#[test]
fn merges_commits_and_reviews_in_date_order() {
    let commits = vec![
        commit("c2", "second", "2026-02-02T00:00:00Z"),
        commit("c1", "first", "2026-02-01T00:00:00Z"),
    ];
    let reviews = vec![review("APPROVED", "2026-02-03T00:00:00Z", "LGTM")];
    let events = build_from(&commits, &reviews);
    assert_eq!(events.len(), 3);
    // Ascending by date: c1, c2, then the approval.
    assert_eq!(events[0].kind, EventKind::Commit);
    assert!(events[0].text.contains("first"));
    assert!(events[1].text.contains("second"));
    assert_eq!(events[2].kind, EventKind::ReviewApproved);
    assert!(events[2].text.contains("LGTM"));
}

#[test]
fn review_states_map_to_kinds() {
    let reviews = vec![
        review("CHANGES_REQUESTED", "2026-01-01T00:00:00Z", ""),
        review("COMMENTED", "2026-01-02T00:00:00Z", ""),
    ];
    let events = build_from(&[], &reviews);
    assert_eq!(events[0].kind, EventKind::ReviewChangesRequested);
    assert_eq!(events[1].kind, EventKind::ReviewCommented);
}

#[test]
fn empty_source_has_no_events() {
    assert!(build_from(&[], &[]).is_empty());
}
