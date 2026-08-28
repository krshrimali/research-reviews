//! The Publish view: preview + edit exactly what will be posted to a GitHub PR, then
//! submit on explicit confirm. Nothing leaves the machine until `ctrl+s`.

use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use ratatui::layout::{Constraint, Direction, Layout};
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, BorderType, Borders, Clear, List, ListItem, Paragraph, Wrap};
use ratatui::Frame;

use crate::data::store::{Comment, Store};
use crate::theme as t;

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Verdict {
    Comment,
    Approve,
    RequestChanges,
}

impl Verdict {
    pub fn event(self) -> &'static str {
        match self {
            Verdict::Approve => "APPROVE",
            Verdict::RequestChanges => "REQUEST_CHANGES",
            Verdict::Comment => "COMMENT",
        }
    }
    fn label(self) -> &'static str {
        match self {
            Verdict::Approve => "Approve",
            Verdict::RequestChanges => "Request changes",
            Verdict::Comment => "Comment",
        }
    }
    fn next(self) -> Verdict {
        match self {
            Verdict::Comment => Verdict::Approve,
            Verdict::Approve => Verdict::RequestChanges,
            Verdict::RequestChanges => Verdict::Comment,
        }
    }
}

pub struct PubItem {
    pub include: bool,
    pub path: String,
    pub line_start: u32,
    pub line_end: u32,
    pub side: String,
    pub body: String,
    pub root_id: String,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Focus {
    Verdict,
    Body,
    List,
}

pub enum PublishAction {
    None,
    Cancel,
    Submit,
}

pub struct PublishView {
    pub verdict: Verdict,
    pub body: String,
    pub items: Vec<PubItem>,
    pub error: Option<String>,
    focus: Focus,
    selected: usize,
    editing: bool, // editing the body or the selected item's text
}

impl PublishView {
    /// Build from the store: every unpublished, unresolved, non-hidden thread (root +
    /// replies flattened into one body). `summary` seeds the review body.
    pub fn new(store: &Store, summary: &str) -> PublishView {
        let mut items = vec![];
        let mut roots = store.all_threads();
        roots.sort_by(|a, b| a.file.cmp(&b.file).then(a.line_start.cmp(&b.line_start)));
        for root in roots {
            if root.hidden || root.status == "resolved" || root.status == "published" {
                continue;
            }
            items.push(PubItem {
                include: true,
                path: root.file.clone(),
                line_start: root.line_start,
                line_end: root.line_end,
                side: root.side.clone(),
                body: flatten_thread(store, &root),
                root_id: root.id.clone(),
            });
        }
        PublishView {
            verdict: Verdict::Comment,
            body: summary.to_string(),
            items,
            error: None,
            focus: Focus::Verdict,
            selected: 0,
            editing: false,
        }
    }

    /// The included items — exactly what will be posted.
    pub fn included(&self) -> Vec<&PubItem> {
        self.items.iter().filter(|i| i.include).collect()
    }

