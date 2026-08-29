//! PR / local-branch picker. Branches load instantly; PRs are fetched in a background
//! thread so startup never blocks.
//!
//! Search combines GitHub-style **qualifiers** with **fuzzy** free text:
//!   `is:pr is:draft author:alice label:bug review:required branch:feature  tok ref`
//! Qualifiers filter on structured metadata; the remaining text is fuzzy-matched
//! (fzf-style scoring) across all of a row's metadata, with matched chars highlighted.

use std::sync::mpsc::{channel, Receiver};

use crossterm::event::{KeyCode, KeyEvent};
use ratatui::layout::{Constraint, Direction, Layout};
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, BorderType, Borders, List, ListItem, ListState, Paragraph};
use ratatui::Frame;

use crate::data::{gh, git, proc};
use crate::theme as t;

#[derive(Clone, Default)]
pub struct Item {
    pub kind: &'static str, // "pr" | "branch"
    pub arg: String,        // PR number (string) or branch name
    pub id: String,         // "#482" | "●"
    pub title: String,
    // structured metadata (for qualifiers)
    pub author: String,
    pub labels: Vec<String>,
    pub state: String, // open|closed|merged (lower)
    pub draft: bool,
    pub review: String, // reviewDecision (lower)
    pub head: String,
    pub base: String,
    pub assignees: Vec<String>,
    pub updated: String,
    pub haystack: String, // lowercased combined text for free-text fuzzy
}

pub enum PickerAction {
    None,
    Open { kind: &'static str, arg: String },
    Quit,
}

pub struct Picker {
    cwd: String,
    items: Vec<Item>,
    filtered: Vec<usize>, // indices into items, ranked
    query: String,
    searching: bool,
    state: ListState,
    pr_rx: Option<Receiver<Vec<Item>>>,
    loading: bool,
    error: Option<String>,
    pr_scope: String,
}

// ---- fuzzy matching -------------------------------------------------------

/// fzf-lite score of `needle` (lowercase, no spaces) as a subsequence of `hay`
/// (lowercase). None if not a subsequence. Rewards contiguous runs and word starts.
fn fuzzy_score(hay: &str, needle: &str) -> Option<i32> {
    if needle.is_empty() {
        return Some(0);
    }
    let h: Vec<char> = hay.chars().collect();
    let mut hi = 0usize;
    let mut score = 0i32;
    let mut last: i32 = -2;
    for nc in needle.chars() {
        let mut found = None;
        while hi < h.len() {
            if h[hi] == nc {
                found = Some(hi);
                break;
            }
            hi += 1;
        }
        let j = found?;
        let mut s = 2;
        if j as i32 == last + 1 {
            s += 5; // contiguous
        }
        let before = if j == 0 { ' ' } else { h[j - 1] };
        if matches!(before, ' ' | '/' | '-' | '_' | '#' | ':') {
            s += 4; // word boundary
        }
        s -= (j as i32 - (last + 1)).min(3); // small gap penalty
        score += s;
        last = j as i32;
        hi = j + 1;
    }
    Some(score)
}

/// Greedy subsequence indices of `needle` in `text` (both lowercased), for highlighting.
fn match_indices(text: &str, needle: &str) -> Vec<usize> {
    if needle.is_empty() {
        return vec![];
    }
    let mut out = vec![];
    let mut nchars = needle.chars().peekable();
    let mut want = nchars.next();
    for (i, c) in text.chars().enumerate() {
        if let Some(w) = want {
            if c == w {
                out.push(i);
                want = nchars.next();
            }
        }
    }
    if want.is_none() {
        out
    } else {
        vec![]
    } // only highlight a full match
}

struct Query {
    quals: Vec<(String, String)>,
    text: String, // spaces removed, lowercased
}

const KNOWN_QUALS: &[&str] = &[
    "is", "author", "label", "review", "branch", "assignee", "type",
];

fn parse_query(s: &str) -> Query {
    let mut quals = vec![];
    let mut text = String::new();
    for tok in s.split_whitespace() {
        if let Some((k, v)) = tok.split_once(':') {
            if KNOWN_QUALS.contains(&k.to_lowercase().as_str()) && !v.is_empty() {
                quals.push((k.to_lowercase(), v.to_lowercase()));
                continue;
            }
        }
        text.push_str(&tok.to_lowercase());
    }
    Query { quals, text }
}

fn qual_ok(it: &Item, k: &str, v: &str) -> bool {
    match k {
        "type" | "is" => match v {
            "pr" => it.kind == "pr",
            "branch" => it.kind == "branch",
            "draft" => it.draft,
            "open" | "closed" | "merged" => it.state == v,
            other => it.review.contains(other) || it.state.contains(other),
        },
        "author" => it.author.to_lowercase().contains(v),
        "label" => it.labels.iter().any(|l| l.to_lowercase().contains(v)),
        "review" => it.review.contains(v),
        "branch" => it.head.to_lowercase().contains(v) || it.base.to_lowercase().contains(v),
        "assignee" => it.assignees.iter().any(|a| a.to_lowercase().contains(v)),
        _ => true,
    }
}

/// Returns a match score if the item passes all qualifiers and the fuzzy text, else None.
fn item_score(it: &Item, q: &Query) -> Option<i32> {
    for (k, v) in &q.quals {
        if !qual_ok(it, k, v) {
            return None;
        }
    }
    fuzzy_score(&it.haystack, &q.text)
}

// ---- construction ---------------------------------------------------------

impl Picker {
    pub fn new(cwd: &str) -> Picker {
        Self::with_pr_scope(cwd, "open")
    }

