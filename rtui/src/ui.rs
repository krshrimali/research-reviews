//! Rendering. Immediate-mode: the whole screen is drawn from App state each frame.

use ratatui::layout::{Constraint, Direction, Layout, Rect};
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{
    Block, BorderType, Borders, Clear, List, ListItem, ListState, Paragraph, Wrap,
};
use ratatui::Frame;

use crate::app::{App, DiffKind, MainTab, Modal, Panel};
use crate::data::store::Comment;
use crate::theme as t;

/// Word-wrap `s` to `width` columns (char-based), hard-breaking over-long words.
/// Guarantees every returned line fits, so nothing is clipped horizontally.
pub fn wrap(s: &str, width: usize) -> Vec<String> {
    // Honor embedded newlines: wrap each logical line independently.
    if s.contains('\n') {
        let mut out = Vec::new();
        for line in s.split('\n') {
            out.extend(wrap(line, width));
        }
        return out;
    }
    let width = width.max(1);
    let mut out: Vec<String> = Vec::new();
    let mut cur = String::new();
    let mut cur_w = 0usize;
    let push_word = |word: &str, out: &mut Vec<String>, cur: &mut String, cur_w: &mut usize| {
        let wlen = word.chars().count();
        if *cur_w != 0 && *cur_w + 1 + wlen <= width {
            cur.push(' ');
            cur.push_str(word);
            *cur_w += 1 + wlen;
        } else if wlen <= width {
            if *cur_w != 0 {
                out.push(std::mem::take(cur));
            }
            *cur = word.to_string();
            *cur_w = wlen;
        } else {
            // hard-break a word longer than the width
            if *cur_w != 0 {
                out.push(std::mem::take(cur));
                *cur_w = 0;
            }
            let mut chunk = String::new();
            let mut cw = 0;
            for ch in word.chars() {
                if cw == width {
                    out.push(std::mem::take(&mut chunk));
                    cw = 0;
                }
                chunk.push(ch);
                cw += 1;
            }
            *cur = chunk;
            *cur_w = cw;
        }
    };
    for word in s.split(' ') {
        push_word(word, &mut out, &mut cur, &mut cur_w);
    }
    out.push(cur);
    if out.is_empty() {
        out.push(String::new());
    }
    out
}

fn panel_block(title: &str, focused: bool) -> Block<'static> {
    let border = if focused {
        t::border_focus()
    } else {
        t::border()
    };
    let title_style = if focused {
        Style::default()
            .fg(t::border_focus())
            .add_modifier(Modifier::BOLD)
    } else {
        Style::default().fg(t::muted())
    };
    Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(Style::default().fg(border))
        .title(Span::styled(format!(" {title} "), title_style))
        .style(Style::default().bg(t::panel()))
}

pub fn draw(f: &mut Frame, app: &mut App) {
    // The Publish view takes over the whole screen when open.
    if let Some(pv) = &app.publish {
        pv.draw(f);
        return;
    }
    // Full background.
    f.render_widget(
        Block::default().style(Style::default().bg(t::bg())),
        f.area(),
    );

    let root = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Min(3), Constraint::Length(1)])
        .split(f.area());

    if root[0].width < 82 {
        draw_main(f, app, root[0]);
    } else {
        let body = Layout::default()
            .direction(Direction::Horizontal)
            .constraints([Constraint::Length(36), Constraint::Min(20)])
            .split(root[0]);
        let sidebar = Layout::default()
            .direction(Direction::Vertical)
            .constraints([Constraint::Percentage(60), Constraint::Percentage(40)])
            .split(body[0]);
        draw_files(f, app, sidebar[0]);
        draw_commits(f, app, sidebar[1]);
        draw_main(f, app, body[1]);
    }
    draw_status(f, app, root[1]);

    if app.result_drawer_open {
        if let Some(result) = &app.implementation_result {
            draw_edit_result(f, result);
        }
    }

    if let Some(modal) = &app.modal {
        match modal {
            Modal::Compose(_) => draw_compose(f, app),
            Modal::Claude(_) => draw_claude_form(f, app),
            Modal::Confirm { prompt, .. } => draw_confirm(f, prompt),
            Modal::Actions(items) => draw_actions(f, items),
            Modal::React { .. } => draw_react(f),
            Modal::Palette { query, selected } => draw_palette(f, query, *selected),
            Modal::AddressPreview { rows, .. } => draw_address_preview(f, rows),
            Modal::Summary(rows) => draw_summary(f, rows),
            Modal::PromptPreview { prompt, .. } => draw_prompt_preview(f, prompt),
        }
    }
    if app.show_help {
        draw_help(f);
    }
}

fn draw_files(f: &mut Frame, app: &mut App, area: Rect) {
    use crate::tree::FileRow;
    let focused = app.panel == Panel::Files;
    // One pass over the store instead of threads_for_file()+replies() per file row.
    let summary = app.store.file_comment_summary();
    let items: Vec<ListItem> = app
        .file_rows
        .iter()
        .map(|row| {
            match row {
                FileRow::Dir {
                    name,
                    depth,
                    collapsed,
                    nfiles,
                    ..
                } => {
                    let indent = "  ".repeat(*depth);
                    let caret = if *collapsed { "▸" } else { "▾" };
                    ListItem::new(Line::from(vec![
                        Span::raw(indent),
                        Span::styled(format!("{caret} "), Style::default().fg(t::muted())),
                        Span::styled(
                            format!("{name}/"),
                            Style::default()
                                .fg(t::accent())
                                .add_modifier(Modifier::BOLD),
                        ),
                        Span::styled(format!("  {nfiles}"), Style::default().fg(t::muted())),
                    ]))
                }
                FileRow::File { idx, depth } => {
                    let file = &app.source.files[*idx];
                    let viewed = app.store.is_viewed(&file.path);
                    let indent = "  ".repeat(*depth);
                    let mut spans = vec![
                        Span::raw(indent),
                        Span::styled(
                            if viewed { "✓ " } else { "  " },
                            Style::default().fg(t::green()),
                        ),
                    ];
                    let dot = match file.status.as_str() {
                        "added" => Span::styled("+ ", Style::default().fg(t::green())),
                        "deleted" => Span::styled("- ", Style::default().fg(t::red())),
                        "renamed" => Span::styled("» ", Style::default().fg(t::purple())),
                        _ => Span::styled("● ", Style::default().fg(t::yellow())),
                    };
                    spans.push(dot);
                    // Show only the leaf name in the tree; renames show old→new leaves.
                    let leaf = |p: &str| p.rsplit('/').next().unwrap_or(p).to_string();
                    let name = if file.status == "renamed" {
                        match &file.old_path {
                            Some(old) => format!("{} → {}", leaf(old), leaf(&file.path)),
                            None => leaf(&file.path),
                        }
                    } else {
                        leaf(&file.path)
                    };
                    spans.push(Span::styled(
                        name,
                        Style::default().fg(if viewed { t::muted() } else { t::text() }),
                    ));
                    if file.additions > 0 {
                        spans.push(Span::styled(
                            format!("  +{}", file.additions),
                            Style::default().fg(t::green()),
                        ));
                    }
                    if file.deletions > 0 {
                        spans.push(Span::styled(
                            format!(" -{}", file.deletions),
                            Style::default().fg(t::red()),
                        ));
                    }
                    if let Some(&(total, has_claude, has_github)) = summary.get(&file.path) {
                        if total > 0 {
                            let (icon, color) = if has_claude {
                                ("★", t::purple())
                            } else if has_github {
                                ("◆", t::accent())
                            } else {
                                ("▸", t::yellow())
                            };
                            spans.push(Span::styled(
                                format!("  {icon}{total}"),
                                Style::default().fg(color).add_modifier(Modifier::BOLD),
                            ));
                        }
                    }
                    ListItem::new(Line::from(spans))
                }
            }
        })
        .collect();

    let nfiles = app.source.files.len();
    let nviewed = app
        .source
        .files
        .iter()
        .filter(|f| app.store.is_viewed(&f.path))
        .count();
    let title = format!("Files (1)  {}  ✓{}/{}", nfiles, nviewed, nfiles);
    let list = List::new(items)
        .block(panel_block(&title, focused))
        .highlight_style(
            Style::default()
                .bg(t::sel_bg())
                .add_modifier(Modifier::BOLD),
        )
        .highlight_symbol("");
    f.render_stateful_widget(list, area, &mut app.files_state);
}

fn draw_commits(f: &mut Frame, app: &mut App, area: Rect) {
    let focused = app.panel == Panel::Commits;
    let items: Vec<ListItem> = app
        .source
        .commits
        .iter()
        .map(|c| {
            let subject: String = c.subject.chars().take(40).collect();
            ListItem::new(Line::from(vec![
                Span::styled(format!("{} ", c.short), Style::default().fg(t::yellow())),
                Span::styled(subject, Style::default().fg(t::text())),
            ]))
        })
        .collect();
    let list = List::new(items)
        .block(panel_block(
            &format!("Commits (2)  {}", app.source.commits.len()),
            focused,
        ))
        .highlight_style(
            Style::default()
                .bg(t::sel_bg())
                .add_modifier(Modifier::BOLD),
        );
    f.render_stateful_widget(list, area, &mut app.commits_state);
}