    pub fn on_key(&mut self, key: KeyEvent) -> PublishAction {
        // Submit / cancel work from anywhere.
        if key.modifiers.contains(KeyModifiers::CONTROL) && key.code == KeyCode::Char('s') {
            return PublishAction::Submit;
        }
        if self.editing {
            match key.code {
                KeyCode::Esc => self.editing = false,
                KeyCode::Enter => self.edit_buf_mut().push('\n'),
                KeyCode::Backspace => {
                    self.edit_buf_mut().pop();
                }
                KeyCode::Char(c) => self.edit_buf_mut().push(c),
                _ => {}
            }
            return PublishAction::None;
        }
        match key.code {
            KeyCode::Esc | KeyCode::Char('q') => return PublishAction::Cancel,
            KeyCode::Tab => {
                self.focus = match self.focus {
                    Focus::Verdict => Focus::Body,
                    Focus::Body => Focus::List,
                    Focus::List => Focus::Verdict,
                }
            }
            _ => match self.focus {
                Focus::Verdict => match key.code {
                    KeyCode::Char(' ') | KeyCode::Right | KeyCode::Char('l') => {
                        self.verdict = self.verdict.next()
                    }
                    KeyCode::Char('j') | KeyCode::Down => self.focus = Focus::List,
                    KeyCode::Char('e') | KeyCode::Enter => self.focus = Focus::Body,
                    _ => {}
                },
                Focus::Body => match key.code {
                    KeyCode::Char('e') | KeyCode::Enter => self.editing = true,
                    KeyCode::Char('j') | KeyCode::Down => self.focus = Focus::List,
                    KeyCode::Char('k') | KeyCode::Up => self.focus = Focus::Verdict,
                    _ => {}
                },
                Focus::List => match key.code {
                    KeyCode::Char('j') | KeyCode::Down => {
                        if !self.items.is_empty() {
                            self.selected = (self.selected + 1).min(self.items.len() - 1);
                        }
                    }
                    KeyCode::Char('k') | KeyCode::Up => {
                        self.selected = self.selected.saturating_sub(1);
                    }
                    KeyCode::Char(' ') => {
                        if let Some(it) = self.items.get_mut(self.selected) {
                            it.include = !it.include;
                        }
                    }
                    KeyCode::Char('e') | KeyCode::Enter => {
                        if !self.items.is_empty() {
                            self.editing = true;
                        }
                    }
                    KeyCode::Char('d') if self.selected < self.items.len() => {
                        self.items.remove(self.selected);
                        self.selected = self.selected.min(self.items.len().saturating_sub(1));
                    }
                    _ => {}
                },
            },
        }
        PublishAction::None
    }

    fn edit_buf_mut(&mut self) -> &mut String {
        match self.focus {
            Focus::List => &mut self.items[self.selected].body,
            _ => &mut self.body,
        }
    }