    fn with_pr_scope(cwd: &str, pr_scope: &str) -> Picker {
        let mut items = vec![];
        let cur = git::current_branch(Some(cwd));
        if let (true, out, _) = proc::git(
            &["for-each-ref", "--format=%(refname:short)", "refs/heads/"],
            Some(cwd),
        ) {
            for name in out.split_whitespace() {
                let is_cur = Some(name.to_string()) == cur;
                items.push(Item {
                    kind: "branch",
                    arg: name.to_string(),
                    id: "●".into(),
                    title: format!("{name}{}", if is_cur { "  (current)" } else { "" }),
                    head: name.to_string(),
                    haystack: format!("branch {} {}", name, if is_cur { "current" } else { "" })
                        .to_lowercase(),
                    ..Default::default()
                });
            }
        }
        let (tx, rx) = channel();
        let loading = gh::available();
        if loading {
            let cwd2 = cwd.to_string();
            let state = pr_scope.to_string();
            std::thread::spawn(move || {
                let _ = tx.send(
                    gh::list_prs_with_state(Some(&cwd2), &state)
                        .iter()
                        .map(pr_to_item)
                        .collect(),
                );
            });
        }
        let mut p = Picker {
            cwd: cwd.to_string(),
            items,
            filtered: vec![],
            query: String::new(),
            searching: false,
            state: ListState::default(),
            pr_rx: if loading { Some(rx) } else { None },
            loading,
            error: None,
            pr_scope: pr_scope.to_string(),
        };
        p.refilter();
        p
    }

    pub fn set_error(&mut self, e: &str) {
        self.error = Some(e.to_string());
    }

    pub fn poll(&mut self) -> bool {
        if let Some(rx) = &self.pr_rx {
            if let Ok(prs) = rx.try_recv() {
                let branches: Vec<Item> = std::mem::take(&mut self.items);
                self.items = prs;
                self.items.extend(branches);
                self.loading = false;
                self.pr_rx = None;
                self.refilter();
                return true;
            }
        }
        false
    }

    fn refilter(&mut self) {
        let q = parse_query(&self.query);
        let mut scored: Vec<(i32, usize)> = self
            .items
            .iter()
            .enumerate()
            .filter_map(|(i, it)| item_score(it, &q).map(|s| (s, i)))
            .collect();
        // Highest score first; tie-break by recency (updated desc) then title.
        scored.sort_by(|a, b| {
            b.0.cmp(&a.0)
                .then_with(|| self.items[b.1].updated.cmp(&self.items[a.1].updated))
                .then_with(|| self.items[a.1].title.cmp(&self.items[b.1].title))
        });
        self.filtered = scored.into_iter().map(|(_, i)| i).collect();
        let sel = if self.filtered.is_empty() {
            None
        } else {
            Some(
                self.state
                    .selected()
                    .unwrap_or(0)
                    .min(self.filtered.len() - 1),
            )
        };
        self.state.select(sel);
    }

    fn move_sel(&mut self, delta: i32) {
        if self.filtered.is_empty() {
            return;
        }
        let cur = self.state.selected().unwrap_or(0) as i32;
        self.state.select(Some(
            (cur + delta).clamp(0, self.filtered.len() as i32 - 1) as usize
        ));
    }

    /// Args of the currently visible (filtered) items — for tests.
    pub fn visible_args(&self) -> Vec<String> {
        self.filtered
            .iter()
            .map(|&i| self.items[i].arg.clone())
            .collect()
    }