fn tab_title(app: &App, compact: bool) -> Line<'static> {
    let mk = |label: &str, active: bool| {
        if active {
            Span::styled(
                format!(" {label} "),
                Style::default()
                    .fg(t::bg())
                    .bg(t::accent())
                    .add_modifier(Modifier::BOLD),
            )
        } else {
            Span::styled(format!(" {label} "), Style::default().fg(t::muted()))
        }
    };
    Line::from(vec![
        mk(
            if compact { "D" } else { "3 Diff" },
            app.main_tab == MainTab::Diff,
        ),
        Span::raw(" "),
        mk(
            if compact { "Cv" } else { "Conversation" },
            app.main_tab == MainTab::Conversation,
        ),
        Span::raw(" "),
        mk(
            if compact { "T" } else { "Timeline" },
            app.main_tab == MainTab::Timeline,
        ),
        Span::raw(" "),
        mk(
            &format!(
                "{}{}",
                if compact { "Cl" } else { "Claude" },
                if app.claude_rx.is_some() { " ●" } else { "" }
            ),
            app.main_tab == MainTab::Claude,
        ),
        Span::raw(" "),
        mk(
            &format!(
                "{}({})",
                if compact { "Cm" } else { "Comments" },
                app.store.all_threads().len()
            ),
            app.main_tab == MainTab::Comments,
        ),
    ])
}

fn draw_main(f: &mut Frame, app: &mut App, area: Rect) {
    let focused = app.panel == Panel::Main;
    let title = match &app.commit_view {
        Some(sha) if app.main_tab == MainTab::Diff => {
            format!("commit {} (read-only)", &sha[..sha.len().min(8)])
        }
        _ => app.source.title.clone(),
    };
    // Border titles do not reserve space from one another. Keep the repository/PR title
    // inside the space left of the right-aligned tabs so long branch names cannot paint
    // underneath the active-tab background.
    let compact_tabs = area.width < 80;
    let tab_reserve = if compact_tabs { 33 } else { 67 };
    let max_title = (area.width as usize).saturating_sub(tab_reserve).max(4);
    let title = if title.chars().count() > max_title {
        format!(
            "{}…",
            title
                .chars()
                .take(max_title.saturating_sub(1))
                .collect::<String>()
        )
    } else {
        title
    };
    let block =
        panel_block(&title, focused).title_top(tab_title(app, compact_tabs).right_aligned());
    let inner = block.inner(area);
    app.main_h = inner.height; // for ^d/^u/^f/^b page scrolling
    f.render_widget(block, area);
    if app.thread_drawer && matches!(app.main_tab, MainTab::Diff | MainTab::Conversation) {
        let panes = Layout::default()
            .direction(Direction::Horizontal)
            .constraints([Constraint::Percentage(62), Constraint::Percentage(38)])
            .split(inner);
        match app.main_tab {
            MainTab::Diff if app.diff_split => draw_diff_split(f, app, panes[0]),
            MainTab::Diff => draw_diff(f, app, panes[0]),
            _ => draw_conversation(f, app, panes[0]),
        }
        draw_thread_drawer(f, app, panes[1]);
        return;
    }
    match app.main_tab {
        MainTab::Diff if app.diff_split => draw_diff_split(f, app, inner),
        MainTab::Diff => draw_diff(f, app, inner),
        MainTab::Conversation => draw_conversation(f, app, inner),
        MainTab::Timeline => draw_timeline(f, app, inner),
        MainTab::Claude => draw_claude(f, app, inner),
        MainTab::Comments => draw_comments(f, app, inner),
    }
}

fn draw_thread_drawer(f: &mut Frame, app: &App, area: Rect) {
    let block = panel_block("Thread detail · D close", true);
    let inner = block.inner(area);
    f.render_widget(block, area);
    let root = app
        .diff_state
        .selected()
        .and_then(|i| app.diff.get(i))
        .and_then(|d| d.comment_id.as_deref())
        .map(|id| app.store.root_of(id))
        .and_then(|id| app.store.get(&id));
    let mut lines = Vec::new();
    if let Some(root) = root {
        thread_lines(&app.store, root, &mut lines);
    } else {
        lines.push(Line::from(Span::styled(
            "Select a commented diff line.",
            Style::default().fg(t::muted()),
        )));
    }
    f.render_widget(Paragraph::new(lines).wrap(Wrap { trim: false }), inner);
}

/// The "Comments" view: all threads, grouped into Unresolved / Resolved / Outdated.
/// Selecting a row (enter) jumps to that thread's diff position (outdated threads aren't
/// on the current diff, so they aren't jump targets). Fills app.comment_targets.
fn draw_comments(f: &mut Frame, app: &mut App, area: Rect) {
    let width = area.width as usize;
    let mut all = app.store.all_threads();
    if !app.comment_query.is_empty() {
        let q = app.comment_query.to_lowercase();
        all.retain(|c| {
            [
                c.file.as_str(),
                c.author.as_str(),
                c.body.as_str(),
                c.label.as_str(),
                c.workflow_state.as_str(),
            ]
            .iter()
            .any(|v| v.to_lowercase().contains(&q))
        });
    }
    let mut outdated: Vec<_> = all.iter().filter(|t| t.outdated).cloned().collect();
    let mut unresolved: Vec<_> = all
        .iter()
        .filter(|t| !t.outdated && t.status != "resolved")
        .cloned()
        .collect();
    let mut resolved: Vec<_> = all
        .iter()
        .filter(|t| !t.outdated && t.status == "resolved")
        .cloned()
        .collect();
    match app.comment_filter {
        1 => {
            resolved.clear();
            outdated.clear();
        }
        2 => {
            unresolved.clear();
            outdated.clear();
        }
        3 => {
            let is_claude = |c: &crate::data::store::Comment| {
                c.origin == "claude"
                    || app
                        .store
                        .replies(&c.id)
                        .iter()
                        .any(|r| r.origin == "claude")
            };
            unresolved.retain(&is_claude);
            resolved.retain(&is_claude);
            outdated.retain(&is_claude);
        }
        4 => {
            let keep = |c: &crate::data::store::Comment| {
                c.workflow_state == "needs_clarification" || c.assessment == "needs clarification"
            };
            unresolved.retain(&keep);
            resolved.retain(&keep);
            outdated.retain(&keep);
        }
        5 => {
            let keep = |c: &crate::data::store::Comment| {
                matches!(
                    c.workflow_state.as_str(),
                    "committed" | "pushed" | "verified"
                )
            };
            unresolved.retain(&keep);
            resolved.retain(&keep);
            outdated.retain(&keep);
        }
        6 => {
            let keep = |c: &crate::data::store::Comment| {
                !c.push_state.is_empty() && c.push_state != "pushed"
            };
            unresolved.retain(&keep);
            resolved.retain(&keep);
            outdated.retain(&keep);
        }
        7 => {
            let keep = |c: &crate::data::store::Comment| app.marked_threads.contains(&c.id);
            unresolved.retain(&keep);
            resolved.retain(&keep);
            outdated.retain(&keep);
        }
        _ => {}
    }
    for v in [&mut unresolved, &mut resolved, &mut outdated] {
        v.sort_by(|a, b| a.file.cmp(&b.file).then(a.line_start.cmp(&b.line_start)));
    }

    let mut items: Vec<ListItem> = Vec::new();
    let mut targets: Vec<Option<(String, u32, String)>> = Vec::new();

    let section = |title: String,
                   hl: ratatui::style::Color,
                   list: &[crate::data::store::Comment],
                   items: &mut Vec<ListItem>,
                   targets: &mut Vec<Option<(String, u32, String)>>,
                   store: &crate::data::store::Store,
                   marked: &std::collections::HashSet<String>| {
        items.push(ListItem::new(Line::from(Span::styled(
            title,
            Style::default().fg(hl).add_modifier(Modifier::BOLD),
        ))));
        targets.push(None);
        if list.is_empty() {
            items.push(ListItem::new(Line::from(Span::styled(
                "  (none)",
                Style::default().fg(t::muted()),
            ))));
            targets.push(None);
        }
        for root in list {
            let claude = root.origin == "claude"
                || store.replies(&root.id).iter().any(|r| r.origin == "claude");
            let github = root.origin == "github"
                || store.replies(&root.id).iter().any(|r| r.origin == "github");
            let icon = if claude {
                "★"
            } else if github {
                "◆"
            } else {
                "▸"
            };
            let nrep = store.replies(&root.id).len();
            let owner = if root.action_owner.is_empty() {
                store
                    .replies(&root.id)
                    .last()
                    .map(|r| {
                        if r.origin == "local" {
                            "reviewer"
                        } else {
                            "author"
                        }
                    })
                    .unwrap_or("author")
            } else {
                root.action_owner.as_str()
            };
            let head = format!(
                "{} {icon} {}:{}  {}  [{} · next:{owner}]{}{}{}{}{}",
                if marked.contains(&root.id) {
                    "[x]"
                } else {
                    "[ ]"
                },
                root.file,
                root.line_start,
                root.author,
                if root.workflow_state.is_empty() {
                    "unresolved"
                } else {
                    &root.workflow_state
                },
                if nrep > 0 {
                    format!("  ({nrep} repl{})", if nrep == 1 { "y" } else { "ies" })
                } else {
                    String::new()
                },
                if root.outdated { "  (outdated)" } else { "" },
                if root.hidden { "  (hidden)" } else { "" },
                if root.label.is_empty() {
                    String::new()
                } else {
                    format!("  #{}", root.label)
                },
                root.implementation_commit
                    .as_ref()
                    .map(|c| format!("  commit:{}", &c[..c.len().min(8)]))
                    .unwrap_or_default()
            );
            let head = if root.priority > 0 {
                format!("P{} {head}", root.priority)
            } else {
                head
            };
            let mut lines = vec![Line::from(Span::styled(
                head,
                Style::default().fg(if claude { t::purple() } else { t::accent() }),
            ))];
            if root.hidden {
                lines.push(Line::from(Span::styled(
                    "    (hidden)",
                    Style::default().fg(t::muted()),
                )));
            }
            // Show the original code an outdated comment was written against (wrapped so it
            // never clips in this list view).
            if root.outdated {
                if let Some(code) = root.anchor_text.as_deref().filter(|s| !s.is_empty()) {
                    for chunk in wrap(code, width.saturating_sub(9)) {
                        lines.push(Line::from(Span::styled(
                            format!("    was: {chunk}"),
                            Style::default()
                                .fg(t::muted())
                                .add_modifier(Modifier::ITALIC),
                        )));
                    }
                }
            }
            // Render prose wrapped and fenced code with the language from the fence (falling
            // back to the reviewed file's extension).
            let fallback_ext = crate::syntax::ext_of(&root.file);
            let mut code_ext: Option<String> = None;
            for raw in root.body.lines() {
                if let Some(lang) = raw.trim_start().strip_prefix("```") {
                    if code_ext.is_some() {
                        code_ext = None;
                    } else {
                        let lang = lang.trim();
                        code_ext = Some(if lang.is_empty() || lang == "suggestion" {
                            fallback_ext.clone()
                        } else {
                            lang_to_ext(lang)
                        });
                    }
                    continue;
                }
                if let Some(ext) = &code_ext {
                    lines.push(code_line("    ", raw, ext));
                } else {
                    for chunk in wrap(raw, width.saturating_sub(4)) {
                        lines.push(Line::from(Span::styled(
                            format!("    {chunk}"),
                            Style::default().fg(t::text()),
                        )));
                    }
                }
            }
            items.push(ListItem::new(lines));
            // Outdated threads aren't on the current diff, so they can't be jumped to.
            targets.push(
                (!root.outdated).then(|| (root.file.clone(), root.line_start, root.id.clone())),
            );
        }
        items.push(ListItem::new(Line::raw("")));
        targets.push(None);
    };

    section(
        format!("Unresolved ({})", unresolved.len()),
        t::yellow(),
        &unresolved,
        &mut items,
        &mut targets,
        &app.store,
        &app.marked_threads,
    );
    section(
        format!("Resolved ({})", resolved.len()),
        t::green(),
        &resolved,
        &mut items,
        &mut targets,
        &app.store,
        &app.marked_threads,
    );
    if !outdated.is_empty() {
        section(
            format!("Outdated ({})", outdated.len()),
            t::muted(),
            &outdated,
            &mut items,
            &mut targets,
            &app.store,
            &app.marked_threads,
        );
    }

    app.comment_targets = targets;
    if app.comments_state.selected().is_none() && !app.comment_targets.is_empty() {
        // start on the first actionable row
        let first = app
            .comment_targets
            .iter()
            .position(|t| t.is_some())
            .unwrap_or(0);
        app.comments_state.select(Some(first));
    }

    let hint = "  j/k move · enter jump to diff · n/N next/prev on diff";
    let list = List::new(items)
        .highlight_style(
            Style::default()
                .bg(t::sel_bg())
                .add_modifier(Modifier::BOLD),
        )
        .highlight_symbol("");
    f.render_stateful_widget(list, area, &mut app.comments_state);
    let _ = hint;
}

