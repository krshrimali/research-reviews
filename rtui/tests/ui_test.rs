//! Headless UI tests: drive real key events through App::on_key and assert on the
//! rendered ratatui buffer. This exercises navigation, tab switching, the comment
//! flow, the Claude form, and render safety at tiny sizes — no TTY required.

use std::process::Command;

use crossterm::event::{KeyCode, KeyEvent, KeyEventKind, KeyEventState, KeyModifiers};
use ratatui::backend::TestBackend;
use ratatui::buffer::Buffer;
use ratatui::Terminal;

use prtui::app::{App, Config, MainTab};
use prtui::data::source::Source;
use prtui::data::store::{new_uuid, Store};
use prtui::ui;

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
    let d = std::env::temp_dir().join(format!("prtui-ui-{}-{}", std::process::id(), new_uuid()));
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
    git(&d, &["commit", "-qm", "Add token refresh"]);
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
fn ctrl(c: char) -> KeyEvent {
    KeyEvent {
        code: KeyCode::Char(c),
        modifiers: KeyModifiers::CONTROL,
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

/// Open a changed file by leaf name through the Files *tree* (walking past directory
/// rows), leaving the Main/Diff panel focused — the tree-aware replacement for the old
/// flat-list `1` then `l`.
fn open_file(app: &mut App, leaf: &str) {
    app.on_key(key('1')); // focus Files
    for _ in 0..=app.file_rows.len() {
        let sel = app.files_state.selected().unwrap_or(0);
        if let Some(prtui::tree::FileRow::File { idx, .. }) = app.file_rows.get(sel) {
            if app.source.files[*idx].path.ends_with(leaf) {
                break;
            }
        }
        app.on_key(key('j'));
    }
    app.on_key(key('l')); // open the file, focus Main
}

/// Flatten a rendered buffer to a searchable string.
fn text(buf: &Buffer) -> String {
    let mut s = String::new();
    for y in 0..buf.area.height {
        for x in 0..buf.area.width {
            s.push_str(buf[(x, y)].symbol());
        }
        s.push('\n');
    }
    s
}

fn app_with_fixture() -> (App, String) {
    std::env::set_var(
        "PRTUI_STATE_DIR",
        std::env::temp_dir().join(format!("prtui-uistate-{}", new_uuid())),
    );
    let d = fixture();
    let source = Source::local(&d, Some("main"), None).unwrap();
    let store = Store::for_source(&source);
    (App::new(source, store, Config::default()), d)
}

fn render(app: &mut App, w: u16, h: u16) -> String {
    let mut term = Terminal::new(TestBackend::new(w, h)).unwrap();
    term.draw(|f| ui::draw(f, app)).unwrap();
    text(term.backend().buffer())
}

/// Render and return the buffer so tests can assert *styles* (fg/bg/modifiers), which the
/// glyph-only `text()` flattener drops.
fn render_buf(app: &mut App, w: u16, h: u16) -> Buffer {
    let mut term = Terminal::new(TestBackend::new(w, h)).unwrap();
    term.draw(|f| ui::draw(f, app)).unwrap();
    term.backend().buffer().clone()
}

/// True if any cell whose glyph is part of `needle` (a contiguous run on one row) carries
/// the given foreground color — used to assert syntax/word-diff coloring.
fn fg_on_text(buf: &Buffer, needle: &str, fg: ratatui::style::Color) -> bool {
    for y in 0..buf.area.height {
        let mut row = String::new();
        for x in 0..buf.area.width {
            row.push_str(buf[(x, y)].symbol());
        }
        let hay: Vec<char> = row.chars().collect();
        let wanted: Vec<char> = needle.chars().collect();
        if let Some(col) = hay.windows(wanted.len()).position(|w| w == wanted) {
            // check the cells spanning the match
            for dx in 0..needle.chars().count() {
                if buf[((col + dx) as u16, y)].fg == fg {
                    return true;
                }
            }
        }
    }
    false
}

/// True if any cell carries the given background color (e.g. selection / word-diff emphasis).
fn any_bg(buf: &Buffer, bg: ratatui::style::Color) -> bool {
    (0..buf.area.height).any(|y| (0..buf.area.width).any(|x| buf[(x, y)].bg == bg))
}

#[test]
fn initial_render_shows_panels_and_diff() {
    let (mut app, _d) = app_with_fixture();
    let out = render(&mut app, 120, 38);
    assert!(out.contains("Files"), "file panel title");
    assert!(out.contains("Commits"), "commits panel title");
    assert!(out.contains("auth.lua"), "changed file listed");
    assert!(
        out.contains("Diff")
            && out.contains("Conversation")
            && out.contains("Claude")
            && out.contains("Comments"),
        "tab bar"
    );
    assert!(out.contains("j/k move"), "status bar hints");
}

#[test]
fn tab_cycling_switches_main_view() {
    let (mut app, _d) = app_with_fixture();
    app.on_key(key(']')); // -> Conversation
    let out = render(&mut app, 120, 38);
    assert!(
        out.contains("Commits") && out.contains("commit(s) ahead"),
        "conversation body shown"
    );
    app.on_key(key(']')); // -> Timeline
    assert!(
        render(&mut app, 120, 38).contains("Activity"),
        "timeline tab shown"
    );
    app.on_key(key(']')); // -> Claude
    let out = render(&mut app, 120, 38);
    assert!(out.contains("Claude review"), "claude tab shown");
    assert!(
        out.contains("press") || out.contains("No review"),
        "claude empty-state hint"
    );
}

#[test]
fn selecting_a_file_loads_its_diff() {
    let (mut app, _d) = app_with_fixture();
    open_file(&mut app, "cache.cpp");
    let out = render(&mut app, 120, 38);
    assert!(out.contains("cache.cpp"), "cache.cpp diff header");
    assert!(out.contains("int cache"), "cache.cpp added content shown");
}

#[test]
fn comment_flow_opens_modal_and_persists() {
    let (mut app, _d) = app_with_fixture();
    open_file(&mut app, "auth.lua"); // focus main
    for _ in 0..5 {
        app.on_key(key('j'));
    } // land on a context/add line
    app.on_key(key('c')); // open compose
    let out = render(&mut app, 120, 38);
    assert!(
        out.contains("submit") && out.contains("cancel"),
        "compose modal visible"
    );
    for ch in "needs a guard here".chars() {
        app.on_key(key(ch));
    }
    app.on_key(ctrl('s')); // submit
                           // A comment should now exist in the store, and a marker should render.
    let count = app.store.all_threads().len();
    assert_eq!(count, 1, "one thread persisted after submit");
    let out = render(&mut app, 120, 38);
    assert!(
        out.contains('▸'),
        "comment marker rendered on the diff line"
    );
}

#[test]
fn actions_menu_guarded_on_local_source() {
    // A local branch has no PR, so the Actions menu (X) must decline rather than open.
    let (mut app, _d) = app_with_fixture();
    app.on_key(key('X'));
    let out = render(&mut app, 120, 38);
    assert!(
        !out.contains("key = choose"),
        "actions modal must not open for a local source"
    );
    assert!(
        app.status.contains("GitHub PR"),
        "status explains why: {}",
        app.status
    );
}

#[test]
fn claude_form_opens() {
    let (mut app, _d) = app_with_fixture();
    app.on_key(key('a'));
    let out = render(&mut app, 120, 38);
    assert!(out.contains("Claude review"), "claude form title");
    assert!(
        out.contains("allow edits") && out.contains("auto-resolve"),
        "form toggles"
    );
    assert!(
        out.contains("Critical review"),
        "instruction profiles listed"
    );
}

#[test]
fn claude_address_mode_implies_edits() {
    let (mut app, _d) = app_with_fixture();
    app.on_key(key('a'));
    app.on_key(ctrl('w'));
    match &app.modal {
        Some(prtui::app::Modal::Claude(form)) => {
            assert!(form.address_comments);
            assert!(form.allow_edits);
        }
        _ => panic!("Claude form not open"),
    }
}

#[test]
fn claude_direction_supports_multiline_and_explicit_submit() {
    let (mut app, _d) = app_with_fixture();
    app.on_key(key('a'));
    for ch in "first line".chars() {
        app.on_key(key(ch));
    }
    app.on_key(code(KeyCode::Enter));
    for ch in "second line".chars() {
        app.on_key(key(ch));
    }
    match &app.modal {
        Some(prtui::app::Modal::Claude(form)) => {
            assert_eq!(form.direction, "first line\nsecond line")
        }
        _ => panic!("enter should insert a newline, not submit"),
    }
}

#[test]
fn final_claude_prompt_round_trips_through_editor() {
    let (mut app, _d) = app_with_fixture();
    app.store.add(
        "src/auth.lua",
        "RIGHT",
        2,
        "handle the expired token case",
        "local",
        "normal",
        None,
    );
    app.on_key(key('a'));
    for ch in "Please implement carefully".chars() {
        app.on_key(key(ch));
    }
    app.on_key(ctrl('o'));
    let path = app.pending_editor.take().expect("prompt queued for editor");
    let prompt = std::fs::read_to_string(&path).unwrap();
    assert!(prompt.contains("Please implement carefully"));
    assert!(prompt.contains("handle the expired token case"));
    assert!(prompt.contains("git diff --no-ext-diff --unified=3"));
    assert!(
        !prompt.contains("function M.get_or_refresh() return 2 end"),
        "portable prompt should not embed the patch"
    );
    std::fs::write(&path, format!("{prompt}\n\nRevised externally.")).unwrap();
    app.editor_closed(&path);
    match &app.modal {
        Some(prtui::app::Modal::PromptPreview {
            prompt: revised, ..
        }) => {
            assert!(revised.contains("Revised externally."))
        }
        _ => panic!("revised prompt should open in preview"),
    }
    let _ = std::fs::remove_file(path);
}

#[test]
fn revised_prompt_can_run_from_preview() {
    let (mut app, _d) = app_with_fixture();
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.sh");
    app.cfg.claude_bin = fake.to_string();
    app.on_key(key('a'));
    app.on_key(ctrl('o'));
    let path = app.pending_editor.take().unwrap();
    let mut prompt = std::fs::read_to_string(&path).unwrap();
    prompt.push_str("\nUse this revised instruction.\n");
    std::fs::write(&path, prompt).unwrap();
    app.editor_closed(&path);
    app.on_key(ctrl('s'));
    assert!(app.modal.is_none());
    for _ in 0..200 {
        app.poll_background();
        if app.claude_rx.is_some() || app.claude_session.is_some() {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
    assert!(
        app.claude_session.is_some(),
        "revised prompt was dispatched"
    );
    let _ = std::fs::remove_file(path);
}

#[test]
fn push_toggle_implies_edit_mode() {
    let (mut app, _d) = app_with_fixture();
    app.on_key(key('a'));
    app.on_key(ctrl('p'));
    match &app.modal {
        Some(prtui::app::Modal::Claude(form)) => {
            assert!(form.push_changes);
            assert!(form.allow_edits);
        }
        _ => panic!("Claude form not open"),
    }
}

#[test]
fn edit_enabled_review_refreshes_then_uses_isolated_worktree() {
    let (mut app, d) = app_with_fixture();
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.sh");
    app.cfg.claude_bin = fake.to_string();
    app.on_key(key('a'));
    app.on_key(ctrl('e'));
    app.on_key(ctrl('s'));
    for _ in 0..300 {
        app.poll_background();
        if app.claude_rx.is_none()
            && app
                .claude_session
                .as_ref()
                .is_some_and(|session| session.state == "done")
        {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    let session = app
        .claude_session
        .as_ref()
        .expect("review session completed");
    let worktree = session
        .worktree
        .as_deref()
        .expect("edit review has a worktree");
    assert_ne!(worktree, d);
    assert_eq!(session.target_branch.as_deref(), Some("feature/x"));
    assert!(!session.push_changes, "push is opt-in");
}

#[test]
#[cfg(unix)]
fn implementation_commit_is_shown_and_worktree_is_repo_local() {
    use std::os::unix::fs::PermissionsExt;

    let (mut app, d) = app_with_fixture();
    let original = app.source.head_sha.clone();
    let fake = std::path::Path::new(&d).join(".git/fake-edit-claude.sh");
    std::fs::write(
        &fake,
        r#"#!/bin/sh
set -eu
cat >/dev/null
printf '\n-- implemented by fake review\n' >> src/auth.lua
git add src/auth.lua
git -c user.name=prtui -c user.email=prtui@example.invalid commit -qm 'Claude implementation'
head=$(git rev-parse HEAD)
python3 - "$head" <<'PY'
import json, sys
findings = {"reviewed_head_sha": sys.argv[1], "verdict": "comment", "summary": "implemented", "thread_replies": [], "new_comments": [], "resolved": [], "commits": []}
result = "```json\n" + json.dumps(findings) + "\n```"
print(json.dumps({"type": "result", "result": result}))
PY
"#,
    )
    .unwrap();
    std::fs::set_permissions(&fake, std::fs::Permissions::from_mode(0o700)).unwrap();
    app.cfg.claude_bin = fake.to_string_lossy().to_string();
    app.on_key(key('a'));
    app.on_key(ctrl('e'));
    app.on_key(ctrl('s'));
    for _ in 0..300 {
        app.poll_background();
        if app.implementation_result.is_some() {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    assert_ne!(app.source.head_sha, original);
    assert!(app
        .source
        .commits
        .iter()
        .any(|commit| commit.subject == "Claude implementation"));
    match &app.implementation_result {
        Some(result) => {
            let git_dir = std::fs::canonicalize(std::path::Path::new(&d).join(".git")).unwrap();
            assert!(std::fs::canonicalize(&result.worktree)
                .unwrap()
                .starts_with(git_dir));
        }
        _ => panic!("implementation result actions were not shown"),
    }
    let implementation = app.source.head_sha.clone();
    assert!(app.result_drawer_open);
    let screen = render(&mut app, 140, 42);
    assert!(screen.contains("Implementation · result diff visible"));
    assert!(
        screen.contains("src/"),
        "the repository view remains visible"
    );
    app.on_key(key('i'));
    assert_eq!(app.source.head_sha, original);
    app.on_key(key('i'));
    assert_eq!(app.source.head_sha, implementation);
    app.on_key(key('j'));
    assert!(
        app.result_drawer_open,
        "normal navigation must not close the drawer"
    );
    app.on_key(key('b'));
    assert_eq!(
        prtui::data::git::rev_parse("feature/x", Some(&d)).as_deref(),
        Some(implementation.as_str())
    );
    app.on_key(key('z'));
    assert!(!app.result_drawer_open);
    app.on_key(key('z'));
    assert!(app.result_drawer_open, "result can be reopened later");
}

#[test]
fn help_overlay_and_close() {
    let (mut app, _d) = app_with_fixture();
    app.on_key(key('?'));
    assert!(
        render(&mut app, 120, 38).contains("Navigation"),
        "help overlay shown"
    );
    app.on_key(key('?')); // any key closes help
    assert!(
        !render(&mut app, 120, 38).contains("top / bottom"),
        "help closed"
    );
}

#[test]
fn info_views_export_to_markdown_for_editor() {
    let (mut app, _d) = app_with_fixture();
    app.store.add(
        "src/auth.lua",
        "RIGHT",
        2,
        "review this path",
        "local",
        "normal",
        None,
    );
    for (tab, heading) in [
        (MainTab::Conversation, "# "),
        (MainTab::Timeline, "# Timeline"),
        (MainTab::Claude, "# Claude reviews"),
        (MainTab::Comments, "# Comments"),
    ] {
        app.main_tab = tab;
        app.on_key(key('O'));
        let path = app.pending_editor.take().expect("view queued for editor");
        let text = std::fs::read_to_string(&path).expect("Markdown export written");
        assert!(text.contains(heading), "{tab:?} export has its heading");
        assert!(path.ends_with(".md"), "editor receives a Markdown file");
        let _ = std::fs::remove_file(path);
    }
}

#[test]
fn diff_view_exports_complete_patch_for_editor() {
    let (mut app, _d) = app_with_fixture();
    app.main_tab = MainTab::Diff;
    app.on_key(key('O'));
    let path = app.pending_editor.take().expect("diff queued for editor");
    let text = std::fs::read_to_string(&path).unwrap();
    assert!(text.contains("diff --git") && text.contains("get_or_refresh"));
    assert!(path.ends_with(".diff"));
    let _ = std::fs::remove_file(path);
}

#[test]
fn command_palette_filters_and_opens_views() {
    let (mut app, _d) = app_with_fixture();
    app.on_key(key(':'));
    assert!(matches!(app.modal, Some(prtui::app::Modal::Palette { .. })));
    app.on_key(key('j'));
    app.on_key(code(KeyCode::Enter));
    assert_eq!(app.main_tab, MainTab::Conversation);
}

#[test]
fn view_filters_drawer_and_accelerators_are_visible() {
    let (mut app, _d) = app_with_fixture();
    app.on_key(key('4'));
    app.on_key(key('F'));
    assert_eq!(app.comment_filter, 1);
    app.on_key(key('3'));
    app.on_key(key('D'));
    assert!(app.thread_drawer);
    let out = render(&mut app, 120, 38);
    assert!(out.contains("Thread detail"));
    app.on_key(key('D'));
    let full = render(&mut app, 180, 38);
    assert!(full.contains("3 Diff") && full.contains("Comments("));
}

#[test]
fn thread_selection_assessment_and_workflow_controls() {
    let (mut app, _d) = app_with_fixture();
    let id = app.store.add(
        "src/auth.lua",
        "RIGHT",
        2,
        "fix this bug",
        "local",
        "normal",
        None,
    );
    app.on_key(key('4'));
    let _ = render(&mut app, 120, 40);
    app.on_key(key('m'));
    assert!(app.marked_threads.contains(&id));
    app.on_key(key('A'));
    match &app.modal {
        Some(prtui::app::Modal::AddressPreview { ids, rows }) => {
            assert_eq!(ids, std::slice::from_ref(&id));
            assert!(rows[0].contains("actionable"));
        }
        _ => panic!("address preview not shown"),
    }
    app.on_key(code(KeyCode::Esc));
    app.on_key(key('C'));
    assert_eq!(
        app.store.get(&id).unwrap().workflow_state,
        "needs_clarification"
    );
    app.on_key(key('L'));
    app.on_key(key('!'));
    app.on_key(key('W'));
    let thread = app.store.get(&id).unwrap();
    assert!(!thread.label.is_empty());
    assert_eq!(thread.priority, 1);
    assert_ne!(thread.action_owner, "author");
}

#[test]
fn comments_search_filters_inbox() {
    let (mut app, _d) = app_with_fixture();
    app.store.add(
        "src/auth.lua",
        "RIGHT",
        2,
        "unique needle",
        "local",
        "normal",
        None,
    );
    app.store.add(
        "src/cache.cpp",
        "RIGHT",
        1,
        "other",
        "local",
        "normal",
        None,
    );
    app.on_key(key('4'));
    app.on_key(key('/'));
    for c in "needle".chars() {
        app.on_key(key(c));
    }
    app.on_key(code(KeyCode::Enter));
    let out = render(&mut app, 120, 40);
    assert!(out.contains("unique needle"));
    assert!(!out.contains("other"));
}

#[test]
fn narrow_layout_promotes_main_view() {
    let (mut app, _d) = app_with_fixture();
    let out = render(&mut app, 70, 30);
    assert!(out.contains("get_or_refresh"));
    assert!(!out.contains("Commits (2)"));
}

#[test]
fn renders_without_panic_at_tiny_and_odd_sizes() {
    let (mut app, _d) = app_with_fixture();
    for (w, h) in [(20u16, 6u16), (1, 1), (40, 10), (200, 60), (36, 3)] {
        let _ = render(&mut app, w, h); // must not panic
    }
}

#[test]
fn every_tab_renders_without_panic_at_tiny_sizes() {
    use prtui::app::MainTab;
    let (mut app, _d) = app_with_fixture();
    // Seed a thread + reply so the Comments/Conversation views have content, and expand it.
    let root = app.store.add(
        "src/auth.lua",
        "RIGHT",
        2,
        "note\n```rs\nlet x=1;\n```",
        "local",
        "normal",
        None,
    );
    app.store.reply(&root, "reply", "local");
    open_file(&mut app, "auth.lua");
    if let Some(r) = app.diff.iter().position(|d| d.new_ln == Some(2)) {
        app.diff_state.select(Some(r));
        app.on_key(key(' ')); // expand inline thread
    }
    let tabs = [
        MainTab::Diff,
        MainTab::Conversation,
        MainTab::Timeline,
        MainTab::Claude,
        MainTab::Comments,
    ];
    for split in [false, true] {
        app.diff_split = split;
        for tab in tabs {
            app.main_tab = tab;
            for (w, h) in [(1u16, 1u16), (8, 4), (36, 3), (200, 8), (120, 40)] {
                let _ = render(&mut app, w, h); // must not panic in any tab/size/split combo
            }
        }
    }
}

#[test]
fn timeline_and_conversation_scroll() {
    use prtui::app::MainTab;
    let (mut app, _d) = app_with_fixture();
    app.panel = prtui::app::Panel::Main; // scroll keys act on the focused Main tab
    app.main_tab = MainTab::Timeline;
    let _ = render(&mut app, 120, 20);
    assert_eq!(app.timeline_scroll, 0);
    app.on_key(key('j'));
    assert!(app.timeline_scroll > 0, "j scrolls the timeline down");
    app.on_key(key('g')); // gg to top
    assert_eq!(app.timeline_scroll, 0, "g returns to the top");

    app.main_tab = MainTab::Conversation;
    let _ = render(&mut app, 120, 20);
    app.on_key(key('j'));
    assert!(app.conv_scroll > 0, "j scrolls the conversation down");
}

#[test]
fn ctrl_d_scrolls_diff_half_page() {
    let (mut app, _d) = app_with_fixture();
    open_file(&mut app, "auth.lua"); // focus main diff
    let _ = render(&mut app, 120, 38); // establishes main_h for page math
    let before = app.diff_state.selected().unwrap_or(0);
    app.on_key(ctrl('d'));
    let after = app.diff_state.selected().unwrap_or(0);
    assert!(
        after > before,
        "ctrl+d moved the diff cursor down (before={before}, after={after})"
    );
    app.on_key(ctrl('u'));
    assert!(
        app.diff_state.selected().unwrap_or(99) <= after,
        "ctrl+u moved back up"
    );
}

#[test]
fn visual_selection_comments_a_line_range() {
    let (mut app, _d) = app_with_fixture();
    open_file(&mut app, "auth.lua"); // focus main diff
    for _ in 0..5 {
        app.on_key(key('j'));
    } // land on a real (numbered) line
    app.on_key(key('V')); // start visual
    app.on_key(key('j')); // extend across the hunk (context + del + add)
    app.on_key(key('j'));
    let out = render(&mut app, 120, 38);
    assert!(out.contains("VISUAL"), "visual-mode status shown");
    app.on_key(key('c')); // comment on the range
    for ch in "these two lines need a guard".chars() {
        app.on_key(key(ch));
    }
    app.on_key(ctrl('s'));
    let threads = app.store.all_threads();
    assert_eq!(threads.len(), 1, "one thread created");
    let t = &threads[0];
    assert!(
        t.line_end > t.line_start,
        "comment spans a range (start={}, end={})",
        t.line_start,
        t.line_end
    );
    assert!(
        app.visual_anchor.is_none(),
        "visual selection cleared after commenting"
    );
}

#[test]
fn visual_selection_works_without_prefocusing_main() {
    // Reproduces the reported bug: from the default (Files) focus, press v then j/k
    // then c — it must comment on the whole range, not a single line.
    let (mut app, _d) = app_with_fixture();
    app.on_key(key('v')); // enters visual + focuses the diff
    for _ in 0..7 {
        app.on_key(key('j'));
    } // extend across the hunk
    let out = render(&mut app, 120, 38);
    assert!(
        out.contains("VISUAL"),
        "visual mode engaged from Files focus"
    );
    app.on_key(key('c'));
    for ch in "range comment".chars() {
        app.on_key(key(ch));
    }
    app.on_key(ctrl('s'));
    let threads = app.store.all_threads();
    assert_eq!(threads.len(), 1);
    assert!(
        threads[0].line_end > threads[0].line_start,
        "range comment spans multiple lines (start={}, end={})",
        threads[0].line_start,
        threads[0].line_end
    );
}

#[test]
fn claude_comment_shows_distinct_marker_on_diff() {
    let (mut app, _d) = app_with_fixture();
    // A Claude-authored comment on a RIGHT line of the shown diff.
    app.store.add(
        "src/auth.lua",
        "RIGHT",
        2,
        "cache this token",
        "claude",
        "normal",
        None,
    );
    app.load_diff();
    let out = render(&mut app, 120, 38);
    assert!(
        out.contains('★'),
        "Claude comment renders a ★ marker on the diff"
    );
}

#[test]
fn reply_to_a_thread_on_a_line() {
    let (mut app, _d) = app_with_fixture();
    app.store.add(
        "src/auth.lua",
        "RIGHT",
        2,
        "claude says cache it",
        "claude",
        "normal",
        None,
    );
    app.load_diff();
    app.on_key(key('1'));
    app.on_key(key('l')); // open auth.lua, focus main diff
                          // Move cursor to the row for new line 2.
    let row = app.diff.iter().position(|d| d.new_ln == Some(2)).unwrap();
    app.diff_state.select(Some(row));
    app.on_key(key('r'));
    let out = render(&mut app, 120, 38);
    assert!(out.contains("Reply"), "reply composer opened");
    for ch in "good point, will fix".chars() {
        app.on_key(key(ch));
    }
    app.on_key(ctrl('s'));
    let root = app
        .store
        .threads_for_file("src/auth.lua")
        .into_iter()
        .find(|t| t.line_start == 2)
        .unwrap();
    let replies = app.store.replies(&root.id);
    assert_eq!(replies.len(), 1, "reply attached to the thread");
    assert_eq!(replies[0].body, "good point, will fix");
}

#[test]
fn space_expands_thread_inline_on_diff() {
    let (mut app, _d) = app_with_fixture();
    // A thread with a reply on a diff line of the open file.
    let root = app.store.add(
        "src/auth.lua",
        "RIGHT",
        2,
        "cache this token",
        "claude",
        "normal",
        None,
    );
    app.store.reply(&root, "will add a TTL", "local");
    app.load_diff();
    app.on_key(key('1'));
    app.on_key(key('l')); // open auth.lua, focus main diff
    let row = app.diff.iter().position(|d| d.new_ln == Some(2)).unwrap();
    app.diff_state.select(Some(row));

    // Collapsed: the thread body is not in the diff yet.
    let before = render(&mut app, 120, 40);
    assert!(
        !before.contains("will add a TTL"),
        "thread body hidden until expanded"
    );

    app.on_key(key(' ')); // expand
    let after = render(&mut app, 120, 40);
    assert!(after.contains("cache this token"), "root body shown inline");
    assert!(after.contains("will add a TTL"), "reply shown inline");

    app.on_key(key(' ')); // collapse again
    let collapsed = render(&mut app, 120, 40);
    assert!(
        !collapsed.contains("will add a TTL"),
        "thread collapses again"
    );
}

#[test]
fn long_comment_wraps_and_is_not_clipped() {
    let (mut app, _d) = app_with_fixture();
    let body = "This is a deliberately long review comment that must wrap across several \
                lines so that no text is ever clipped horizontally ENDSENTINEL";
    let root = app
        .store
        .add("src/auth.lua", "RIGHT", 2, body, "claude", "normal", None);
    let _ = root;
    app.load_diff();
    app.on_key(key('1'));
    app.on_key(key('l'));
    let r = app.diff.iter().position(|d| d.new_ln == Some(2)).unwrap();
    app.diff_state.select(Some(r));
    app.on_key(key(' ')); // expand
                          // Render narrow; the sentinel at the end must still be visible (i.e. wrapped, not clipped).
    let out = render(&mut app, 72, 40);
    assert!(
        out.contains("ENDSENTINEL"),
        "end of a long wrapped comment is visible, not clipped"
    );
    // No rendered row should exceed the width (72) — TestBackend clips, so check the raw lines.
    for line in out.lines() {
        assert!(
            line.chars().count() <= 72,
            "no line exceeds the terminal width"
        );
    }
}

#[test]
fn next_prev_comment_jumps_between_threads() {
    let (mut app, _d) = app_with_fixture();
    app.store
        .add("src/auth.lua", "RIGHT", 1, "first", "local", "normal", None);
    app.store.add(
        "src/auth.lua",
        "RIGHT",
        3,
        "second",
        "local",
        "normal",
        None,
    );
    app.load_diff();
    app.on_key(key('1'));
    app.on_key(key('l')); // open auth.lua
    app.on_key(key('n')); // -> first comment
    let sel1 = app.diff_state.selected().unwrap();
    assert!(app.diff[sel1].comments > 0, "n lands on a commented line");
    let ln1 = app.diff[sel1].new_ln;
    app.on_key(key('n')); // -> next comment
    let sel2 = app.diff_state.selected().unwrap();
    assert!(
        app.diff[sel2].comments > 0,
        "n lands on the next commented line"
    );
    assert_ne!(ln1, app.diff[sel2].new_ln, "moved to a different comment");
}

#[test]
fn comments_view_lists_and_jumps() {
    let (mut app, _d) = app_with_fixture();
    let a = app.store.add(
        "src/auth.lua",
        "RIGHT",
        3,
        "unresolved one",
        "claude",
        "normal",
        None,
    );
    let b = app.store.add(
        "src/auth.lua",
        "RIGHT",
        1,
        "resolved one",
        "local",
        "normal",
        None,
    );
    app.store.set_resolved(&b, true);
    let _ = a;
    app.on_key(key('4')); // Comments tab
    let out = render(&mut app, 100, 40);
    assert!(out.contains("Unresolved (1)"), "unresolved section");
    assert!(out.contains("Resolved (1)"), "resolved section");
    assert!(out.contains("auth.lua:3"), "shows file:line");
    // Enter jumps to the selected thread's diff position.
    app.on_key(code(KeyCode::Enter));
    assert!(
        matches!(app.main_tab, MainTab::Diff),
        "jumped to the Diff tab"
    );
    assert_eq!(app.current_file.as_deref(), Some("src/auth.lua"));
}

#[test]
fn edit_delete_from_comments_view() {
    let (mut app, _d) = app_with_fixture();
    let root = app.store.add(
        "src/auth.lua",
        "RIGHT",
        3,
        "original body",
        "local",
        "normal",
        None,
    );
    app.on_key(key('4')); // Comments view
    let _ = render(&mut app, 100, 40); // fills comment_targets + selects first
                                       // Edit the selected thread.
    app.on_key(key('e'));
    // Replace the buffer: clear then type new text, submit.
    for _ in 0..40 {
        app.on_key(code(KeyCode::Backspace));
    }
    for ch in "edited body".chars() {
        app.on_key(key(ch));
    }
    app.on_key(ctrl('s'));
    assert_eq!(
        app.store.get(&root).unwrap().body,
        "edited body",
        "edit applied from Comments view"
    );
    // Delete it (confirm with y).
    let _ = render(&mut app, 100, 40);
    app.on_key(key('d'));
    app.on_key(key('y'));
    assert!(
        app.store.get(&root).is_none(),
        "delete-from-comments-view works"
    );
}

#[test]
fn hide_removes_marker_but_keeps_in_comments_view() {
    let (mut app, _d) = app_with_fixture();
    let root = app.store.add(
        "src/auth.lua",
        "RIGHT",
        2,
        "hide me please",
        "local",
        "normal",
        None,
    );
    open_file(&mut app, "auth.lua");
    let r = app.diff.iter().position(|d| d.new_ln == Some(2)).unwrap();
    app.diff_state.select(Some(r));
    assert!(app.diff[r].comments > 0, "marker present before hide");
    app.on_key(key('H')); // hide
    let r2 = app.diff.iter().position(|d| d.new_ln == Some(2)).unwrap();
    assert_eq!(app.diff[r2].comments, 0, "marker gone after hide");
    // Still present + tagged in the Comments view.
    app.on_key(key('4'));
    let out = render(&mut app, 100, 40);
    assert!(
        out.contains("(hidden)"),
        "hidden thread listed in Comments view"
    );
    assert!(app.store.get(&root).unwrap().hidden, "store records hidden");
}

#[test]
fn commit_view_shows_commit_diff_readonly() {
    let (mut app, _d) = app_with_fixture();
    app.on_key(key('2')); // focus Commits panel
    app.on_key(code(KeyCode::Enter)); // open the selected commit's diff
    assert!(app.commit_view.is_some(), "entered commit view");
    let out = render(&mut app, 120, 40);
    assert!(
        out.contains("read-only"),
        "commit view title marks it read-only"
    );
    // Commenting is disabled in commit view.
    app.on_key(key('c'));
    assert!(app.modal.is_none(), "no compose modal opens in commit view");
    // Selecting a file returns to the PR diff.
    open_file(&mut app, "auth.lua");
    assert!(
        app.commit_view.is_none(),
        "selecting a file leaves commit view"
    );
}

#[test]
fn diff_search_jumps_to_match() {
    let (mut app, _d) = app_with_fixture();
    open_file(&mut app, "auth.lua");
    app.diff_state.select(Some(0));
    app.on_key(key('/'));
    assert!(app.searching, "search mode active");
    for ch in "refresh".chars() {
        app.on_key(key(ch));
    }
    let out = render(&mut app, 120, 40);
    assert!(out.contains("/refresh"), "search prompt shows the query");
    // Cursor landed on a line containing the query.
    let sel = app.diff_state.selected().unwrap();
    assert!(
        app.diff[sel].text.to_lowercase().contains("refresh"),
        "cursor on a matching line"
    );
    app.on_key(code(KeyCode::Enter));
    assert!(!app.searching, "enter exits search");
}

#[test]
fn viewed_toggle_persists_and_shows() {
    let (mut app, d) = app_with_fixture();
    open_file(&mut app, "auth.lua"); // current file = src/auth.lua
    app.on_key(key('m')); // mark viewed (uses current file when Main focused)
    assert!(app.store.is_viewed("src/auth.lua"), "file marked viewed");
    let out = render(&mut app, 120, 40);
    assert!(out.contains("✓1/"), "files panel shows viewed progress");
    // Persists across reload.
    let src = prtui::data::source::Source::local(&d, Some("main"), None).unwrap();
    let store2 = prtui::data::store::Store::for_source(&src);
    assert!(store2.is_viewed("src/auth.lua"), "viewed state persisted");
    app.on_key(key('m')); // unmark
    assert!(!app.store.is_viewed("src/auth.lua"));
}

#[test]
fn apply_suggestion_commits_in_worktree() {
    std::env::set_var(
        "XDG_CACHE_HOME",
        std::env::temp_dir().join(format!("prtui-cache-{}", new_uuid())),
    );
    let (mut app, _d) = app_with_fixture();
    app.store.add(
        "src/auth.lua",
        "RIGHT",
        2,
        "use the refresh helper",
        "local",
        "suggestion",
        Some("function M.refreshed() return 2 end".into()),
    );
    app.load_diff();
    open_file(&mut app, "auth.lua");
    let r = app.diff.iter().position(|d| d.new_ln == Some(2)).unwrap();
    app.diff_state.select(Some(r));
    app.on_key(key('A')); // apply suggestion
    assert!(
        app.status.contains("committed"),
        "suggestion committed in a worktree: {}",
        app.status
    );
}

#[test]
fn expand_context_increases_context_lines() {
    let (mut app, _d) = app_with_fixture();
    open_file(&mut app, "auth.lua");
    assert_eq!(app.diff_context, 3, "default context");
    app.on_key(key('+'));
    assert_eq!(app.diff_context, 13, "+ expands context");
    let _ = render(&mut app, 120, 40); // must not panic with wider context
    app.on_key(key('-'));
    assert_eq!(app.diff_context, 3, "- collapses back (min 3)");
}

#[test]
fn theme_cycle_recolors() {
    let start = prtui::theme::name();
    let start_bg = prtui::theme::cur().bg;
    let next = prtui::theme::cycle();
    assert_ne!(start, next, "cycle advances the theme");
    assert_ne!(start_bg, prtui::theme::cur().bg, "background color changes");
    // restore for other tests (global state)
    prtui::theme::set_by_name(start);
}

#[test]
fn claude_review_flow_shows_markers_even_on_other_files() {
    let (mut app, _d) = app_with_fixture();
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.sh");
    if !std::path::Path::new(fake).exists() {
        return; // fake runner unavailable; skip
    }
    app.cfg.claude_bin = fake.to_string();
    // View cache.cpp so the current file is NOT the one Claude comments on (auth.lua).
    open_file(&mut app, "cache.cpp");
    assert_eq!(app.current_file.as_deref(), Some("src/cache.cpp"));

    // Run a Claude review.
    app.on_key(key('a'));
    app.on_key(ctrl('s')); // submit the form
    let mut done = false;
    for _ in 0..200 {
        app.poll_claude();
        if app.claude_rx.is_none() {
            done = true;
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(50));
    }
    assert!(done, "claude review completed");

    // A Claude comment exists on src/auth.lua.
    assert!(
        app.file_has_comments("src/auth.lua"),
        "claude comment recorded on auth.lua"
    );
    // The Files panel shows the ★ indicator (visible regardless of active tab).
    let out = render(&mut app, 120, 40);
    assert!(
        out.contains('★'),
        "files panel surfaces the Claude comment indicator"
    );
    // Switching to the diff shows the marker on the commented file.
    app.on_key(key('2')); // Diff tab
    let out2 = render(&mut app, 120, 40);
    assert!(out2.contains('★'), "diff shows the Claude marker");
}

#[test]
fn quit_key_sets_flag() {
    let (mut app, _d) = app_with_fixture();
    assert!(!app.should_quit);
    app.on_key(key('q'));
    assert!(app.should_quit, "q sets quit flag");
}

/// Set up auth.lua open with a thread (root + one reply) on line 2, expanded inline,
/// and return the root and reply ids.
fn thread_with_reply(app: &mut App) -> (String, String) {
    let root = app.store.add(
        "src/auth.lua",
        "RIGHT",
        2,
        "root body here",
        "local",
        "normal",
        None,
    );
    let reply = app.store.reply(&root, "the reply body", "local").unwrap();
    open_file(app, "auth.lua");
    let anchor = app.diff.iter().position(|d| d.new_ln == Some(2)).unwrap();
    app.diff_state.select(Some(anchor));
    app.on_key(key(' ')); // expand the thread inline
    (root, reply)
}

/// Move the diff cursor onto the first inline row belonging to `comment_id`.
fn cursor_on_comment(app: &mut App, comment_id: &str) {
    let row = app
        .diff
        .iter()
        .position(|d| {
            d.comment_id.as_deref() == Some(comment_id) && d.kind == prtui::app::DiffKind::Comment
        })
        .expect("a row for that comment");
    app.diff_state.select(Some(row));
}

#[test]
fn edit_from_reply_row_targets_that_reply() {
    let (mut app, _d) = app_with_fixture();
    let (_root, reply) = thread_with_reply(&mut app);
    cursor_on_comment(&mut app, &reply);
    app.on_key(key('e'));
    match &app.modal {
        Some(prtui::app::Modal::Compose(c)) => {
            assert_eq!(
                c.edit_of.as_deref(),
                Some(reply.as_str()),
                "edits the reply, not the root"
            );
            assert_eq!(
                c.buffer, "the reply body",
                "prefilled with the reply's body"
            );
        }
        _ => panic!("edit did not open a compose modal from the reply row"),
    }
}

#[test]
fn compose_can_round_trip_through_editor() {
    let (mut app, _d) = app_with_fixture();
    let (_root, reply) = thread_with_reply(&mut app);
    cursor_on_comment(&mut app, &reply);
    app.on_key(key('e'));
    app.on_key(ctrl('o'));
    let path = app.pending_editor.take().expect("editor request queued");
    assert_eq!(app.pending_compose_editor.as_deref(), Some(path.as_str()));
    std::fs::write(&path, "edited externally\nwith code").unwrap();
    app.editor_closed(&path);
    match &app.modal {
        Some(prtui::app::Modal::Compose(c)) => {
            assert_eq!(c.buffer, "edited externally\nwith code")
        }
        _ => panic!("compose modal should remain open after editor closes"),
    }
    let _ = std::fs::remove_file(path);
}

#[test]
fn ui_preferences_are_debounced_and_flushable() {
    let (mut app, d) = app_with_fixture();
    app.on_key(key(']'));
    assert_eq!(app.main_tab, MainTab::Conversation);
    assert!(app.flush_ui(true), "forced flush writes staged UI state");
    let source = Source::local(&d, Some("main"), None).unwrap();
    let reopened = Store::for_source(&source);
    assert_eq!(reopened.ui.tab, 1);
}

#[test]
fn manual_refresh_picks_up_new_branch_commits() {
    let (mut app, d) = app_with_fixture();
    let before = app.source.commits.len();
    std::fs::write(
        format!("{d}/src/new.rs"),
        "pub fn new_value() -> u8 { 1 }\n",
    )
    .unwrap();
    git(&d, &["add", "-A"]);
    git(&d, &["commit", "-qm", "new external commit"]);
    app.on_key(key('R'));
    for _ in 0..200 {
        if app.poll_background() && app.status.contains("refresh complete") {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
    assert_eq!(app.source.commits.len(), before + 1);
    assert!(app.source.files.iter().any(|f| f.path == "src/new.rs"));
}

#[test]
fn second_manual_refresh_key_cancels_the_active_refresh() {
    let (mut app, _d) = app_with_fixture();
    app.on_key(key('R'));
    app.on_key(key('R'));
    assert_eq!(app.status, "refresh cancelled");
}

#[test]
fn reply_from_inside_thread_targets_the_root() {
    let (mut app, _d) = app_with_fixture();
    let (root, reply) = thread_with_reply(&mut app);
    cursor_on_comment(&mut app, &reply); // cursor deep inside the thread
    app.on_key(key('r'));
    match &app.modal {
        Some(prtui::app::Modal::Compose(c)) => assert_eq!(
            c.reply_to.as_deref(),
            Some(root.as_str()),
            "reply attaches to the thread root even when composing from a reply row"
        ),
        _ => panic!("reply did not open a compose modal from inside the thread"),
    }
}

#[test]
fn delete_from_reply_row_removes_only_the_reply() {
    let (mut app, _d) = app_with_fixture();
    let (root, reply) = thread_with_reply(&mut app);
    cursor_on_comment(&mut app, &reply);
    app.on_key(key('d'));
    app.on_key(key('y')); // confirm
    assert!(app.store.get(&reply).is_none(), "reply deleted");
    assert!(app.store.get(&root).is_some(), "root thread survives");
}

#[test]
fn cursor_stays_on_thread_after_acting_from_inside() {
    let (mut app, _d) = app_with_fixture();
    let (_root, reply) = thread_with_reply(&mut app);
    cursor_on_comment(&mut app, &reply);
    // Reply to the thread from inside it.
    app.on_key(key('r'));
    for ch in "another reply".chars() {
        app.on_key(key(ch));
    }
    app.on_key(ctrl('s'));
    // After the rebuild the cursor should be at/after the anchor line (line 2), not the top.
    let sel = app.diff_state.selected().unwrap();
    let anchor = app.diff.iter().position(|d| d.new_ln == Some(2)).unwrap();
    assert!(
        sel >= anchor,
        "cursor stays on the thread's anchor, not snapped to the top (sel={sel}, anchor={anchor})"
    );
    assert_eq!(
        app.store.replies(&_root).len(),
        2,
        "the new reply was added"
    );
}

#[test]
fn react_from_reply_row_reacts_to_that_reply() {
    let (mut app, _d) = app_with_fixture();
    let (root, reply) = thread_with_reply(&mut app);
    cursor_on_comment(&mut app, &reply);
    app.on_key(key('E'));
    app.on_key(key('1')); // +1
    assert!(
        app.store.get(&reply).unwrap().reactions.contains_key("+1"),
        "reply got the reaction"
    );
    assert!(
        app.store.get(&root).unwrap().reactions.is_empty(),
        "root unaffected"
    );
}

#[test]
fn conversation_renders_fenced_code_block() {
    let (mut app, _d) = app_with_fixture();
    app.store.add(
        "src/auth.lua",
        "RIGHT",
        2,
        "before the block\n```rust\nlet x = 1; // a comment\n```\nafter the block",
        "local",
        "normal",
        None,
    );
    app.load_diff();
    app.main_tab = prtui::app::MainTab::Conversation;
    let out = render(&mut app, 120, 44);
    assert!(
        out.contains("before the block") && out.contains("after the block"),
        "prose around the fence renders"
    );
    assert!(out.contains("let x = 1;"), "code inside the fence renders");
    assert!(
        !out.contains("```"),
        "the raw ``` fence markers are not shown"
    );
}

#[test]
fn nav_bottom_lands_on_an_actionable_comment_row() {
    let (mut app, _d) = app_with_fixture();
    app.store
        .add("src/auth.lua", "RIGHT", 1, "one", "local", "normal", None);
    app.store
        .add("src/auth.lua", "RIGHT", 3, "two", "local", "normal", None);
    app.on_key(key('4')); // Comments view
    let _ = render(&mut app, 110, 40); // fills comment_targets
    app.on_key(key('G')); // jump to bottom
    let sel = app.comments_state.selected().unwrap();
    assert!(
        app.comment_targets[sel].is_some(),
        "G lands on an actionable row, not a trailing blank"
    );
}

#[test]
fn comments_view_strips_fenced_code_backticks() {
    let (mut app, _d) = app_with_fixture();
    app.store.add(
        "src/auth.lua",
        "RIGHT",
        2,
        "look:\n```rs\nlet y = 2;\n```\nok?",
        "local",
        "normal",
        None,
    );
    app.load_diff();
    app.on_key(key('4')); // Comments view
    let out = render(&mut app, 110, 40);
    assert!(
        out.contains("let y = 2;"),
        "code line shown in Comments view"
    );
    assert!(
        !out.contains("```"),
        "raw fence markers stripped in Comments view"
    );
}

#[test]
fn new_comment_records_its_anchor_code() {
    let (mut app, _d) = app_with_fixture();
    open_file(&mut app, "auth.lua");
    let r = app.diff.iter().position(|d| d.new_ln == Some(2)).unwrap();
    app.diff_state.select(Some(r));
    app.on_key(key('c'));
    for ch in "guard this".chars() {
        app.on_key(key(ch));
    }
    app.on_key(ctrl('s'));
    let root = app
        .store
        .threads_for_file("src/auth.lua")
        .into_iter()
        .next()
        .unwrap();
    let anchor = root.anchor_text.expect("anchor code captured");
    assert!(
        anchor.contains("get_or_refresh"),
        "anchor snapshots the line's code: {anchor:?}"
    );
}

#[test]
fn outdated_thread_hidden_from_diff_but_listed_in_comments() {
    use prtui::data::source::{GhComment, GhThread, Source};
    use prtui::data::store::Store;
    std::env::set_var(
        "PRTUI_STATE_DIR",
        std::env::temp_dir().join(format!("prtui-od-{}", new_uuid())),
    );
    let d = fixture();
    let mut source = Source::local(&d, Some("main"), None).unwrap();
    source.caps.has_threads = true;
    source.threads = vec![GhThread {
        id: "T1".into(),
        resolved: false,
        outdated: true,
        path: "src/auth.lua".into(),
        line: 2,
        side: "RIGHT".into(),
        comments: vec![GhComment {
            id: "C1".into(),
            author: "octocat".into(),
            body: "this line moved on".into(),
            created_at: String::new(),
        }],
    }];
    let store = Store::for_source(&source);
    let mut app = App::new(source, store, prtui::app::Config::default());
    open_file(&mut app, "auth.lua");
    // No inline marker on line 2 (outdated comments aren't shown on the diff).
    let line2 = app.diff.iter().find(|d| d.new_ln == Some(2)).unwrap();
    assert_eq!(
        line2.comments, 0,
        "outdated comment does not mark the diff line"
    );
    // It appears under the Outdated section of the Comments view.
    app.main_tab = prtui::app::MainTab::Comments;
    let out = render(&mut app, 120, 40);
    assert!(
        out.contains("Outdated (1)"),
        "outdated section lists the thread"
    );
    assert!(out.contains("(outdated)"), "the thread is tagged outdated");
}

#[test]
fn reconcile_repositions_then_outdates_through_load_diff() {
    use prtui::data::source::Source;
    use prtui::data::store::Store;
    let state = std::env::temp_dir().join(format!("prtui-rc-{}", new_uuid()));
    // Build a repo where "target" sits next to the changed line so it stays in the diff.
    let d = std::env::temp_dir().join(format!(
        "prtui-rcrepo-{}-{}",
        std::process::id(),
        new_uuid()
    ));
    std::fs::create_dir_all(&d).unwrap();
    let d = d.to_string_lossy().to_string();
    git(&d, &["init", "-q", "-b", "main"]);
    git(&d, &["config", "user.email", "t@t"]);
    git(&d, &["config", "user.name", "t"]);
    std::fs::write(format!("{d}/f.txt"), "one\ntwo\ntarget\nfour\n").unwrap();
    git(&d, &["add", "-A"]);
    git(&d, &["commit", "-qm", "base"]);
    git(&d, &["checkout", "-q", "-b", "feature"]);
    // Modify the line right after target so `target` appears as context in base...head.
    std::fs::write(format!("{d}/f.txt"), "one\ntwo\ntarget\nFOUR\n").unwrap();
    git(&d, &["add", "-A"]);
    git(&d, &["commit", "-qm", "c1"]);

    let open = |d: &str| {
        // Explicit state dir → immune to parallel tests mutating $PRTUI_STATE_DIR.
        let s = Source::local(d, Some("main"), None).unwrap();
        let st = Store::for_source_in(&s, state.clone());
        let mut a = App::new(s, st, prtui::app::Config::default());
        a.current_file = Some("f.txt".into());
        a.load_diff();
        a
    };

    // Comment on the "target" line (find it by content in the current diff).
    let mut app = open(&d);
    let (r, tline) = app
        .diff
        .iter()
        .enumerate()
        .find_map(|(i, dl)| {
            (dl.text.contains("target") && dl.new_ln.is_some()).then(|| (i, dl.new_ln.unwrap()))
        })
        .expect("target line present in the diff");
    app.diff_state.select(Some(r));
    app.on_key(key('c'));
    for ch in "check this".chars() {
        app.on_key(key(ch));
    }
    app.on_key(ctrl('s'));
    let root_id = app.store.threads_for_file("f.txt")[0].id.clone();
    assert_eq!(app.store.get(&root_id).unwrap().line_start, tline);

    // Insert two lines above target, so it moves to line 5 → reconcile should follow it.
    std::fs::write(format!("{d}/f.txt"), "x\ny\none\ntwo\ntarget\nFOUR\n").unwrap();
    git(&d, &["add", "-A"]);
    git(&d, &["commit", "-qm", "c2"]);
    let app2 = open(&d); // App::new + load_diff runs reconcile
    let moved = app2.store.get(&root_id).unwrap();
    assert!(!moved.outdated, "still valid after a pure move");
    assert_eq!(
        moved.line_start,
        tline + 2,
        "comment repositioned by the two inserted lines"
    );

    // Now change the target line's content → reconcile should mark it outdated.
    std::fs::write(format!("{d}/f.txt"), "x\ny\none\ntwo\nCHANGED\nFOUR\n").unwrap();
    git(&d, &["add", "-A"]);
    git(&d, &["commit", "-qm", "c3"]);
    let app3 = open(&d);
    assert!(
        app3.store.get(&root_id).unwrap().outdated,
        "comment marked outdated when its code changed"
    );
}

#[test]
fn syntax_highlight_colors_keywords_in_the_diff() {
    prtui::theme::set_by_name("github-dark");
    let (mut app, _d) = app_with_fixture();
    open_file(&mut app, "auth.lua");
    let buf = render_buf(&mut app, 120, 38);
    // `function` / `local` / `return` are keywords → accent fg (not plain text fg).
    assert!(
        fg_on_text(&buf, "local", prtui::theme::cur().accent)
            || fg_on_text(&buf, "return", prtui::theme::cur().accent),
        "a language keyword is rendered in the accent color"
    );
}

#[test]
fn word_diff_emphasis_paints_changed_words() {
    prtui::theme::set_by_name("github-dark");
    let (mut app, _d) = app_with_fixture();
    open_file(&mut app, "auth.lua"); // line 2: get() return 1  ->  get_or_refresh() return 2
    let buf = render_buf(&mut app, 120, 38);
    // The changed words get the emphasized add/del background.
    assert!(
        any_bg(&buf, prtui::theme::add_emph_bg()) || any_bg(&buf, prtui::theme::del_emph_bg()),
        "word-diff paints an emphasized background on changed words"
    );
}

#[test]
fn split_view_cursor_highlights_a_row() {
    prtui::theme::set_by_name("github-dark");
    let (mut app, _d) = app_with_fixture();
    open_file(&mut app, "auth.lua");
    // Put the cursor on the modified (new) line 2, then switch to split view.
    let r = app.diff.iter().position(|d| d.new_ln == Some(2)).unwrap();
    app.diff_state.select(Some(r));
    app.on_key(key('\\'));
    let buf = render_buf(&mut app, 120, 38);
    assert!(
        any_bg(&buf, prtui::theme::sel_bg()),
        "the cursor row is highlighted in split view"
    );
}

#[test]
fn split_view_toggles_and_renders_both_sides() {
    let (mut app, _d) = app_with_fixture();
    open_file(&mut app, "auth.lua");
    assert!(!app.diff_split, "unified by default");
    app.on_key(key('\\'));
    assert!(app.diff_split, "backslash enables split view");
    let out = render(&mut app, 120, 38);
    assert!(out.contains('│'), "split view shows the column separator");
    // The renamed function appears on the new (right) side.
    assert!(
        out.contains("get_or_refresh"),
        "new side content shown in split view"
    );
    for line in out.lines() {
        assert!(
            line.chars().count() <= 120,
            "split view never exceeds terminal width"
        );
    }
    app.on_key(key('\\'));
    assert!(!app.diff_split, "backslash toggles back to unified");
}

#[test]
fn word_diff_annotates_modified_lines() {
    let (mut app, _d) = app_with_fixture();
    open_file(&mut app, "auth.lua");
    // auth.lua modifies a line (get -> get_or_refresh), so a paired add/del must carry
    // intra-line word-diff highlighting.
    let any_hl = app.diff.iter().any(|d| d.word_hl.is_some());
    assert!(any_hl, "a modified line has word-diff highlighting");
}

#[test]
fn files_tree_collapses_and_expands_directory() {
    use prtui::tree::FileRow;
    let has_files = |app: &App| {
        app.file_rows
            .iter()
            .any(|r| matches!(r, FileRow::File { .. }))
    };
    let (mut app, _d) = app_with_fixture();
    app.on_key(key('1')); // focus Files; row 0 is the src/ directory
    assert!(
        matches!(app.file_rows[0], FileRow::Dir { .. }),
        "first row is a directory"
    );
    assert!(has_files(&app), "file rows visible while expanded");
    let _ = render(&mut app, 120, 38);
    app.on_key(key('l')); // collapse src/
    assert!(
        !has_files(&app),
        "file rows hidden when directory collapsed"
    );
    match &app.file_rows[0] {
        FileRow::Dir { collapsed, .. } => assert!(*collapsed, "dir marked collapsed"),
        _ => panic!("dir row"),
    }
    let _ = render(&mut app, 120, 38); // must still render fine
    app.on_key(key('l')); // expand again
    assert!(has_files(&app), "file rows visible again after expand");
}

#[test]
fn timeline_tab_shows_commits() {
    let (mut app, _d) = app_with_fixture();
    app.main_tab = prtui::app::MainTab::Timeline;
    let out = render(&mut app, 120, 38);
    assert!(out.contains("Activity"), "timeline header");
    assert!(
        out.contains("Add token refresh"),
        "commit shown in the feed"
    );
}

#[test]
fn react_menu_adds_reaction_and_chip_renders() {
    let (mut app, _d) = app_with_fixture();
    app.store.add(
        "src/auth.lua",
        "RIGHT",
        2,
        "please react",
        "local",
        "normal",
        None,
    );
    open_file(&mut app, "auth.lua");
    let r = app.diff.iter().position(|d| d.new_ln == Some(2)).unwrap();
    app.diff_state.select(Some(r));
    app.on_key(key('E')); // open reaction picker
    let out = render(&mut app, 120, 38);
    assert!(
        out.contains("React") && out.contains("rocket"),
        "reaction picker shown"
    );
    app.on_key(key('1')); // toggle the first reaction (+1)
    let root = app
        .store
        .threads_for_file("src/auth.lua")
        .into_iter()
        .find(|t| t.line_start == 2)
        .unwrap();
    assert!(
        root.reactions.contains_key("+1"),
        "reaction recorded on the thread"
    );
    // The chip renders in the Conversation view.
    app.main_tab = prtui::app::MainTab::Conversation;
    let conv = render(&mut app, 120, 38);
    assert!(
        conv.contains("[+1 1]"),
        "reaction chip rendered: shows count"
    );
}