    pub fn on_key(&mut self, key: KeyEvent) -> PickerAction {
        if self.searching {
            match key.code {
                KeyCode::Esc | KeyCode::Enter => self.searching = false,
                KeyCode::Backspace => {
                    self.query.pop();
                    self.refilter();
                }
                KeyCode::Char(c) => {
                    self.query.push(c);
                    self.refilter();
                }
                _ => {}
            }
            return PickerAction::None;
        }
        match key.code {
            KeyCode::Char('q') | KeyCode::Esc => return PickerAction::Quit,
            KeyCode::Char('/') | KeyCode::Char('i') => self.searching = true,
            KeyCode::Char('j') | KeyCode::Down => self.move_sel(1),
            KeyCode::Char('k') | KeyCode::Up => self.move_sel(-1),
            KeyCode::Char('g') => self.state.select((!self.filtered.is_empty()).then_some(0)),
            KeyCode::Char('G') => self.move_sel(i32::MAX / 2),
            KeyCode::Char('r') => {
                let cwd = self.cwd.clone();
                let scope = self.pr_scope.clone();
                *self = Picker::with_pr_scope(&cwd, &scope);
            }
            KeyCode::Char('s') | KeyCode::Tab => {
                let cwd = self.cwd.clone();
                let scope = match self.pr_scope.as_str() {
                    "open" => "closed",
                    "closed" => "merged",
                    "merged" => "all",
                    _ => "open",
                };
                *self = Picker::with_pr_scope(&cwd, scope);
            }
            KeyCode::Char('t') => {
                crate::theme::cycle();
            }
            KeyCode::Enter | KeyCode::Char('l') => {
                if let Some(sel) = self.state.selected() {
                    if let Some(&idx) = self.filtered.get(sel) {
                        let it = &self.items[idx];
                        return PickerAction::Open {
                            kind: it.kind,
                            arg: it.arg.clone(),
                        };
                    }
                }
            }
            _ => {}
        }
        PickerAction::None
    }

    pub fn draw(&mut self, f: &mut Frame) {
        f.render_widget(
            Block::default().style(Style::default().bg(t::bg())),
            f.area(),
        );
        let root = Layout::default()
            .direction(Direction::Vertical)
            .constraints([
                Constraint::Length(3),
                Constraint::Min(3),
                Constraint::Length(2),
            ])
            .split(f.area());

        // Filter box.
        let fb_border = if self.searching {
            t::border_focus()
        } else {
            t::border()
        };
        let fb = Paragraph::new(Line::from(vec![
            Span::styled(
                if self.searching { "/" } else { " " },
                Style::default().fg(t::accent()),
            ),
            Span::styled(
                if self.query.is_empty() && !self.searching {
                    "search — press / or i   (try: is:pr author:… label:… review:required  tok ref)"
                        .to_string()
                } else {
                    format!("{}{}", self.query, if self.searching { "▏" } else { "" })
                },
                Style::default().fg(if self.query.is_empty() && !self.searching {
                    t::muted()
                } else {
                    t::text()
                }),
            ),
        ]))
        .block(
            Block::default()
                .borders(Borders::ALL)
                .border_type(BorderType::Rounded)
                .border_style(Style::default().fg(fb_border))
                .title(Span::styled(
                    " Review — pick a PR or branch ",
                    Style::default()
                        .fg(t::accent())
                        .add_modifier(Modifier::BOLD),
                ))
                .style(Style::default().bg(t::panel())),
        );
        f.render_widget(fb, root[0]);

        // List with match highlighting + metadata.
        let q = parse_query(&self.query);
        let rows: Vec<ListItem> = self
            .filtered
            .iter()
            .map(|&i| self.row(&self.items[i], &q.text))
            .collect();
        let count = self.filtered.len();
        let scope = format!("{} PRs", self.pr_scope);
        let title = if self.loading {
            format!(" {count} shown · {scope} · loading… ")
        } else {
            format!(" {count} shown · {scope} ")
        };
        let list = List::new(rows)
            .block(
                Block::default()
                    .borders(Borders::ALL)
                    .border_type(BorderType::Rounded)
                    .border_style(Style::default().fg(if self.searching {
                        t::border()
                    } else {
                        t::border_focus()
                    }))
                    .title(Span::styled(title, Style::default().fg(t::muted())))
                    .style(Style::default().bg(t::panel())),
            )
            .highlight_style(
                Style::default()
                    .bg(t::sel_bg())
                    .add_modifier(Modifier::BOLD),
            );
        f.render_stateful_widget(list, root[1], &mut self.state);

        // Status bar (2 lines: qualifier help + keys).
        let quals = Line::from(Span::styled(
            "  qualifiers: is:pr is:branch is:draft author: label: review: branch: assignee:",
            Style::default().fg(t::muted()),
        ));
        let hint = if let Some(e) = &self.error {
            Span::styled(
                format!("  could not open: {e}"),
                Style::default().fg(t::red()),
            )
        } else if self.searching {
            Span::styled(
                "  type to filter · enter/esc done",
                Style::default().fg(t::muted()),
            )
        } else {
            Span::styled(
                "  j/k move · enter open · / search · tab PR state · r refresh · t theme · q quit",
                Style::default().fg(t::muted()),
            )
        };
        let bar = Line::from(vec![
            Span::styled(
                " prtui ",
                Style::default()
                    .fg(t::bg())
                    .bg(t::accent())
                    .add_modifier(Modifier::BOLD),
            ),
            hint,
        ]);
        f.render_widget(
            Paragraph::new(vec![quals, bar]).style(Style::default().bg(t::bg())),
            root[2],
        );
    }