/// Build syntax-highlighted spans for a code diff line (`+`/`-`/` ` prefixed). Plain
/// tokens keep the add/del/context fg so the diff still reads; keywords/strings/etc.
/// get syntax colors on top of the line's bg tint.
fn highlight_code_line(text: &str, kind: DiffKind, ext: &str) -> Vec<Span<'static>> {
    let (bg, base_fg) = match kind {
        DiffKind::Add => (Some(t::add_bg()), t::green()),
        DiffKind::Del => (Some(t::del_bg()), t::red()),
        _ => (None, t::text()),
    };
    let mut chars = text.chars();
    let sign = chars.next().unwrap_or(' ');
    let code: String = chars.collect();
    let style = |fg: ratatui::style::Color| {
        let mut s = Style::default().fg(fg);
        if let Some(b) = bg {
            s = s.bg(b);
        }
        s
    };
    let mut spans = vec![Span::styled(sign.to_string(), style(base_fg))];
    for (txt, tok) in crate::syntax::highlight(&code, ext) {
        let fg = match tok {
            crate::syntax::Tok::Keyword => t::accent(),
            crate::syntax::Tok::Str => t::yellow(),
            crate::syntax::Tok::Number => t::purple(),
            crate::syntax::Tok::Comment => t::muted(),
            crate::syntax::Tok::Plain => base_fg,
        };
        // Render code comments in italic so they read clearly as prose within the code.
        let mut st = style(fg);
        if tok == crate::syntax::Tok::Comment {
            st = st.add_modifier(Modifier::ITALIC);
        }
        spans.push(Span::styled(txt, st));
    }
    spans
}

/// Build spans for a modified line using its word-diff: unchanged words keep the base
/// add/del tint; changed words get the emphasized background so the actual edit pops.
fn word_hl_spans(text: &str, kind: DiffKind, hl: &[(String, bool)]) -> Vec<Span<'static>> {
    let (base_bg, emph_bg, fg) = match kind {
        DiffKind::Add => (t::add_bg(), t::add_emph_bg(), t::green()),
        _ => (t::del_bg(), t::del_emph_bg(), t::red()),
    };
    let sign = text.chars().next().unwrap_or(' ');
    let mut spans = vec![Span::styled(
        sign.to_string(),
        Style::default().fg(fg).bg(base_bg),
    )];
    for (txt, changed) in hl {
        let bg = if *changed { emph_bg } else { base_bg };
        let mut style = Style::default().fg(fg).bg(bg);
        if *changed {
            style = style.add_modifier(Modifier::BOLD);
        }
        spans.push(Span::styled(txt.clone(), style));
    }
    spans
}

fn draw_diff(f: &mut Frame, app: &mut App, area: Rect) {
    let sel = if app.visual_anchor.is_some() {
        app.visual_rows()
    } else {
        None
    };
    let total_w = area.width as usize;
    // Build only a bounded window around the cursor. Long diffs no longer allocate, wrap,
    // and tokenize thousands of off-screen ListItems on every navigation key.
    let cursor = app.diff_state.selected().unwrap_or(0);
    let window = (area.height as usize).saturating_mul(3).max(32);
    let window_start = cursor.saturating_sub(window / 3);
    let window_end = (window_start + window).min(app.diff.len());
    let ext = app
        .current_file
        .as_deref()
        .map(crate::syntax::ext_of)
        .unwrap_or_default();
    let items: Vec<ListItem> = app
        .diff
        .iter()
        .enumerate()
        .skip(window_start)
        .take(window_end.saturating_sub(window_start))
        .map(|(i, dl)| {
            // Inline expanded-thread rows: a distinct, wrapped comment block.
            if dl.kind == DiffKind::Comment {
                let fg = if dl.claude_author {
                    t::purple()
                } else {
                    t::accent()
                };
                let is_header = !dl.text.starts_with(' ');
                let style = if is_header {
                    Style::default().fg(fg).add_modifier(Modifier::BOLD)
                } else {
                    Style::default().fg(t::text())
                };
                let prefix = "     │ ";
                let avail = total_w.saturating_sub(prefix.chars().count());
                if let Some(code_ext) = dl
                    .code_ext
                    .as_ref()
                    .filter(|_| i >= window_start && i < window_end)
                {
                    let indent_len = dl.text.chars().take_while(|c| c.is_whitespace()).count();
                    let indent: String = dl.text.chars().take(indent_len).collect();
                    let code: String = dl.text.chars().skip(indent_len).collect();
                    let mut spans = vec![Span::styled(prefix, Style::default().fg(fg))];
                    spans.extend(code_line(&indent, &code, code_ext).spans);
                    return ListItem::new(Line::from(spans)).style(Style::default().bg(t::panel()));
                }
                let lines: Vec<Line> = wrap(&dl.text, avail)
                    .into_iter()
                    .map(|chunk| {
                        Line::from(vec![
                            Span::styled(prefix, Style::default().fg(fg)),
                            Span::styled(chunk, style),
                        ])
                    })
                    .collect();
                return ListItem::new(lines).style(Style::default().bg(t::panel()));
            }
            let gutter = match dl.new_ln {
                Some(n) => format!("{n:>4} "),
                None => "     ".to_string(),
            };
            let content_style = match dl.kind {
                DiffKind::Comment => unreachable!(),
                DiffKind::Add => Style::default().fg(t::green()).bg(t::add_bg()),
                DiffKind::Del => Style::default().fg(t::red()).bg(t::del_bg()),
                DiffKind::Hunk => Style::default().fg(t::hunk()).add_modifier(Modifier::BOLD),
                DiffKind::Meta => Style::default().fg(t::muted()),
                DiffKind::Ctx => Style::default().fg(t::text()),
            };
            // Wrap the content under the gutter so long lines never clip. Reserve a margin for
            // the comment marker (e.g. " ★12") so it isn't truncated on a full-width line.
            let marker_margin = if dl.comments > 0 {
                3 + (dl.comments.to_string().len())
            } else {
                0
            };
            let avail = total_w.saturating_sub(gutter.chars().count() + marker_margin);
            let chunks = wrap(&dl.text, avail);
            // For a single-row line: prefer word-diff emphasis on a modified line, else
            // syntax-highlight (both keep the no-clip guarantee).
            let syntax_spans: Option<Vec<Span>> = if chunks.len() == 1 {
                match &dl.word_hl {
                    Some(hl) if matches!(dl.kind, DiffKind::Add | DiffKind::Del) => {
                        Some(word_hl_spans(&dl.text, dl.kind, hl))
                    }
                    _ if matches!(dl.kind, DiffKind::Add | DiffKind::Del | DiffKind::Ctx) => {
                        Some(highlight_code_line(&dl.text, dl.kind, &ext))
                    }
                    _ => None,
                }
            } else {
                None
            };
            let mut lines: Vec<Line> = Vec::with_capacity(chunks.len());
            for (ci, chunk) in chunks.iter().enumerate() {
                let mut spans = vec![Span::styled(
                    if ci == 0 {
                        gutter.clone()
                    } else {
                        "     ".to_string()
                    },
                    Style::default().fg(t::muted()),
                )];
                if ci == 0 {
                    if let Some(hl) = &syntax_spans {
                        spans.extend(hl.iter().cloned());
                    } else {
                        spans.push(Span::styled(chunk.clone(), content_style));
                    }
                } else {
                    spans.push(Span::styled(chunk.clone(), content_style));
                }
                if ci == 0 && dl.comments > 0 {
                    let (icon, color) = if dl.has_claude {
                        ("★", t::purple())
                    } else if dl.has_github {
                        ("◆", t::accent())
                    } else {
                        ("▸", t::yellow())
                    };
                    spans.push(Span::styled(
                        format!("  {icon}{}", dl.comments),
                        Style::default().fg(color).add_modifier(Modifier::BOLD),
                    ));
                }
                lines.push(Line::from(spans));
            }
            let mut item = ListItem::new(lines);
            if let Some((lo, hi)) = sel {
                if i >= lo && i <= hi {
                    item = item.style(Style::default().bg(t::sel_bg()));
                }
            }
            item
        })
        .collect();

    let list = List::new(items)
        .highlight_style(Style::default().bg(t::sel_bg()))
        .highlight_symbol("");
    let mut visible_state = ListState::default();
    visible_state.select(Some(cursor.saturating_sub(window_start)));
    f.render_stateful_widget(list, area, &mut visible_state);
}

