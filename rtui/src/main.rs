//! prtui — GitHub-style PR/branch review TUI (Rust/ratatui).

use std::io::stdout;
use std::time::Duration;

use crossterm::event::{self, Event};
use crossterm::execute;
use crossterm::terminal::{
    disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen,
};
use ratatui::backend::CrosstermBackend;
use ratatui::Terminal;

use prtui::app::{App, Config};
use prtui::data::source::Source;
use prtui::data::store::Store;
use prtui::picker::{Picker, PickerAction};
use prtui::ui;

enum Mode {
    Picker(Picker),
    Review(Box<App>),
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut target: Option<String> = None;
    let mut base_arg: Option<String> = None;
    let mut claude_bin_arg: Option<String> = None;
    let mut cleanup_worktrees = false;
    let mut cwd = std::env::current_dir()?.to_string_lossy().to_string();
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--base" => {
                i += 1;
                base_arg = args.get(i).cloned();
            }
            "--claude-bin" => {
                i += 1;
                claude_bin_arg = args.get(i).cloned();
            }
            "--cwd" => {
                i += 1;
                cwd = args.get(i).cloned().unwrap_or(cwd);
            }
            "--cleanup-worktrees" => cleanup_worktrees = true,
            other => target = Some(other.to_string()),
        }
        i += 1;
    }

    // Defaults < config file < CLI flags.
    let mut cfg = prtui::config::apply(Config::default(), &prtui::config::load());
    if let Some(b) = base_arg {
        cfg.base = b;
    }
    if let Some(c) = claude_bin_arg {
        cfg.claude_bin = c;
    }

    if cleanup_worktrees {
        let root = prtui::data::git::root(Some(&cwd)).ok_or("not inside a git repository")?;
        let removed =
            prtui::data::worktree::cleanup(&root, Duration::from_secs(30 * 24 * 60 * 60))?;
        println!("Removed {removed} managed worktree(s) older than 30 days.");
        return Ok(());
    }

    // Initial mode: open a target directly if given, else show the picker.
    let mode = match target.as_deref() {
        Some(t) => match build_review(t, &cwd, &cfg) {
            Ok(app) => Mode::Review(Box::new(app)),
            Err(e) => {
                eprintln!("prtui: {e}");
                std::process::exit(1);
            }
        },
        None => Mode::Picker(Picker::new(&cwd)),
    };

    // Restore the terminal even if we panic mid-loop (otherwise the shell is left in
    // raw mode + alternate screen).
    let prev_hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        let _ = disable_raw_mode();
        let _ = execute!(stdout(), LeaveAlternateScreen);
        prev_hook(info);
    }));

    enable_raw_mode()?;
    let mut out = stdout();
    execute!(out, EnterAlternateScreen)?;
    let mut terminal = Terminal::new(CrosstermBackend::new(out))?;

    let res = run(&mut terminal, mode, &cwd, &cfg);

    disable_raw_mode()?;
    execute!(terminal.backend_mut(), LeaveAlternateScreen)?;
    terminal.show_cursor()?;
    res
}

/// Build a review App from a target string (PR number / URL / branch / ".").
fn build_review(t: &str, cwd: &str, cfg: &Config) -> Result<App, String> {
    let source = if t.chars().all(|c| c.is_ascii_digit()) && !t.is_empty() {
        Source::pr(t.parse().map_err(|_| "bad PR number")?, cwd)
    } else if t.contains("/pull/") {
        let num = t
            .rsplit("/pull/")
            .next()
            .and_then(|s| s.split('/').next())
            .and_then(|s| s.parse().ok());
        match num {
            Some(n) => Source::pr(n, cwd),
            None => Source::local(cwd, Some(&cfg.base), None),
        }
    } else if t != "." && !t.is_empty() {
        Source::local(cwd, Some(&cfg.base), Some(t))
    } else {
        Source::local(cwd, Some(&cfg.base), None)
    }?;
    let store = Store::for_source(&source);
    Ok(App::new(source, store, cfg.clone()))
}

/// Suspend the TUI, run `$EDITOR <path>` (falls back to vi), then restore the TUI.
fn open_in_editor<B: ratatui::backend::Backend>(
    terminal: &mut Terminal<B>,
    path: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    let editor = std::env::var("EDITOR").unwrap_or_else(|_| "vi".into());
    disable_raw_mode()?;
    execute!(stdout(), LeaveAlternateScreen)?;
    let status = std::process::Command::new(editor).arg(path).status();
    enable_raw_mode()?;
    execute!(stdout(), EnterAlternateScreen)?;
    terminal.clear()?;
    let _ = status;
    Ok(())
}

fn run<B: ratatui::backend::Backend>(
    terminal: &mut Terminal<B>,
    mut mode: Mode,
    cwd: &str,
    cfg: &Config,
) -> Result<(), Box<dyn std::error::Error>> {
    let mut dirty = true;
    let mut input_started: Option<std::time::Instant> = None;
    loop {
        dirty |= match &mut mode {
            Mode::Picker(p) => p.poll(),
            Mode::Review(app) => app.poll_background(),
        };
        if dirty {
            let started = std::time::Instant::now();
            terminal.draw(|f| match &mut mode {
                Mode::Picker(p) => p.draw(f),
                Mode::Review(app) => ui::draw(f, app),
            })?;
            prtui::perf::record("frame.draw", started.elapsed());
            if let Some(started) = input_started.take() {
                prtui::perf::record("input.to_frame", started.elapsed());
            }
            dirty = false;
        }

        if event::poll(Duration::from_millis(60))? {
            match event::read()? {
                Event::Resize(_, _) => dirty = true,
                Event::Key(key) if key.kind == event::KeyEventKind::Press => {
                    dirty = true;
                    input_started = Some(std::time::Instant::now());
                    match &mut mode {
                        Mode::Picker(p) => match p.on_key(key) {
                            PickerAction::Quit => return Ok(()),
                            PickerAction::Open { arg, .. } => {
                                match build_review(&arg, cwd, cfg) {
                                    Ok(app) => mode = Mode::Review(Box::new(app)),
                                    Err(e) => {
                                        // Rebuild picker with an error hint in its title.
                                        let mut np = Picker::new(cwd);
                                        np.set_error(&e);
                                        mode = Mode::Picker(np);
                                    }
                                }
                            }
                            PickerAction::None => {}
                        },
                        Mode::Review(app) => {
                            app.on_key(key);
                            if app.should_quit {
                                app.flush_ui(true);
                                return Ok(());
                            }
                            if let Some(path) = app.pending_editor.take() {
                                open_in_editor(terminal, &path)?;
                                app.editor_closed(&path);
                                let exported = std::path::Path::new(&path)
                                    .parent()
                                    .is_some_and(|p| p == std::env::temp_dir())
                                    && std::path::Path::new(&path)
                                        .file_name()
                                        .and_then(|n| n.to_str())
                                        .is_some_and(|n| {
                                            n.starts_with("prtui-")
                                                && (n.ends_with(".md") || n.ends_with(".diff"))
                                        });
                                if exported {
                                    let _ = std::fs::remove_file(&path);
                                }
                            }
                            if app.request_picker {
                                app.flush_ui(true);
                                mode = Mode::Picker(Picker::new(cwd));
                            }
                        }
                    }
                }
                _ => {}
            }
        }
    }
}