    pub fn draw(&self, f: &mut Frame) {
        f.render_widget(Clear, f.area());
        f.render_widget(
            Block::default().style(Style::default().bg(t::bg())),
            f.area(),
        );
        let root = Layout::default()
            .direction(Direction::Vertical)
            .constraints([
                Constraint::Length(3), // verdict
                Constraint::Length(6), // body
                Constraint::Min(4),    // items
                Constraint::Length(2), // status
            ])
            .split(f.area());

        // Verdict row.
        let vbox = Block::default()
            .borders(Borders::ALL)
            .border_type(BorderType::Rounded)
            .border_style(Style::default().fg(if self.focus == Focus::Verdict {
                t::border_focus()
            } else {
                t::border()
            }))
            .title(Span::styled(
                " Publish review to GitHub ",
                Style::default()
                    .fg(t::accent())
                    .add_modifier(Modifier::BOLD),
            ))
            .style(Style::default().bg(t::panel()));
        let vcolor = match self.verdict {
            Verdict::Approve => t::green(),
            Verdict::RequestChanges => t::red(),
            Verdict::Comment => t::yellow(),
        };
        f.render_widget(
            Paragraph::new(Line::from(vec![
                Span::styled("verdict: ", Style::default().fg(t::muted())),
                Span::styled(self.verdict.label(), vcolor.into_style_bold()),
                Span::styled("   (space to change)", Style::default().fg(t::muted())),
            ]))
            .block(vbox),
            root[0],
        );

        // Body editor.
        let bbox = Block::default()
            .borders(Borders::ALL)
            .border_type(BorderType::Rounded)
            .border_style(Style::default().fg(if self.focus == Focus::Body {
                t::border_focus()
            } else {
                t::border()
            }))
            .title(Span::styled(
                if self.editing && self.focus != Focus::List {
                    " Review summary (editing) "
                } else {
                    " Review summary (e to edit) "
                },
                Style::default().fg(t::muted()),
            ))
            .style(Style::default().bg(t::panel()));
        let body_text = if self.body.is_empty() {
            "(no summary)".to_string()
        } else {
            self.body.clone()
        };
        f.render_widget(
            Paragraph::new(body_text)
                .style(Style::default().fg(t::text()))
                .wrap(Wrap { trim: false })
                .block(bbox),
            root[1],
        );

        // Items list.
        let n_inc = self.included().len();
        let ibox = Block::default()
            .borders(Borders::ALL)
            .border_type(BorderType::Rounded)
            .border_style(Style::default().fg(if self.focus == Focus::List {
                t::border_focus()
            } else {
                t::border()
            }))
            .title(Span::styled(
                format!(
                    " Comments to post: {n_inc}/{} (space toggle · e edit · d remove) ",
                    self.items.len()
                ),
                Style::default().fg(t::muted()),
            ))
            .style(Style::default().bg(t::panel()));
        let inner_w = root[2].width.saturating_sub(2) as usize;
        let mut rows: Vec<ListItem> = Vec::new();
        if self.items.is_empty() {
            rows.push(ListItem::new(Line::from(Span::styled(
                "  (no draft comments to publish)",
                Style::default().fg(t::muted()),
            ))));
        }
        for (i, it) in self.items.iter().enumerate() {
            let check = if it.include { "[x]" } else { "[ ]" };
            let sel = i == self.selected && self.focus == Focus::List;
            let loc = if it.line_start == it.line_end {
                format!("{}", it.line_start)
            } else {
                format!("{}-{}", it.line_start, it.line_end)
            };
            let mut lines = vec![Line::from(vec![
                Span::styled(
                    format!("{check} "),
                    Style::default().fg(if it.include { t::green() } else { t::muted() }),
                ),
                Span::styled(
                    format!("{}:{}", it.path, loc),
                    Style::default()
                        .fg(t::accent())
                        .add_modifier(Modifier::BOLD),
                ),
            ])];
            for chunk in crate::ui::wrap(&it.body, inner_w.saturating_sub(4)) {
                lines.push(Line::from(Span::styled(
                    format!("    {chunk}"),
                    Style::default().fg(if it.include { t::text() } else { t::muted() }),
                )));
            }
            let mut item = ListItem::new(lines);
            if sel {
                item = item.style(Style::default().bg(t::sel_bg()));
            }
            rows.push(item);
        }
        f.render_widget(List::new(rows).block(ibox), root[2]);

        // Status / errors.
        let status = if let Some(e) = &self.error {
            Line::from(Span::styled(
                format!("  error: {e}"),
                Style::default().fg(t::red()),
            ))
        } else {
            Line::from(Span::styled(
                "  tab: move · ctrl+s: SUBMIT · esc: cancel  —  nothing is posted until you submit",
                Style::default().fg(t::muted()),
            ))
        };
        f.render_widget(
            Paragraph::new(vec![
                Line::from(Span::styled(
                    " prtui · publish ",
                    Style::default()
                        .fg(t::bg())
                        .bg(t::accent())
                        .add_modifier(Modifier::BOLD),
                )),
                status,
            ])
            .style(Style::default().bg(t::bg())),
            root[3],
        );
    }
}

/// Flatten a thread (root + replies) into one comment body for posting.
fn flatten_thread(store: &Store, root: &Comment) -> String {
    let mut s = root.body.clone();
    for r in store.replies(&root.id) {
        s.push_str(&format!("\n\n> {}: {}", r.author, r.body));
    }
    s
}

/// Build the create-review REST payload. Pure + testable (no gh call).
pub fn build_payload(
    head_sha: &str,
    verdict: Verdict,
    body: &str,
    items: &[&PubItem],
) -> serde_json::Value {
    let comments: Vec<serde_json::Value> = items
        .iter()
        .map(|it| {
            let mut c = serde_json::json!({
                "path": it.path,
                "line": it.line_end,
                "side": it.side,
                "body": it.body,
            });
            if it.line_start != it.line_end {
                c["start_line"] = serde_json::json!(it.line_start);
                c["start_side"] = serde_json::json!(it.side);
            }
            c
        })
        .collect();
    serde_json::json!({
        "commit_id": head_sha,
        "body": body,
        "event": verdict.event(),
        "comments": comments,
    })
}

// small helper trait to keep the draw code tidy
trait IntoStyleBold {
    fn into_style_bold(self) -> Style;
}
impl IntoStyleBold for ratatui::style::Color {
    fn into_style_bold(self) -> Style {
        Style::default().fg(self).add_modifier(Modifier::BOLD)
    }
}