/// Split (side-by-side) diff: old lines on the left, new on the right, paired from the
/// unified model. Cells wrap within their column so nothing is clipped. The cursor
/// (and any visual selection) is mapped from the unified model onto the new side.
fn draw_diff_split(f: &mut Frame, app: &mut App, area: Rect) {
    let rows = crate::diffview::split_rows(&app.diff);
    let total = area.width as usize;
    let gutter = 5usize; // line-number columns
    let seps = 3usize; // " │ "
    let margin = 4usize; // room for the comment marker on the right, so it never clips
    let colw = total.saturating_sub(gutter * 2 + seps + margin) / 2;
    let colw = colw.max(4);

    // Which new-side line numbers are "selected" (cursor + visual range) in the unified model?
    let cursor = app.diff_state.selected().and_then(|i| app.diff.get(i));
    let cursor_new = cursor.and_then(|d| d.new_ln);
    let cursor_old = cursor.and_then(|d| d.old_ln);
    let ext = app
        .current_file
        .as_deref()
        .map(crate::syntax::ext_of)
        .unwrap_or_default();
    // Selected new- and old-side lines, so a visual selection over deletions still shows.
    let mut sel_new: std::collections::HashSet<u32> = std::collections::HashSet::new();
    let mut sel_old: std::collections::HashSet<u32> = std::collections::HashSet::new();
    if let Some((lo, hi)) = if app.visual_anchor.is_some() {
        app.visual_rows()
    } else {
        None
    } {
        for d in &app.diff[lo.min(app.diff.len())..=hi.min(app.diff.len().saturating_sub(1))] {
            if let Some(n) = d.new_ln {
                sel_new.insert(n);
            }
            if let Some(n) = d.old_ln {
                sel_old.insert(n);
            }
        }
    }

    let cell_spans = |cell: &Option<crate::diffview::Cell>,
                      chunk: Option<&String>,
                      first: bool|
     -> Vec<Span<'static>> {
        match cell {
            None => vec![Span::styled(" ".repeat(gutter + colw), Style::default())],
            Some(c) => {
                let (bg, fg) = match c.kind {
                    DiffKind::Add => (Some(t::add_bg()), t::green()),
                    DiffKind::Del => (Some(t::del_bg()), t::red()),
                    _ => (None, t::text()),
                };
                let gut = match (first, c.ln) {
                    (true, Some(n)) => format!("{n:>4} "),
                    _ => "     ".to_string(),
                };
                let mut spans = vec![Span::styled(gut, Style::default().fg(t::muted()))];
                let text = chunk.cloned().unwrap_or_default();
                // Word-diff emphasis only when the whole cell fits on one visual line.
                if first && chunk.map(|s| s.len()) == Some(c.text.len()) {
                    if let Some(hl) = &c.word_hl {
                        let emph = if matches!(c.kind, DiffKind::Add) {
                            t::add_emph_bg()
                        } else {
                            t::del_emph_bg()
                        };
                        let mut w = 0usize;
                        for (txt, changed) in hl {
                            let b = if *changed {
                                emph
                            } else {
                                bg.unwrap_or(t::bg())
                            };
                            let mut st = Style::default().fg(fg).bg(b);
                            if *changed {
                                st = st.add_modifier(Modifier::BOLD);
                            }
                            w += txt.chars().count();
                            spans.push(Span::styled(txt.clone(), st));
                        }
                        if w < colw {
                            let pad = " ".repeat(colw - w);
                            spans.push(Span::styled(
                                pad,
                                bg.map(|b| Style::default().bg(b)).unwrap_or_default(),
                            ));
                        }
                        return spans;
                    }
                }
                let w = text.chars().count();
                // Syntax-highlight when the whole cell fits on one visual line; else render
                // the (wrapped) chunk plainly so we never clip.
                let whole =
                    first && chunk.map(|s| s.chars().count()) == Some(c.text.chars().count());
                if whole && !text.is_empty() {
                    for (txt, tok) in crate::syntax::highlight(&text, &ext) {
                        let tfg = match tok {
                            crate::syntax::Tok::Keyword => t::accent(),
                            crate::syntax::Tok::Str => t::yellow(),
                            crate::syntax::Tok::Number => t::purple(),
                            crate::syntax::Tok::Comment => t::muted(),
                            crate::syntax::Tok::Plain => fg,
                        };
                        let mut st = Style::default().fg(tfg);
                        if let Some(b) = bg {
                            st = st.bg(b);
                        }
                        if tok == crate::syntax::Tok::Comment {
                            st = st.add_modifier(Modifier::ITALIC);
                        }
                        spans.push(Span::styled(txt, st));
                    }
                    if w < colw {
                        let mut pst = Style::default();
                        if let Some(b) = bg {
                            pst = pst.bg(b);
                        }
                        spans.push(Span::styled(" ".repeat(colw - w), pst));
                    }
                } else {
                    let padded = if w < colw {
                        format!("{text}{}", " ".repeat(colw - w))
                    } else {
                        text
                    };
                    let mut st = Style::default().fg(fg);
                    if let Some(b) = bg {
                        st = st.bg(b);
                    }
                    spans.push(Span::styled(padded, st));
                }
                spans
            }
        }
    };

    // As in unified mode, materialize only a bounded visible neighborhood.
    let cursor_row = crate::diffview::split_cursor_row(&rows, cursor_new, cursor_old).unwrap_or(0);
    let window = (area.height as usize).saturating_mul(3).max(32);
    let window_start = cursor_row.saturating_sub(window / 3);
    let window_end = (window_start + window).min(rows.len());
    let mut items: Vec<ListItem> = Vec::with_capacity(window_end.saturating_sub(window_start));
    for row in rows
        .iter()
        .skip(window_start)
        .take(window_end.saturating_sub(window_start))
    {
        if let Some(h) = &row.hunk {
            let style = if h.starts_with("@@") {
                Style::default().fg(t::hunk()).add_modifier(Modifier::BOLD)
            } else {
                Style::default().fg(t::muted())
            };
            let chunks = wrap(h, total);
            let lines: Vec<Line> = chunks
                .into_iter()
                .map(|c| Line::from(Span::styled(c, style)))
                .collect();
            items.push(ListItem::new(lines));
            continue;
        }
        let lw = row
            .left
            .as_ref()
            .map(|c| wrap(&c.text, colw))
            .unwrap_or_default();
        let rw = row
            .right
            .as_ref()
            .map(|c| wrap(&c.text, colw))
            .unwrap_or_default();
        let n = lw.len().max(rw.len()).max(1);
        let mut vlines: Vec<Line> = Vec::with_capacity(n);
        for k in 0..n {
            let mut spans = cell_spans(&row.left, lw.get(k), k == 0);
            spans.push(Span::styled(" │ ", Style::default().fg(t::border())));
            spans.extend(cell_spans(&row.right, rw.get(k), k == 0));
            if k == 0 && row.comments > 0 {
                let (icon, color) = if row.has_claude {
                    ("★", t::purple())
                } else if row.has_github {
                    ("◆", t::accent())
                } else {
                    ("▸", t::yellow())
                };
                spans.push(Span::styled(
                    format!(" {icon}{}", row.comments),
                    Style::default().fg(color).add_modifier(Modifier::BOLD),
                ));
            }
            vlines.push(Line::from(spans));
        }
        let mut item = ListItem::new(vlines);
        if crate::diffview::split_row_selected(row, &sel_new, &sel_old) {
            item = item.style(Style::default().bg(t::sel_bg()));
        }
        items.push(item);
    }
    let mut state = ListState::default();
    if !items.is_empty() {
        state.select(Some(cursor_row.saturating_sub(window_start)));
    }
    let list = List::new(items)
        .highlight_style(Style::default().bg(t::sel_bg()))
        .highlight_symbol("");
    f.render_stateful_widget(list, area, &mut state);
}

