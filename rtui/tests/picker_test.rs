//! Tests for the PR/branch picker (branch listing, fuzzy filter, open action).

use std::process::Command;

use crossterm::event::{KeyCode, KeyEvent, KeyEventKind, KeyEventState, KeyModifiers};
use prtui::data::store::new_uuid;
use prtui::picker::{Picker, PickerAction};

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
    let d = std::env::temp_dir().join(format!("prtui-pick-{}-{}", std::process::id(), new_uuid()));
    std::fs::create_dir_all(&d).unwrap();
    let d = d.to_string_lossy().to_string();
    git(&d, &["init", "-q", "-b", "main"]);
    git(&d, &["config", "user.email", "t@t"]);
    git(&d, &["config", "user.name", "t"]);
    std::fs::write(format!("{d}/a.txt"), "x\n").unwrap();
    git(&d, &["add", "-A"]);
    git(&d, &["commit", "-qm", "base"]);
    git(&d, &["branch", "feature/token-refresh"]);
    git(&d, &["branch", "bugfix/cache"]);
    d
}

fn key(c: char) -> KeyEvent {
    KeyEvent {
        code: KeyCode::Char(c),
        modifiers: KeyModifiers::NONE,
        kind: KeyEventKind::Press,
        state: KeyEventState::NONE,
    }
}
fn code(k: KeyCode) -> KeyEvent {
    KeyEvent {
        code: k,
        modifiers: KeyModifiers::NONE,
        kind: KeyEventKind::Press,
        state: KeyEventState::NONE,
    }
}

fn is_open(a: PickerAction) -> Option<String> {
    if let PickerAction::Open { arg, .. } = a {
        Some(arg)
    } else {
        None
    }
}

#[test]
fn lists_branches_and_opens_selection() {
    let mut p = Picker::new(&fixture());
    // Something is selected; Enter opens a branch.
    let arg = is_open(p.on_key(code(KeyCode::Enter))).expect("Enter opens a source");
    assert!(
        ["main", "feature/token-refresh", "bugfix/cache"].contains(&arg.as_str()),
        "opened a known branch, got {arg}"
    );
}

#[test]
fn fuzzy_filter_narrows_then_opens() {
    let mut p = Picker::new(&fixture());
    p.on_key(key('/')); // enter search mode
    for c in "cache".chars() {
        p.on_key(key(c));
    }
    p.on_key(code(KeyCode::Esc)); // back to list, filter kept
    let arg = is_open(p.on_key(code(KeyCode::Enter))).expect("opens the filtered branch");
    assert_eq!(arg, "bugfix/cache");
}

fn type_query(p: &mut Picker, q: &str) {
    p.on_key(key('/'));
    for c in q.chars() {
        p.on_key(key(c));
    }
    p.on_key(code(KeyCode::Esc));
}

#[test]
fn qualifier_is_pr_excludes_branches() {
    let mut p = Picker::new(&fixture()); // fixture has only local branches
    type_query(&mut p, "is:pr");
    assert!(
        p.visible_args().is_empty(),
        "is:pr filters out local branches"
    );
}

#[test]
fn qualifier_is_branch_keeps_branches() {
    let mut p = Picker::new(&fixture());
    type_query(&mut p, "is:branch");
    let v = p.visible_args();
    assert!(
        v.contains(&"main".to_string()) && v.contains(&"bugfix/cache".to_string()),
        "is:branch shows local branches: {v:?}"
    );
}

#[test]
fn branch_qualifier_matches_ref_name() {
    let mut p = Picker::new(&fixture());
    type_query(&mut p, "branch:token");
    assert_eq!(p.visible_args(), vec!["feature/token-refresh".to_string()]);
}

#[test]
fn q_quits() {
    let mut p = Picker::new(&fixture());
    assert!(matches!(p.on_key(key('q')), PickerAction::Quit));
}

#[test]
fn toggles_open_and_all_pr_scope() {
    let mut p = Picker::new(&fixture());
    assert!(!p.showing_all_prs());
    p.on_key(code(KeyCode::Tab));
    assert!(p.showing_all_prs());
    p.on_key(key('s'));
    assert!(!p.showing_all_prs());
}

#[test]
fn search_mode_captures_text_not_commands() {
    let mut p = Picker::new(&fixture());
    p.on_key(key('/'));
    // 'q' while searching must be filter text, not quit.
    assert!(matches!(p.on_key(key('q')), PickerAction::None));
}