    /// Exposed for UI/integration tests and status consumers.
    pub fn pr_scope(&self) -> &str {
        &self.pr_scope
    }

    /// Build one list row: kind badge + highlighted title + metadata.
    fn row(&self, it: &Item, needle: &str) -> ListItem<'static> {
        let mut spans = vec![Span::styled(
            format!("{:<6}", it.id),
            Style::default().fg(if it.kind == "pr" {
                t::green()
            } else {
                t::purple()
            }),
        )];
        if it.draft {
            spans.push(Span::styled("draft ", Style::default().fg(t::muted())));
        }
        // Title with fuzzy-match highlight.
        let title: String = it.title.chars().take(48).collect();
        let hl = match_indices(&title.to_lowercase(), needle);
        for (i, ch) in title.chars().enumerate() {
            if hl.contains(&i) {
                spans.push(Span::styled(
                    ch.to_string(),
                    Style::default()
                        .fg(t::accent())
                        .add_modifier(Modifier::BOLD | Modifier::UNDERLINED),
                ));
            } else {
                spans.push(Span::styled(ch.to_string(), Style::default().fg(t::text())));
            }
        }
        // pad to a column
        let used = title.chars().count();
        if used < 50 {
            spans.push(Span::raw(" ".repeat(50 - used)));
        }
        // Metadata: author · labels · review
        let mut meta = String::new();
        if !it.author.is_empty() {
            meta.push_str(&it.author);
        } else if it.kind == "branch" {
            meta.push_str("local branch");
        }
        if !it.labels.is_empty() {
            meta.push_str(&format!(
                "  {}",
                it.labels
                    .iter()
                    .map(|l| format!("#{l}"))
                    .collect::<Vec<_>>()
                    .join(" ")
            ));
        }
        spans.push(Span::styled(
            format!("  {meta}"),
            Style::default().fg(t::muted()),
        ));
        if !it.review.is_empty() {
            let col = if it.review.contains("approv") {
                t::green()
            } else if it.review.contains("change") {
                t::red()
            } else {
                t::yellow()
            };
            spans.push(Span::styled(
                format!("  {}", it.review.replace('_', " ")),
                Style::default().fg(col),
            ));
        }
        ListItem::new(Line::from(spans))
    }
}

fn pr_to_item(pr: &serde_json::Value) -> Item {
    let number = pr["number"].as_u64().unwrap_or(0);
    let title = pr["title"].as_str().unwrap_or("").to_string();
    let author = pr["author"]["login"].as_str().unwrap_or("?").to_string();
    let state = pr["state"].as_str().unwrap_or("").to_lowercase();
    let draft = pr["isDraft"].as_bool().unwrap_or(false);
    let review = pr["reviewDecision"].as_str().unwrap_or("").to_lowercase();
    let head = pr["headRefName"].as_str().unwrap_or("").to_string();
    let base = pr["baseRefName"].as_str().unwrap_or("").to_string();
    let labels: Vec<String> = pr["labels"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|l| l["name"].as_str().map(|s| s.to_string()))
                .collect()
        })
        .unwrap_or_default();
    let assignees: Vec<String> = pr["assignees"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|x| x["login"].as_str().map(|s| s.to_string()))
                .collect()
        })
        .unwrap_or_default();
    let updated = pr["updatedAt"].as_str().unwrap_or("").to_string();
    let haystack = format!(
        "#{number} {title} {author} {} {head} {base} {state} {review} {}",
        labels.join(" "),
        assignees.join(" ")
    )
    .to_lowercase();
    Item {
        kind: "pr",
        arg: number.to_string(),
        id: format!("#{number}"),
        title,
        author,
        labels,
        state,
        draft,
        review,
        head,
        base,
        assignees,
        updated,
        haystack,
    }
}