/// The Timeline / activity feed: commits + reviews in chronological order.
fn draw_timeline(f: &mut Frame, app: &mut App, area: Rect) {
    use crate::timeline::EventKind;
    let events = crate::timeline::build(&app.source);
    let width = area.width as usize;
    let mut lines: Vec<Line> = Vec::new();
    lines.push(Line::from(Span::styled(
        "Activity",
        Style::default()
            .fg(t::accent())
            .add_modifier(Modifier::BOLD),
    )));
    lines.push(Line::raw(""));
    if events.is_empty() {
        lines.push(Line::from(Span::styled(
            "  (no activity yet)",
            Style::default().fg(t::muted()),
        )));
    }
    for e in events.iter().filter(|e| match app.timeline_filter {
        1 => e.kind == EventKind::Commit,
        2 => e.kind != EventKind::Commit,
        3 => matches!(
            e.kind,
            EventKind::ReviewApproved | EventKind::ReviewChangesRequested
        ),
        _ => true,
    }) {
        let (icon, color) = match e.kind {
            EventKind::Commit => ("●", t::yellow()),
            EventKind::ReviewApproved => ("✓", t::green()),
            EventKind::ReviewChangesRequested => ("✗", t::red()),
            EventKind::ReviewCommented => ("◆", t::accent()),
        };
        let date = rel_time(&e.date);
        let mut head = vec![
            Span::styled(
                format!("{icon} "),
                Style::default().fg(color).add_modifier(Modifier::BOLD),
            ),
            Span::styled(
                format!("{} ", e.actor),
                Style::default().fg(t::text()).add_modifier(Modifier::BOLD),
            ),
        ];
        if !date.is_empty() {
            head.push(Span::styled(
                format!("· {date}"),
                Style::default().fg(t::muted()),
            ));
        }
        lines.push(Line::from(head));
        for chunk in wrap(&e.text, width.saturating_sub(4)) {
            lines.push(Line::from(Span::styled(
                format!("    {chunk}"),
                Style::default().fg(t::text()),
            )));
        }
    }
    let p = Paragraph::new(lines)
        .wrap(Wrap { trim: false })
        .scroll((app.timeline_scroll, 0));
    f.render_widget(p, area);
}

fn rel_time(iso: &str) -> String {
    // The store timestamps are epoch seconds strings; git dates are ISO. Just show a
    // trimmed value; a precise humanizer isn't worth the dependency.
    if iso.len() >= 19 && iso.contains('T') {
        iso[..19].replace('T', " ")
    } else {
        iso.to_string()
    }
}

/// Render a body line with light markdown styling, under an indent prefix.
fn md_line(indent: &str, text: &str) -> Line<'static> {
    use crate::markdown::Md;
    let mut spans: Vec<Span> = Vec::new();
    if !indent.is_empty() {
        spans.push(Span::raw(indent.to_string()));
    }
    for (txt, kind) in crate::markdown::spans(text) {
        let style = match kind {
            Md::Bold => Style::default().fg(t::text()).add_modifier(Modifier::BOLD),
            Md::Italic => Style::default()
                .fg(t::text())
                .add_modifier(Modifier::ITALIC),
            Md::Code => Style::default().fg(t::yellow()),
            Md::Link => Style::default()
                .fg(t::accent())
                .add_modifier(Modifier::UNDERLINED),
            Md::Heading => Style::default()
                .fg(t::accent())
                .add_modifier(Modifier::BOLD),
            Md::Bullet => Style::default().fg(t::muted()),
            Md::Plain => Style::default().fg(t::text()),
        };
        spans.push(Span::styled(txt, style));
    }
    Line::from(spans)
}

/// A one-line summary of a comment's reactions as ASCII chips, e.g. "+1 2 · heart 1".
/// Returns None when there are no reactions.
fn reaction_line(indent: &str, c: &Comment) -> Option<Line<'static>> {
    if c.reactions.is_empty() {
        return None;
    }
    let mut spans = vec![Span::raw(indent.to_string())];
    for (name, who) in &c.reactions {
        spans.push(Span::styled(
            format!("[{name} {}] ", who.len()),
            Style::default()
                .fg(t::purple())
                .add_modifier(Modifier::BOLD),
        ));
    }
    Some(Line::from(spans))
}

/// Map a fenced-code language tag to a file extension our tokenizer understands.
fn lang_to_ext(lang: &str) -> String {
    match lang.to_lowercase().as_str() {
        "rust" => "rs",
        "python" => "py",
        "javascript" => "js",
        "typescript" => "ts",
        "c++" | "cpp" => "cpp",
        "c" => "c",
        "golang" | "go" => "go",
        "ruby" => "rb",
        "shell" | "sh" | "bash" => "sh",
        "lua" => "lua",
        "java" => "java",
        "yaml" => "yaml",
        other => other,
    }
    .to_string()
}

/// One syntax-highlighted code line (used inside fenced code blocks). Comments render in a
/// muted italic so they read clearly as prose within the code.
fn code_line(indent: &str, raw: &str, ext: &str) -> Line<'static> {
    let mut spans = vec![Span::styled(
        indent.to_string(),
        Style::default().bg(t::panel()),
    )];
    for (txt, tok) in crate::syntax::highlight(raw, ext) {
        let style = match tok {
            crate::syntax::Tok::Keyword => Style::default().fg(t::accent()).bg(t::panel()),
            crate::syntax::Tok::Str => Style::default().fg(t::yellow()).bg(t::panel()),
            crate::syntax::Tok::Number => Style::default().fg(t::purple()).bg(t::panel()),
            crate::syntax::Tok::Comment => Style::default()
                .fg(t::muted())
                .bg(t::panel())
                .add_modifier(Modifier::ITALIC),
            crate::syntax::Tok::Plain => Style::default().fg(t::text()).bg(t::panel()),
        };
        spans.push(Span::styled(txt, style));
    }
    Line::from(spans)
}

/// Render a comment/description body: markdown for prose, syntax-highlighted code for
/// ```fenced``` blocks (GitHub-style). `ext` is the fallback language (from the file).
fn md_block(indent: &str, text: &str, ext: &str) -> Vec<Line<'static>> {
    let mut out = Vec::new();
    let mut in_code = false;
    let mut code_ext = String::new();
    for raw in text.lines() {
        let trimmed = raw.trim_start();
        if let Some(rest) = trimmed.strip_prefix("```") {
            if !in_code {
                in_code = true;
                let lang = rest.trim();
                code_ext = if lang.is_empty() || lang == "suggestion" {
                    ext.to_string()
                } else {
                    lang_to_ext(lang)
                };
                let label = if lang.is_empty() { "code" } else { lang };
                out.push(Line::from(Span::styled(
                    format!("{indent}{label}"),
                    Style::default().fg(t::muted()).add_modifier(Modifier::DIM),
                )));
            } else {
                in_code = false;
                code_ext.clear();
            }
            continue;
        }
        if in_code {
            out.push(code_line(&format!("{indent}  "), raw, &code_ext));
        } else {
            out.push(md_line(indent, raw));
        }
    }
    out
}

