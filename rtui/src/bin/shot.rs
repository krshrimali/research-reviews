//! Headless screenshot tool: render each view to a TestBackend and emit SVG.
//! Usage: shot <repo_dir> <out_dir> [--base REF]

use crossterm::event::{KeyCode, KeyEvent, KeyEventKind, KeyEventState, KeyModifiers};
use ratatui::backend::TestBackend;
use ratatui::Terminal;

use prtui::app::{App, Config, MainTab};
use prtui::data::source::Source;
use prtui::data::store::Store;
use prtui::picker::Picker;
use prtui::screenshot::buffer_to_svg;
use prtui::ui;

fn key(c: char) -> KeyEvent {
    KeyEvent {
        code: KeyCode::Char(c),
        modifiers: KeyModifiers::NONE,
        kind: KeyEventKind::Press,
        state: KeyEventState::NONE,
    }
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let repo = args.first().cloned().expect("repo dir");
    let out = args.get(1).cloned().unwrap_or_else(|| "/tmp".into());
    let base = if let Some(i) = args.iter().position(|a| a == "--base") {
        args.get(i + 1).cloned().unwrap_or("auto".into())
    } else {
        "auto".into()
    };

    let mut source = Source::local(&repo, Some(&base), None).expect("source");
    // Seed a synthetic imported GitHub thread so the ◆ marker + conversation render
    // (the fixture is a local branch with no real PR).
    source.caps.has_threads = true;
    source.threads = vec![
        prtui::data::source::GhThread {
        id: "T_demo".into(), resolved: false, outdated: false, path: "src/auth.lua".into(), line: 1, side: "RIGHT".into(),
        comments: vec![
            prtui::data::source::GhComment { id: "GC1".into(), author: "octocat".into(),
                body: "Is `token` guaranteed to be set here? Consider a guard:\n```lua\nif not token then return nil end  -- bail early\n```".into(), created_at: String::new() },
            prtui::data::source::GhComment { id: "GC2".into(), author: "monalisa".into(),
                body: "Good catch — I'll add one.".into(), created_at: String::new() },
        ],
        },
        // An outdated thread: the code it referenced has changed since.
        prtui::data::source::GhThread {
            id: "T_old".into(), resolved: false, outdated: true, path: "src/auth.lua".into(), line: 2, side: "RIGHT".into(),
            comments: vec![
                prtui::data::source::GhComment { id: "GC3".into(), author: "octocat".into(),
                    body: "This early return looks wrong.".into(), created_at: String::new() },
            ],
        },
    ];
    // Pretend this is a real PR so the Checks panel and Actions menu render.
    source.key = "gh:acme/prtui#42".into();
    source.caps.has_checks = true;
    source.checks = vec![
        ("build".into(), "success".into()),
        ("test / unit".into(), "success".into()),
        ("test / integration".into(), "failure".into()),
        ("lint".into(), "pending".into()),
    ];
    source.reviews = vec![
        prtui::data::source::Review {
            author: "octocat".into(),
            state: "CHANGES_REQUESTED".into(),
            date: "2026-08-20T10:00:00Z".into(),
            body: "A couple of things to address before merge.".into(),
        },
        prtui::data::source::Review {
            author: "hubber".into(),
            state: "APPROVED".into(),
            date: "2026-08-21T14:30:00Z".into(),
            body: "LGTM after the last fix.".into(),
        },
    ];
    let mut store = Store::for_source(&source);
    // Seed a human comment on src/auth.lua so threads/markers render.
    store.add(
        "src/auth.lua",
        "RIGHT",
        3,
        "Should this also handle the 401 refresh path?",
        "local",
        "normal",
        None,
    );
    // A local comment whose anchored code no longer exists -> reconciled to "Outdated",
    // shown with the original code it was written against.
    let od = store.add(
        "src/auth.lua",
        "RIGHT",
        2,
        "This getter should validate the token.",
        "local",
        "normal",
        None,
    );
    store.set_anchor(&od, "function M.get() return 1 end");
    let mut cfg = Config {
        base,
        ..Config::default()
    };
    // Use a fake claude for a deterministic, offline review.
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.sh");
    if std::path::Path::new(fake).exists() {
        cfg.claude_bin = fake.to_string();
    }
    let mut app = App::new(source, store, cfg);

    let mut term = Terminal::new(TestBackend::new(120, 38))?;

    let save = |term: &mut Terminal<TestBackend>, name: &str, out: &str| {
        let svg = buffer_to_svg(term.backend().buffer());
        std::fs::write(format!("{out}/rs_{name}.svg"), svg).unwrap();
        println!("wrote rs_{name}.svg");
    };

    // Diff view (default), focus main so cursor row shows.
    app.on_key(key('l')); // open selected file -> focus main
    term.draw(|f| ui::draw(f, &mut app))?;
    save(&mut term, "diff", &out);

    // Imported GitHub thread expanded on the diff (◆ marker) — before any Claude review.
    app.on_key(key('1'));
    app.on_key(key('l')); // open src/auth.lua
    if let Some(r) = app.diff.iter().position(|d| d.new_ln == Some(1)) {
        app.diff_state.select(Some(r));
        app.on_key(key(' '));
    }
    term.draw(|f| ui::draw(f, &mut app))?;
    save(&mut term, "github_thread", &out);
    app.on_key(key(' ')); // collapse

    // Conversation
    app.on_key(key(']')); // Diff -> Conversation
    term.draw(|f| ui::draw(f, &mut app))?;
    save(&mut term, "conversation", &out);

    // Claude dispatch form
    app.on_key(key(']')); // -> Claude tab
    app.on_key(key('a'));
    term.draw(|f| ui::draw(f, &mut app))?;
    save(&mut term, "claude_form", &out);
    // Run it (Enter), then block until the async review completes.
    app.on_key(KeyEvent {
        code: KeyCode::Enter,
        modifiers: KeyModifiers::NONE,
        kind: KeyEventKind::Press,
        state: KeyEventState::NONE,
    });
    for _ in 0..200 {
        app.poll_claude();
        if app.claude_rx.is_none() {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(50));
    }
    term.draw(|f| ui::draw(f, &mut app))?;
    save(&mut term, "claude", &out);

    // Diff after the review: Claude's line comment shows as ★ on the diff.
    app.current_file = Some("src/auth.lua".into());
    app.expanded.clear();
    app.load_diff();
    app.main_tab = MainTab::Diff;
    app.panel = prtui::app::Panel::Main;
    term.draw(|f| ui::draw(f, &mut app))?;
    save(&mut term, "diff_claude", &out);

    // Expand a thread inline on the diff (space).
    if let Some(r) = app.diff.iter().position(|d| d.new_ln == Some(3)) {
        app.diff_state.select(Some(r));
    }
    app.on_key(key(' '));
    term.draw(|f| ui::draw(f, &mut app))?;
    save(&mut term, "diff_thread", &out);

    // Theme switcher — render the same diff under two other themes.
    prtui::theme::set_by_name("github-light");
    term.draw(|f| ui::draw(f, &mut app))?;
    save(&mut term, "theme_light", &out);
    prtui::theme::set_by_name("dracula");
    term.draw(|f| ui::draw(f, &mut app))?;
    save(&mut term, "theme_dracula", &out);
    prtui::theme::set_by_name("github-dark");

    // ---- follow-up walkthrough --------------------------------------------
    // The reviewer replies to the (human) thread that Claude answered…
    if let Some(t) = app
        .store
        .threads_for_file("src/auth.lua")
        .into_iter()
        .find(|t| t.origin == "local")
    {
        app.store.reply(
            &t.id,
            "But the cached token can go stale — add a short TTL?",
            "local",
        );
    }
    app.load_diff();
    app.main_tab = MainTab::Conversation;
    term.draw(|f| ui::draw(f, &mut app))?;
    save(&mut term, "conversation_thread", &out); // human → claude → reviewer reply

    // …and runs a follow-up review, which responds to that reply.
    app.on_key(key('a'));
    app.on_key(KeyEvent {
        code: KeyCode::Enter,
        modifiers: KeyModifiers::NONE,
        kind: KeyEventKind::Press,
        state: KeyEventState::NONE,
    });
    for _ in 0..200 {
        app.poll_claude();
        if app.claude_rx.is_none() {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(50));
    }
    app.main_tab = MainTab::Conversation;
    term.draw(|f| ui::draw(f, &mut app))?;
    save(&mut term, "conversation_followup", &out); // full thread incl. Claude follow-up
    app.main_tab = MainTab::Claude;
    term.draw(|f| ui::draw(f, &mut app))?;
    save(&mut term, "claude_followup", &out);

    // Wrapping: a long comment expanded inline on the diff must wrap, not clip.
    app.store.add(
        "src/auth.lua",
        "RIGHT",
        1,
        "This whole block should validate the token shape before returning it, and wrap \
         gracefully across the panel width instead of running off the right edge of the \
         terminal where it would be clipped and unreadable.",
        "local",
        "normal",
        None,
    );
    app.current_file = Some("src/auth.lua".into());
    app.expanded.clear();
    app.load_diff();
    app.main_tab = MainTab::Diff;
    app.panel = prtui::app::Panel::Main;
    if let Some(r) = app.diff.iter().position(|d| d.new_ln == Some(1)) {
        app.diff_state.select(Some(r));
        app.on_key(key(' ')); // expand the long thread
    }
    term.draw(|f| ui::draw(f, &mut app))?;
    save(&mut term, "diff_wrap", &out);

    // Comments view: all threads, grouped unresolved / resolved.
    app.on_key(key('4'));
    term.draw(|f| ui::draw(f, &mut app))?;
    save(&mut term, "comments_view", &out);

    // Publish preview (built directly since the fixture is a local branch, not a PR).
    app.publish = Some(prtui::publish::PublishView::new(
        &app.store,
        "Overall solid; a couple of small fixes before merge.",
    ));
    term.draw(|f| ui::draw(f, &mut app))?;
    save(&mut term, "publish", &out);
    app.publish = None;

    // Compose modal — select src/auth.lua (has real code lines), land on a ctx line.
    app.on_key(key('1')); // focus files
    app.on_key(key('j')); // -> src/auth.lua
    app.on_key(key('l')); // open, focus main diff
    for _ in 0..6 {
        app.on_key(key('j'));
    } // into the hunk body (addable line)
    app.on_key(key('c'));
    for ch in "should this also handle the 401 refresh path?".chars() {
        app.on_key(key(ch));
    }
    term.draw(|f| ui::draw(f, &mut app))?;
    save(&mut term, "compose", &out);

    // Visual-line selection over the diff.
    app.on_key(KeyEvent {
        code: KeyCode::Esc,
        modifiers: KeyModifiers::NONE,
        kind: KeyEventKind::Press,
        state: KeyEventState::NONE,
    });
    app.on_key(key('1'));
    app.on_key(key('l'));
    for _ in 0..5 {
        app.on_key(key('j'));
    }
    app.on_key(key('V'));
    app.on_key(key('j'));
    app.on_key(key('j'));
    term.draw(|f| ui::draw(f, &mut app))?;
    save(&mut term, "visual", &out);

    // Commit diff view (select a commit).
    app.on_key(KeyEvent {
        code: KeyCode::Esc,
        modifiers: KeyModifiers::NONE,
        kind: KeyEventKind::Press,
        state: KeyEventState::NONE,
    });
    app.on_key(key('2')); // Commits panel
    app.on_key(KeyEvent {
        code: KeyCode::Enter,
        modifiers: KeyModifiers::NONE,
        kind: KeyEventKind::Press,
        state: KeyEventState::NONE,
    });
    term.draw(|f| ui::draw(f, &mut app))?;
    save(&mut term, "commit_view", &out);

    // In-diff search.
    app.on_key(key('1'));
    app.on_key(key('l')); // back to a file diff
    app.on_key(key('/'));
    for ch in "refresh".chars() {
        app.on_key(key(ch));
    }
    term.draw(|f| ui::draw(f, &mut app))?;
    save(&mut term, "search", &out);
    app.on_key(KeyEvent {
        code: KeyCode::Enter,
        modifiers: KeyModifiers::NONE,
        kind: KeyEventKind::Press,
        state: KeyEventState::NONE,
    });

    // Conversation with the Checks panel (CI rollup) visible.
    app.on_key(KeyEvent {
        code: KeyCode::Esc,
        modifiers: KeyModifiers::NONE,
        kind: KeyEventKind::Press,
        state: KeyEventState::NONE,
    });
    app.main_tab = MainTab::Conversation;
    app.conv_scroll = 0;
    term.draw(|f| ui::draw(f, &mut app))?;
    save(&mut term, "checks", &out);

    // PR actions menu (X).
    app.on_key(key('X'));
    term.draw(|f| ui::draw(f, &mut app))?;
    save(&mut term, "actions", &out);
    app.on_key(KeyEvent {
        code: KeyCode::Esc,
        modifiers: KeyModifiers::NONE,
        kind: KeyEventKind::Press,
        state: KeyEventState::NONE,
    });

    // Split (side-by-side) diff with intra-line word-diff highlighting (auth.lua has a
    // real modified line: get -> get_or_refresh).
    app.current_file = Some("src/auth.lua".into());
    app.expanded.clear();
    app.load_diff();
    app.main_tab = MainTab::Diff;
    app.panel = prtui::app::Panel::Main;
    app.on_key(key('\\')); // enable split
    term.draw(|f| ui::draw(f, &mut app))?;
    save(&mut term, "split_diff", &out);
    app.on_key(key('\\')); // back to unified

    // Files tree with a collapsed directory (put the cursor on the src/ dir row first).
    app.on_key(key('1'));
    app.files_state.select(Some(0)); // the src/ directory row
    app.on_key(key('l')); // collapse src/
    term.draw(|f| ui::draw(f, &mut app))?;
    save(&mut term, "tree_collapsed", &out);
    app.on_key(key('l')); // expand again

    // Timeline / activity feed (commits + reviews).
    app.main_tab = MainTab::Timeline;
    term.draw(|f| ui::draw(f, &mut app))?;
    save(&mut term, "timeline", &out);

    // Reactions: add a couple to a thread, then show the picker + the chips inline.
    if let Some(root) = app
        .store
        .threads_for_file("src/auth.lua")
        .into_iter()
        .next()
    {
        app.store.toggle_reaction(&root.id, "+1", "octocat");
        app.store.toggle_reaction(&root.id, "+1", "hubber");
        app.store.toggle_reaction(&root.id, "rocket", "monalisa");
    }
    app.load_diff();
    app.main_tab = MainTab::Conversation;
    app.conv_scroll = 0;
    term.draw(|f| ui::draw(f, &mut app))?;
    save(&mut term, "reactions_chips", &out);
    // The reaction picker overlay.
    app.main_tab = MainTab::Diff;
    app.on_key(key('1'));
    app.on_key(key('j'));
    app.on_key(key('l')); // open src/auth.lua
    if let Some(r) = app.diff.iter().position(|d| d.new_ln == Some(1)) {
        app.diff_state.select(Some(r));
    }
    app.on_key(key('E'));
    term.draw(|f| ui::draw(f, &mut app))?;
    save(&mut term, "react_menu", &out);
    app.on_key(KeyEvent {
        code: KeyCode::Esc,
        modifiers: KeyModifiers::NONE,
        kind: KeyEventKind::Press,
        state: KeyEventState::NONE,
    });

    // Help
    app.on_key(KeyEvent {
        code: KeyCode::Esc,
        modifiers: KeyModifiers::NONE,
        kind: KeyEventKind::Press,
        state: KeyEventState::NONE,
    });
    app.on_key(key('?'));
    term.draw(|f| ui::draw(f, &mut app))?;
    save(&mut term, "help", &out);

    // Picker screen.
    let mut picker = Picker::new(&repo);
    std::thread::sleep(std::time::Duration::from_millis(300));
    picker.poll();
    term.draw(|f| picker.draw(f))?;
    save(&mut term, "picker", &out);

    // Picker with a live fuzzy query (shows match highlighting + qualifier help).
    picker.on_key(key('/'));
    for ch in "tok".chars() {
        picker.on_key(key(ch));
    }
    term.draw(|f| picker.draw(f))?;
    save(&mut term, "picker_search", &out);

    Ok(())
}
