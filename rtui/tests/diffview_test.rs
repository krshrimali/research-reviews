//! Unit tests for the word-diff and split-view pairing helpers.

use std::collections::HashMap;

use prtui::app::{DiffKind, DiffLine};
use prtui::diffview::{annotate_word_diff, locate_anchor, split_rows, word_diff, Anchor};

fn dl(kind: DiffKind, text: &str, old_ln: Option<u32>, new_ln: Option<u32>) -> DiffLine {
    DiffLine {
        kind,
        text: text.into(),
        old_ln,
        new_ln,
        ..Default::default()
    }
}

#[test]
fn word_diff_marks_only_the_changed_word() {
    let (old, new) = word_diff("let x = 1;", "let x = 2;");
    // The only changed token on each side is the number.
    let changed_old: String = old
        .iter()
        .filter(|(_, c)| *c)
        .map(|(t, _)| t.clone())
        .collect();
    let changed_new: String = new
        .iter()
        .filter(|(_, c)| *c)
        .map(|(t, _)| t.clone())
        .collect();
    assert_eq!(changed_old, "1");
    assert_eq!(changed_new, "2");
    // Reassembling all spans reproduces the original text (nothing dropped).
    let whole: String = new.iter().map(|(t, _)| t.clone()).collect();
    assert_eq!(whole, "let x = 2;");
}

#[test]
fn word_diff_identical_lines_have_no_changes() {
    let (old, new) = word_diff("same line", "same line");
    assert!(old.iter().all(|(_, c)| !c));
    assert!(new.iter().all(|(_, c)| !c));
}

#[test]
fn annotate_pairs_del_and_add_runs() {
    let mut lines = vec![
        dl(DiffKind::Hunk, "@@ -1,3 +1,3 @@", None, None),
        dl(DiffKind::Ctx, " ctx", Some(1), Some(1)),
        dl(DiffKind::Del, "-let x = 1;", Some(2), None),
        dl(DiffKind::Add, "+let x = 2;", None, Some(2)),
        dl(DiffKind::Ctx, " tail", Some(3), Some(3)),
    ];
    annotate_word_diff(&mut lines);
    assert!(lines[2].word_hl.is_some(), "deleted line got word-diff");
    assert!(lines[3].word_hl.is_some(), "added line got word-diff");
    // Context lines are never word-annotated.
    assert!(lines[1].word_hl.is_none());
    assert!(lines[4].word_hl.is_none());
}

#[test]
fn pure_insertion_is_not_word_annotated() {
    // An add with no matching del in the run stays fully colored (no pairing).
    let mut lines = vec![
        dl(DiffKind::Ctx, " ctx", Some(1), Some(1)),
        dl(DiffKind::Add, "+brand new line", None, Some(2)),
    ];
    annotate_word_diff(&mut lines);
    assert!(lines[1].word_hl.is_none());
}

#[test]
fn split_rows_pairs_changes_side_by_side() {
    let lines = vec![
        dl(DiffKind::Hunk, "@@ -1,3 +1,3 @@", None, None),
        dl(DiffKind::Ctx, " unchanged", Some(1), Some(1)),
        dl(DiffKind::Del, "-old one", Some(2), None),
        dl(DiffKind::Add, "+new one", None, Some(2)),
        dl(DiffKind::Ctx, " tail", Some(3), Some(3)),
    ];
    let rows = split_rows(&lines);
    // hunk header + 3 content rows.
    assert_eq!(rows.len(), 4);
    assert!(rows[0].hunk.is_some(), "first row is the hunk header");

    // Context row: same text on both sides, with respective line numbers.
    let ctx = &rows[1];
    assert_eq!(ctx.left.as_ref().unwrap().ln, Some(1));
    assert_eq!(ctx.right.as_ref().unwrap().ln, Some(1));
    assert_eq!(ctx.right.as_ref().unwrap().text, "unchanged");

    // Change row: del on the left, add on the right.
    let chg = &rows[2];
    assert_eq!(chg.left.as_ref().unwrap().text, "old one");
    assert_eq!(chg.left.as_ref().unwrap().kind, DiffKind::Del);
    assert_eq!(chg.right.as_ref().unwrap().text, "new one");
    assert_eq!(chg.right.as_ref().unwrap().kind, DiffKind::Add);
}

fn code_map(pairs: &[(u32, &str)]) -> HashMap<u32, String> {
    pairs.iter().map(|(k, v)| (*k, v.to_string())).collect()
}

#[test]
fn locate_anchor_in_place() {
    let code = code_map(&[(1, "let a = 1;"), (2, "let b = 2;"), (3, "return a + b;")]);
    assert_eq!(locate_anchor(2, "let b = 2;", &code), Anchor::InPlace);
}

#[test]
fn locate_anchor_repositions_to_nearest_match() {
    // The anchored code moved from line 2 to line 4 (e.g. lines inserted above it).
    let code = code_map(&[(1, "hdr"), (4, "let b = 2;"), (7, "let b = 2;")]);
    // Nearest to the original line 2 is line 4, not the duplicate at 7.
    assert_eq!(locate_anchor(2, "let b = 2;", &code), Anchor::MoveTo(4));
}

#[test]
fn locate_anchor_outdated_when_code_gone() {
    let code = code_map(&[(1, "let a = 1;"), (2, "let b = 99;")]); // b changed
    assert_eq!(locate_anchor(2, "let b = 2;", &code), Anchor::Outdated);
}

#[test]
fn split_rows_gives_filler_for_uneven_runs() {
    // Two deletions, one addition: the second change row has no right cell.
    let lines = vec![
        dl(DiffKind::Del, "-a", Some(1), None),
        dl(DiffKind::Del, "-b", Some(2), None),
        dl(DiffKind::Add, "+c", None, Some(1)),
    ];
    let rows = split_rows(&lines);
    assert_eq!(rows.len(), 2);
    assert!(rows[0].left.is_some() && rows[0].right.is_some());
    assert!(
        rows[1].left.is_some() && rows[1].right.is_none(),
        "leftover deletion has empty right"
    );
}