fn thread_lines<'a>(store: &crate::data::store::Store, root: &Comment, out: &mut Vec<Line<'a>>) {
    let ext = crate::syntax::ext_of(&root.file);
    let icon = if root.outdated {
        Span::styled("⊘ ", Style::default().fg(t::muted()))
    } else if root.status == "resolved" {
        Span::styled("✓ ", Style::default().fg(t::green()))
    } else if root.status == "published" || root.origin == "github" {
        Span::styled("◆ ", Style::default().fg(t::accent()))
    } else {
        Span::styled(
            "DRAFT ",
            Style::default()
                .fg(t::yellow())
                .add_modifier(Modifier::BOLD),
        )
    };
    let who = if root.origin == "claude" {
        format!("★ {}", root.author)
    } else {
        root.author.clone()
    };
    let mut head = vec![
        icon,
        Span::styled(
            who,
            Style::default()
                .fg(t::accent())
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled(
            format!("  {}:{}", root.file, root.line_start),
            Style::default().fg(t::muted()),
        ),
    ];
    if root.outdated {
        head.push(Span::styled(
            "  Outdated",
            Style::default()
                .fg(t::yellow())
                .add_modifier(Modifier::BOLD),
        ));
    }
    out.push(Line::from(head));
    // For an outdated thread, show the code the comment was originally made against.
    if root.outdated {
        if let Some(code) = root.anchor_text.as_deref().filter(|s| !s.is_empty()) {
            out.push(Line::from(Span::styled(
                "  was: ",
                Style::default().fg(t::muted()),
            )));
            out.push(code_line("    ", code, &ext));
        }
    }
    for l in md_block("  ", &root.body, &ext) {
        out.push(l);
    }
    if let Some(rl) = reaction_line("  ", root) {
        out.push(rl);
    }
    for rep in store.replies(&root.id) {
        let rwho = if rep.origin == "claude" {
            format!("★ {}", rep.author)
        } else {
            rep.author.clone()
        };
        out.push(Line::from(Span::styled(
            format!("    ↳ {rwho}"),
            Style::default().fg(t::purple()),
        )));
        for l in md_block("      ", &rep.body, &ext) {
            out.push(l);
        }
        if let Some(rl) = reaction_line("      ", &rep) {
            out.push(rl);
        }
    }
    out.push(Line::raw(""));
}

fn draw_conversation(f: &mut Frame, app: &mut App, area: Rect) {
    let s = &app.source;
    let mut lines: Vec<Line> = vec![];
    // (title is already in the panel border)
    let mut meta = vec![
        Span::styled(
            s.author.clone(),
            Style::default().fg(t::text()).add_modifier(Modifier::BOLD),
        ),
        Span::styled(
            format!("  ·  {}", rel_time(&s.updated_at)),
            Style::default().fg(t::muted()),
        ),
    ];
    if s.caps.has_checks && !s.checks.is_empty() {
        let ok = s
            .checks
            .iter()
            .filter(|(_, st)| st.eq_ignore_ascii_case("success"))
            .count();
        meta.push(Span::styled(
            format!("  ·  checks {}/{}", ok, s.checks.len()),
            Style::default().fg(t::muted()),
        ));
    }
    if !s.review_decision.is_empty() {
        meta.push(Span::styled(
            format!("  ·  {}", s.review_decision),
            Style::default().fg(t::yellow()),
        ));
    }
    lines.push(Line::from(meta));
    if s.caps.has_reviewers && !s.reviewers.is_empty() {
        lines.push(Line::from(Span::styled(
            format!("reviewers: {}", s.reviewers.join(", ")),
            Style::default().fg(t::muted()),
        )));
    }
    lines.push(Line::raw(""));
    for l in md_block("", &s.description, "") {
        lines.push(l);
    }
    lines.push(Line::raw(""));
    lines.push(Line::from(Span::styled(
        "Commits",
        Style::default()
            .fg(t::accent())
            .add_modifier(Modifier::BOLD),
    )));
    for c in &s.commits {
        lines.push(Line::from(vec![
            Span::styled(format!("  {} ", c.short), Style::default().fg(t::yellow())),
            Span::styled(c.subject.clone(), Style::default().fg(t::text())),
        ]));
    }
    // Checks / CI (GitHub's checks section).
    if s.caps.has_checks && !s.checks.is_empty() {
        lines.push(Line::raw(""));
        let ok = s
            .checks
            .iter()
            .filter(|(_, st)| st.eq_ignore_ascii_case("success"))
            .count();
        lines.push(Line::from(Span::styled(
            format!("Checks  {ok}/{} passing", s.checks.len()),
            Style::default()
                .fg(t::accent())
                .add_modifier(Modifier::BOLD),
        )));
        for (name, state) in &s.checks {
            let st = state.to_lowercase();
            let (mark, color) = if st == "success" {
                ("✓", t::green())
            } else if st == "failure" || st == "error" {
                ("✗", t::red())
            } else if st == "pending" || st == "in_progress" || st.is_empty() {
                ("•", t::yellow())
            } else {
                ("•", t::muted())
            };
            lines.push(Line::from(vec![
                Span::styled(format!("  {mark} "), Style::default().fg(color)),
                Span::styled(name.clone(), Style::default().fg(t::text())),
                Span::styled(format!("  {state}"), Style::default().fg(t::muted())),
            ]));
        }
    }
    let threads: Vec<_> = app
        .store
        .all_threads()
        .into_iter()
        .filter(|t| !t.hidden)
        .collect();
    if !threads.is_empty() {
        lines.push(Line::raw(""));
        lines.push(Line::from(Span::styled(
            "Comments",
            Style::default()
                .fg(t::accent())
                .add_modifier(Modifier::BOLD),
        )));
        lines.push(Line::raw(""));
        let mut sorted = threads;
        sorted.sort_by_key(|a| (a.file.clone(), a.line_start));
        for root in &sorted {
            thread_lines(&app.store, root, &mut lines);
        }
    }
    let p = Paragraph::new(lines)
        .wrap(Wrap { trim: false })
        .scroll((app.conv_scroll, 0));
    f.render_widget(p, area);
}

fn draw_claude(f: &mut Frame, app: &mut App, area: Rect) {
    let mut lines: Vec<Line> = vec![];
    let mut sessions: Vec<_> = app.store.sessions.values().collect();
    sessions.sort_by(|a, b| b.started_at.cmp(&a.started_at));
    let selected = sessions
        .get(
            app.claude_session_index
                .min(sessions.len().saturating_sub(1)),
        )
        .copied()
        .or(app.claude_session.as_ref());
    if !sessions.is_empty() {
        lines.push(Line::from(Span::styled(
            format!(
                "Sessions  {}/{}  (h/l switch)",
                app.claude_session_index.min(sessions.len() - 1) + 1,
                sessions.len()
            ),
            Style::default().fg(t::muted()),
        )));
        lines.push(Line::raw(""));
    }
    match selected {
        None => {
            lines.push(Line::from(Span::styled(
                "★ Claude review",
                Style::default()
                    .fg(t::purple())
                    .add_modifier(Modifier::BOLD),
            )));
            lines.push(Line::raw(""));
            lines.push(Line::from(Span::styled(
                "No review yet — press  a  to run one.",
                Style::default().fg(t::muted()),
            )));
        }
        Some(sess) => {
            let (icon, vstyle) = match sess.verdict.as_deref() {
                Some("approve") => ("✓ approve".to_string(), Style::default().fg(t::green())),
                Some("request_changes") => (
                    "✗ request changes".to_string(),
                    Style::default().fg(t::red()),
                ),
                Some("comment") => ("● commented".to_string(), Style::default().fg(t::yellow())),
                _ if sess.state == "running" => (
                    if sess.log.is_empty() {
                        "… starting".to_string()
                    } else {
                        format!("… running · {} updates", sess.log.len())
                    },
                    Style::default().fg(t::accent()),
                ),
                _ if sess.state == "error" => {
                    ("! error".to_string(), Style::default().fg(t::red()))
                }
                _ => ("—".to_string(), Style::default().fg(t::muted())),
            };
            lines.push(Line::from(vec![
                Span::styled(
                    "★ Claude review  ",
                    Style::default()
                        .fg(t::purple())
                        .add_modifier(Modifier::BOLD),
                ),
                Span::styled(icon, vstyle.add_modifier(Modifier::BOLD)),
            ]));
            lines.push(Line::raw(""));
            if let Some(e) = &sess.error {
                lines.push(Line::from(Span::styled(
                    format!("Error: {e}"),
                    Style::default().fg(t::red()),
                )));
                lines.push(Line::raw(""));
            }
            if !sess.summary.is_empty() {
                for l in sess.summary.lines() {
                    lines.push(Line::from(Span::styled(
                        l.to_string(),
                        Style::default().fg(t::text()),
                    )));
                }
                lines.push(Line::raw(""));
            }
            if !sess.replied.is_empty() {
                lines.push(Line::from(Span::styled(
                    "Replies to threads",
                    Style::default()
                        .fg(t::accent())
                        .add_modifier(Modifier::BOLD),
                )));
                for cid in &sess.replied {
                    if let Some(root) = app.store.get(cid) {
                        lines.push(Line::from(vec![
                            Span::styled(
                                format!("  {}:{}  ", root.file, root.line_start),
                                Style::default().fg(t::muted()),
                            ),
                            Span::styled(
                                root.body.chars().take(50).collect::<String>(),
                                Style::default().fg(t::text()),
                            ),
                        ]));
                        for rep in app.store.replies(cid) {
                            if rep.origin == "claude" {
                                lines.push(Line::from(Span::styled(
                                    format!("    ↳ {}", rep.body),
                                    Style::default().fg(t::purple()),
                                )));
                            }
                        }
                    }
                }
                lines.push(Line::raw(""));
            }
            if !sess.new_comment_ids.is_empty() {
                lines.push(Line::from(Span::styled(
                    "New comments",
                    Style::default()
                        .fg(t::accent())
                        .add_modifier(Modifier::BOLD),
                )));
                for id in &sess.new_comment_ids {
                    if let Some(c) = app.store.get(id) {
                        lines.push(Line::from(Span::styled(
                            format!("  {}:{}", c.file, c.line_start),
                            Style::default().fg(t::yellow()),
                        )));
                        lines.extend(md_block("    ", &c.body, &crate::syntax::ext_of(&c.file)));
                        if c.kind == "suggestion" {
                            if let Some(sug) = &c.suggestion_text {
                                lines.push(Line::from(Span::styled(
                                    "    suggestion:",
                                    Style::default().fg(t::muted()),
                                )));
                                let ext = crate::syntax::ext_of(&c.file);
                                for l in sug.lines() {
                                    lines.push(code_line("      ", l, &ext));
                                }
                            }
                        }
                    }
                }
                lines.push(Line::raw(""));
            }
            if !sess.notes.is_empty() {
                lines.push(Line::from(Span::styled(
                    "Notes",
                    Style::default()
                        .fg(t::accent())
                        .add_modifier(Modifier::BOLD),
                )));
                for n in &sess.notes {
                    lines.push(Line::from(Span::styled(
                        format!("  • {n}"),
                        Style::default().fg(t::muted()),
                    )));
                }
                lines.push(Line::raw(""));
            }
            if !sess.log.is_empty() {
                lines.push(Line::from(Span::styled(
                    "Progress",
                    Style::default().fg(t::muted()).add_modifier(Modifier::BOLD),
                )));
                for entry in sess.log.iter().rev().take(20).rev() {
                    lines.push(Line::from(Span::styled(
                        format!("  {entry}"),
                        Style::default().fg(t::muted()),
                    )));
                }
            }
        }
    }
    let p = Paragraph::new(lines)
        .wrap(Wrap { trim: false })
        .scroll((app.claude_scroll, 0));
    f.render_widget(p, area);
}

fn draw_status(f: &mut Frame, app: &App, area: Rect) {
    // While searching, the status bar is the search prompt.
    if app.searching {
        let line = Line::from(vec![
            Span::styled(
                " search ",
                Style::default()
                    .fg(t::bg())
                    .bg(t::accent())
                    .add_modifier(Modifier::BOLD),
            ),
            Span::styled(format!("  /{}", app.search), Style::default().fg(t::text())),
            Span::styled("▏", Style::default().fg(t::accent())),
            Span::styled("   (enter/esc to finish)", Style::default().fg(t::muted())),
        ]);
        f.render_widget(
            Paragraph::new(line).style(Style::default().bg(t::bg())),
            area,
        );
        return;
    }
    if app.comment_searching {
        f.render_widget(
            Paragraph::new(format!(
                " comments  /{}▏  (enter/esc finish)",
                app.comment_query
            ))
            .style(Style::default().fg(t::text()).bg(t::bg())),
            area,
        );
        return;
    }
    let hints = if app.claude_rx.is_some() {
        Span::styled(
            " ★ Claude reviewing… ",
            Style::default()
                .fg(t::bg())
                .bg(t::purple())
                .add_modifier(Modifier::BOLD),
        )
    } else {
        Span::styled(
            " prtui ",
            Style::default()
                .fg(t::bg())
                .bg(t::accent())
                .add_modifier(Modifier::BOLD),
        )
    };
    let line = Line::from(vec![
        hints,
        Span::styled(
            format!("  {}", app.context_hint()),
            Style::default().fg(t::muted()),
        ),
        Span::styled(
            format!("  │  {}", app.status),
            Style::default().fg(t::muted()),
        ),
    ]);
    f.render_widget(
        Paragraph::new(line).style(Style::default().bg(t::bg())),
        area,
    );
}

fn centered(area: Rect, w: u16, h: u16) -> Rect {
    let x = area.x + (area.width.saturating_sub(w)) / 2;
    let y = area.y + (area.height.saturating_sub(h)) / 2;
    Rect {
        x,
        y,
        width: w.min(area.width),
        height: h.min(area.height),
    }
}

fn draw_compose(f: &mut Frame, app: &App) {
    let Some(Modal::Compose(c)) = &app.modal else {
        return;
    };
    let area = centered(f.area(), 76, 16);
    f.render_widget(Clear, area);
    let block = Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(Style::default().fg(t::border_focus()))
        .title(Span::styled(
            format!(" {} ", c.title),
            Style::default()
                .fg(t::border_focus())
                .add_modifier(Modifier::BOLD),
        ))
        .style(Style::default().bg(t::panel()));
    let inner = block.inner(area);
    f.render_widget(block, area);
    let rows = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Min(1), Constraint::Length(1)])
        .split(inner);
    let mut body_lines: Vec<Line> = c
        .buffer
        .lines()
        .map(|l| Line::from(l.to_string()))
        .collect();
    body_lines.push(Line::from(Span::styled(
        "▏",
        Style::default().fg(t::accent()),
    ))); // cursor hint
    f.render_widget(
        Paragraph::new(body_lines)
            .style(Style::default().fg(t::text()))
            .wrap(Wrap { trim: false }),
        rows[0],
    );
    f.render_widget(
        Paragraph::new(Line::from(Span::styled(
            "ctrl+s submit · ctrl+o edit in $EDITOR · esc cancel",
            Style::default().fg(t::muted()),
        ))),
        rows[1],
    );
}

fn draw_claude_form(f: &mut Frame, app: &App) {
    let Some(Modal::Claude(form)) = &app.modal else {
        return;
    };
    let direction_lines = form.direction.lines().count().max(1) as u16;
    let area = centered(f.area(), 82, (16 + direction_lines).min(30));
    f.render_widget(Clear, area);
    let block = Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(Style::default().fg(t::purple()))
        .title(Span::styled(
            " ★ Claude review ",
            Style::default()
                .fg(t::purple())
                .add_modifier(Modifier::BOLD),
        ))
        .style(Style::default().bg(t::panel()));
    let inner = block.inner(area);
    f.render_widget(block, area);
    let mut lines: Vec<Line> = vec![];
    lines.push(Line::from(Span::styled(
        "Instruction profile (↑/↓):",
        Style::default().fg(t::text()),
    )));
    for (i, p) in form.profiles.iter().enumerate() {
        let sel = i == form.selected;
        let style = if sel {
            Style::default()
                .fg(t::bg())
                .bg(t::accent())
                .add_modifier(Modifier::BOLD)
        } else {
            Style::default().fg(t::muted())
        };
        lines.push(Line::from(Span::styled(
            format!("  {} {}", if sel { "›" } else { " " }, p),
            style,
        )));
    }
    lines.push(Line::raw(""));
    lines.push(Line::from(Span::styled(
        "Direction:",
        Style::default().fg(t::text()),
    )));
    let direction: Vec<_> = form.direction.split('\n').collect();
    for (index, value) in direction.iter().enumerate() {
        lines.push(Line::from(Span::styled(
            format!(
                "  {}{}",
                value,
                if index + 1 == direction.len() {
                    "▏"
                } else {
                    ""
                }
            ),
            Style::default().fg(t::accent()),
        )));
    }
    lines.push(Line::raw(""));
    lines.push(Line::from(vec![
        Span::styled(
            format!(
                "[{}] allow edits (ctrl+e)   ",
                if form.allow_edits { "x" } else { " " }
            ),
            Style::default().fg(t::text()),
        ),
        Span::styled(
            format!(
                "[{}] auto-resolve (ctrl+r)",
                if form.auto_resolve { "x" } else { " " }
            ),
            Style::default().fg(t::text()),
        ),
    ]));
    lines.push(Line::from(Span::styled(
        format!(
            "[{}] push committed edits after validation (ctrl+p)",
            if form.push_changes { "x" } else { " " }
        ),
        Style::default().fg(if form.push_changes {
            t::yellow()
        } else {
            t::text()
        }),
    )));
    lines.push(Line::from(Span::styled(
        format!(
            "[{}] address all comments in worktree, commit + push (ctrl+w)",
            if form.address_comments { "x" } else { " " }
        ),
        Style::default().fg(if form.address_comments {
            t::purple()
        } else {
            t::text()
        }),
    )));
    lines.push(Line::raw(""));
    lines.push(Line::from(Span::styled(
        "enter newline · ctrl+s run · ctrl+y copy prompt · ctrl+o edit prompt · esc cancel",
        Style::default().fg(t::muted()),
    )));
    f.render_widget(Paragraph::new(lines), inner);
}

fn draw_prompt_preview(f: &mut Frame, prompt: &str) {
    let area = centered(f.area(), 92, 34);
    f.render_widget(Clear, area);
    let block = panel_block("Final Claude prompt", true);
    let inner = block.inner(area);
    f.render_widget(block, area);
    let mut lines: Vec<Line> = prompt
        .lines()
        .map(|line| Line::raw(line.to_string()))
        .collect();
    lines.push(Line::raw(""));
    lines.push(Line::from(Span::styled(
        "ctrl+s run revised prompt · y/c copy · e/o edit again · esc close",
        Style::default().fg(t::muted()),
    )));
    f.render_widget(Paragraph::new(lines).wrap(Wrap { trim: false }), inner);
}

fn draw_edit_result(f: &mut Frame, result: &crate::app::ImplementationResult) {
    let screen = f.area();
    let width = screen.width.saturating_sub(2).min(88);
    let height = (result.rows.len() as u16 + 6).min(screen.height.saturating_sub(2));
    if width < 4 || height < 3 {
        return;
    }
    let area = Rect::new(
        screen.x + screen.width.saturating_sub(width + 1),
        screen.y + screen.height.saturating_sub(height + 1),
        width,
        height,
    );
    f.render_widget(Clear, area);
    let title = if result.showing_implementation {
        "Implementation · result diff visible"
    } else {
        "Implementation · original diff visible"
    };
    let block = panel_block(title, true);
    let inner = block.inner(area);
    f.render_widget(block, area);
    let mut lines: Vec<Line> = result
        .rows
        .iter()
        .map(|row| Line::raw(row.clone()))
        .collect();
    if let Some(busy) = &result.busy {
        lines.push(Line::from(Span::styled(
            busy.clone(),
            Style::default().fg(t::accent()),
        )));
    }
    lines.push(Line::raw(""));
    lines.push(Line::from(Span::styled(
        if result.pushed {
            "pushed · b update branch · o open worktree · i toggle diff · z/esc close"
        } else {
            "p push · b update branch · o open worktree · i toggle diff · z/esc close"
        },
        Style::default().fg(t::muted()),
    )));
    f.render_widget(Paragraph::new(lines).wrap(Wrap { trim: false }), inner);
}

fn draw_actions(f: &mut Frame, items: &[(char, String, crate::app::ConfirmAction)]) {
    let h = items.len() as u16 + 4;
    let area = centered(f.area(), 44, h);
    f.render_widget(Clear, area);
    let block = Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(Style::default().fg(t::border_focus()))
        .title(Span::styled(
            " PR actions ",
            Style::default()
                .fg(t::border_focus())
                .add_modifier(Modifier::BOLD),
        ))
        .style(Style::default().bg(t::panel()));
    let inner = block.inner(area);
    f.render_widget(block, area);
    let mut lines: Vec<Line> = items
        .iter()
        .map(|(c, label, _)| {
            Line::from(vec![
                Span::styled(
                    format!("  {c}  "),
                    Style::default()
                        .fg(t::accent())
                        .add_modifier(Modifier::BOLD),
                ),
                Span::styled(label.clone(), Style::default().fg(t::text())),
            ])
        })
        .collect();
    lines.push(Line::raw(""));
    lines.push(Line::from(Span::styled(
        "  key = choose · Esc = cancel",
        Style::default().fg(t::muted()),
    )));
    f.render_widget(Paragraph::new(lines), inner);
}

fn draw_react(f: &mut Frame) {
    let reactions = crate::data::store::REACTIONS;
    let area = centered(f.area(), 40, reactions.len() as u16 + 4);
    f.render_widget(Clear, area);
    let block = Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(Style::default().fg(t::border_focus()))
        .title(Span::styled(
            " React ",
            Style::default()
                .fg(t::border_focus())
                .add_modifier(Modifier::BOLD),
        ))
        .style(Style::default().bg(t::panel()));
    let inner = block.inner(area);
    f.render_widget(block, area);
    let mut lines: Vec<Line> = reactions
        .iter()
        .enumerate()
        .map(|(i, r)| {
            Line::from(vec![
                Span::styled(
                    format!("  {}  ", i + 1),
                    Style::default()
                        .fg(t::accent())
                        .add_modifier(Modifier::BOLD),
                ),
                Span::styled((*r).to_string(), Style::default().fg(t::text())),
            ])
        })
        .collect();
    lines.push(Line::raw(""));
    lines.push(Line::from(Span::styled(
        "  1-8 = toggle · Esc = cancel",
        Style::default().fg(t::muted()),
    )));
    f.render_widget(Paragraph::new(lines), inner);
}

fn draw_confirm(f: &mut Frame, prompt: &str) {
    let area = centered(f.area(), (prompt.len() as u16 + 6).min(f.area().width), 5);
    f.render_widget(Clear, area);
    let block = Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(Style::default().fg(t::red()))
        .title(Span::styled(
            " Confirm ",
            Style::default().fg(t::red()).add_modifier(Modifier::BOLD),
        ))
        .style(Style::default().bg(t::panel()));
    let inner = block.inner(area);
    f.render_widget(block, area);
    f.render_widget(
        Paragraph::new(vec![
            Line::from(Span::styled(
                prompt.to_string(),
                Style::default().fg(t::text()),
            )),
            Line::from(Span::styled(
                "y = yes · any other key = cancel",
                Style::default().fg(t::muted()),
            )),
        ])
        .wrap(Wrap { trim: false }),
        inner,
    );
}

fn draw_help(f: &mut Frame) {
    let area = centered(f.area(), 82, 40);
    f.render_widget(Clear, area);
    let block = Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(Style::default().fg(t::border_focus()))
        .title(Span::styled(
            " Help ",
            Style::default()
                .fg(t::border_focus())
                .add_modifier(Modifier::BOLD),
        ))
        .style(Style::default().bg(t::panel()));
    let inner = block.inner(area);
    f.render_widget(block, area);
    let kv = |k: &'static str, v: &'static str| {
        Line::from(vec![
            Span::styled(
                format!("  {k:<10}"),
                Style::default()
                    .fg(t::accent())
                    .add_modifier(Modifier::BOLD),
            ),
            Span::styled(v, Style::default().fg(t::text())),
        ])
    };
    let lines = vec![
        Line::from(Span::styled(
            "Navigation",
            Style::default().fg(t::muted()).add_modifier(Modifier::BOLD),
        )),
        kv("j / k", "move down / up"),
        kv("^d / ^u", "half-page down / up"),
        kv("^f / ^b", "full-page down / up"),
        kv("g / G", "top / bottom"),
        kv(
            "tab",
            "cycle panel  (1 files, 2 commits, 3 diff, 4 comments)",
        ),
        kv(
            "[ / ]",
            "cycle main tab (Diff/Conversation/Timeline/Claude/Comments)",
        ),
        kv("n / N", "next / previous comment (jumps on the diff)"),
        kv("R", "refresh; press R again to cancel an active refresh"),
        kv("/", "search within the diff"),
        kv("\\", "toggle split (side-by-side) diff"),
        kv("+ / -", "expand / collapse diff context lines"),
        kv(
            "l/enter (dir)",
            "collapse / expand a directory in the Files tree",
        ),
        kv("o", "open the file at the commit in $EDITOR (worktree)"),
        kv("O", "open the active info view as Markdown in $EDITOR"),
        kv("z", "toggle the latest implementation result drawer"),
        kv(":", "open command palette"),
        kv("F", "cycle Comments / Timeline filter"),
        kv("D", "toggle thread detail drawer"),
        kv("l / enter", "open file / focus / commit diff / jump"),
        Line::raw(""),
        Line::from(Span::styled(
            "Review",
            Style::default().fg(t::muted()).add_modifier(Modifier::BOLD),
        )),
        kv("space", "expand / collapse the thread on the diff line"),
        kv("V / v", "visual-line select (then c to comment range)"),
        kv("c / s", "comment / suggest on line or selection"),
        kv("r / x", "reply / resolve the thread"),
        kv("d / e / y", "delete / edit / copy the thread"),
        kv("H", "hide / unhide the thread"),
        kv("E", "react to the thread (+1/heart/rocket as chips)"),
        kv("m", "toggle 'viewed' for the file"),
        kv("A", "apply a suggestion (commit in a worktree)"),
        kv(
            "Comments m/M",
            "select thread / select all visible; u clears",
        ),
        kv(
            "Comments A",
            "assess selected threads, then address actionable ones",
        ),
        kv(
            "Comments /",
            "search author, file, body, label, or workflow state",
        ),
        kv("C/Z/T", "needs clarification / defer / convert to task"),
        kv("L/!/W", "cycle label / priority / next-action owner"),
        kv(
            "U/I/R",
            "jump unresolved / actionable / retry selected thread",
        ),
        kv("backspace", "return to the previous comment location"),
        kv("a", "run a Claude review (re-run = follow-up)"),
        kv("Claude ^S", "run; enter adds a direction newline"),
        kv("Claude ^E/^P", "allow edits / opt in to pushing the commit"),
        kv("Claude ^Y/^O", "copy / edit the complete final prompt"),
        kv("S", "publish review to GitHub (preview first, PR only)"),
        kv("X", "PR actions: merge / close / reopen / ready / draft"),
        kv("P", "back to the PR / branch list"),
        kv("R", "refresh PR/branch metadata, threads, checks, and diff"),
        kv("t", "cycle color theme"),
        Line::raw(""),
        kv("? ", "close help    q  quit"),
    ];
    f.render_widget(Paragraph::new(lines), inner);
}

fn draw_palette(f: &mut Frame, query: &str, selected: usize) {
    let area = centered(f.area(), 58, 18);
    f.render_widget(Clear, area);
    let block = panel_block("Command palette · :", true);
    let inner = block.inner(area);
    f.render_widget(block, area);
    let commands = [
        "Open Diff",
        "Open Conversation",
        "Open Timeline",
        "Open Claude",
        "Open Comments",
        "Open view in editor",
        "Toggle thread drawer",
        "Cycle view filter",
        "Run Claude review",
        "Help",
    ];
    let q = query.to_lowercase();
    let items: Vec<ListItem> = commands
        .iter()
        .enumerate()
        .filter(|(_, c)| q.is_empty() || c.to_lowercase().contains(&q))
        .map(|(i, c)| ListItem::new(format!("{} {c}", if i == selected { "›" } else { " " })))
        .collect();
    let mut lines = vec![ListItem::new(format!(":{query}▏")), ListItem::new("")];
    lines.extend(items);
    f.render_widget(
        List::new(lines).highlight_style(Style::default().bg(t::sel_bg())),
        inner,
    );
}

fn draw_address_preview(f: &mut Frame, rows: &[String]) {
    let area = centered(f.area(), 82, (rows.len() as u16 + 7).min(30));
    f.render_widget(Clear, area);
    let block = panel_block("Address selected threads", true);
    let inner = block.inner(area);
    f.render_widget(block, area);
    let mut lines = vec![Line::from("Assessment preview"), Line::raw("")];
    lines.extend(rows.iter().map(|r| Line::from(format!("  {r}"))));
    lines.push(Line::raw(""));
    lines.push(Line::from(Span::styled(
        "enter/y implement actionable selections · esc cancel",
        Style::default().fg(t::muted()),
    )));
    f.render_widget(Paragraph::new(lines).wrap(Wrap { trim: false }), inner);
}

fn draw_summary(f: &mut Frame, rows: &[String]) {
    let area = centered(f.area(), 76, (rows.len() as u16 + 6).min(28));
    f.render_widget(Clear, area);
    let block = panel_block("Address run summary", true);
    let inner = block.inner(area);
    f.render_widget(block, area);
    let mut lines: Vec<Line> = rows.iter().map(|r| Line::from(r.clone())).collect();
    lines.push(Line::raw(""));
    lines.push(Line::from(Span::styled(
        "any key closes",
        Style::default().fg(t::muted()),
    )));
    f.render_widget(Paragraph::new(lines), inner);
}
