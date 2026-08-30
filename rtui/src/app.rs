//! Application state, navigation, and input handling.

use std::collections::HashMap;
use std::sync::mpsc::Receiver;
use std::time::{Duration, Instant};

use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use ratatui::widgets::ListState;

use crate::data::claude::{self, ClaudeEvent, ClaudeOpts};
use crate::data::git;
use crate::data::source::Source;
use crate::data::store::{Session, Store};

type DiffCacheKey = (String, String, String, usize);
type DiffPrefetch = (u64, DiffCacheKey, String);

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Panel {
    Files,
    Commits,
    Main,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum MainTab {
    Diff,
    Conversation,
    Timeline,
    Claude,
    Comments,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum DiffKind {
    Meta,
    Hunk,
    Add,
    Del,
    Ctx,
    Comment, // an inline, expanded thread line (not part of the actual diff)
}

pub struct DiffLine {
    pub text: String,
    pub kind: DiffKind,
    pub new_ln: Option<u32>,
    pub old_ln: Option<u32>, // old-side line number (for split view / word-diff)
    pub comments: u32,       // number of comments in the thread(s) on this line
    pub has_claude: bool,    // any comment on this line is from Claude
    pub has_github: bool,    // any comment on this line came from GitHub
    pub claude_author: bool, // for Comment rows: authored by Claude (purple)
    pub reply_row: bool,     // for Comment rows: a reply (extra indent)
    /// intra-line word-diff spans (text, changed) — set on paired modified lines only.
    pub word_hl: Option<Vec<(String, bool)>>,
    /// the comment this row belongs to: the root id on an anchor line or a thread-root
    /// row, the reply id on a reply row. Drives reply/edit/delete/react targeting.
    pub comment_id: Option<String>,
    /// Language used to syntax-highlight an inline comment code row.
    pub code_ext: Option<String>,
}

impl Default for DiffLine {
    fn default() -> Self {
        DiffLine {
            text: String::new(),
            kind: DiffKind::Ctx,
            new_ln: None,
            old_ln: None,
            comments: 0,
            has_claude: false,
            has_github: false,
            claude_author: false,
            reply_row: false,
            word_hl: None,
            comment_id: None,
            code_ext: None,
        }
    }
}

pub enum Modal {
    Compose(Compose),
    Claude(ClaudeForm),
    Confirm {
        prompt: String,
        action: ConfirmAction,
    },
    /// PR actions menu: (accelerator key, label, action).
    Actions(Vec<(char, String, ConfirmAction)>),
    /// React to the thread `comment_id`: pick a reaction by its number key.
    React {
        comment_id: String,
    },
    Palette {
        query: String,
        selected: usize,
    },
    AddressPreview {
        ids: Vec<String>,
        rows: Vec<String>,
    },
    Summary(Vec<String>),
    PromptPreview {
        prompt: String,
        form: ClaudeForm,
    },
}

#[derive(Debug, Clone)]
pub struct ImplementationResult {
    pub rows: Vec<String>,
    pub commit: String,
    pub worktree: String,
    pub original_head: String,
    pub pushed: bool,
    pub showing_implementation: bool,
    pub busy: Option<String>,
}

#[derive(Clone)]
pub enum ConfirmAction {
    DeleteThread(String),
    /// A `gh pr` command (args), e.g. ["merge","<n>","--squash"], with a human label.
    PrCommand(Vec<String>),
}

pub struct Compose {
    pub title: String,
    pub buffer: String,
    pub is_suggestion: bool,
    pub file: String,
    pub line: u32,
    pub line_end: u32,
    pub reply_to: Option<String>,
    /// when set, submitting edits this comment's body instead of creating a new one.
    pub edit_of: Option<String>,
}

#[derive(Clone)]
pub struct ClaudeForm {
    pub profiles: Vec<String>,
    pub selected: usize,
    pub direction: String,
    pub allow_edits: bool,
    pub auto_resolve: bool,
    pub address_comments: bool,
    pub address_ids: Vec<String>,
    pub push_changes: bool,
}

#[derive(Clone)]
pub struct Config {
    pub claude_bin: String,
    pub base: String,
    pub saved_instructions: Vec<(String, String)>,
    pub address_test_commands: Vec<String>,
    pub protected_paths: Vec<String>,
    pub commit_strategy: String,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            claude_bin: "claude".into(),
            base: "auto".into(),
            saved_instructions: vec![
                ("Critical review".into(),
                 "Be a rigorous, skeptical reviewer. Prioritize correctness, edge cases, and failure modes over style.".into()),
                ("InfoSec review".into(),
                 "Review strictly for security: injection, authz/authn, secrets, unsafe deserialization, path traversal, SSRF, crypto misuse, unsafe subprocess use.".into()),
            ],
            address_test_commands: vec![],
            protected_paths: vec!["vendor/".into(), "generated/".into()],
            commit_strategy: "single".into(),
        }
    }
}

pub struct App {
    pub source: Source,
    pub store: Store,
    pub cfg: Config,
    pub panel: Panel,
    pub main_tab: MainTab,
    pub files_state: ListState,
    pub commits_state: ListState,
    pub current_file: Option<String>,
    pub diff: Vec<DiffLine>,
    pub diff_state: ListState,
    pub conv_scroll: u16,
    pub timeline_scroll: u16,
    pub claude_scroll: u16,
    pub claude_rx: Option<Receiver<ClaudeEvent>>,
    pub claude_session: Option<Session>,
    pub status: String,
    pub show_help: bool,
    pub modal: Option<Modal>,
    pub implementation_result: Option<ImplementationResult>,
    pub result_drawer_open: bool,
    pub should_quit: bool,
    /// diff row index where visual-line selection was anchored (None = not selecting).
    pub visual_anchor: Option<usize>,
    /// last-rendered main content height, for half/full-page scrolling.
    pub main_h: u16,
    /// set when the user asks to return to the PR/branch picker.
    pub request_picker: bool,
    /// root ids of threads expanded inline in the diff.
    pub expanded: std::collections::HashSet<String>,
    /// selection state for the Comments view.
    pub comments_state: ListState,
    /// jump targets for the Comments view rows: (file, line, root_id) or None (header).
    pub comment_targets: Vec<Option<(String, u32, String)>>,
    /// the Publish-to-GitHub preview, when open.
    pub publish: Option<crate::publish::PublishView>,
    /// when Some(sha), the Diff tab is showing a single commit's diff (read-only).
    pub commit_view: Option<String>,
    /// in-diff search: current query + whether we're typing it.
    pub search: String,
    pub searching: bool,
    /// set to a file path when the user asks to open it in $EDITOR (handled by the loop).
    pub pending_editor: Option<String>,
    /// Temporary compose file awaiting a round trip through `$EDITOR`.
    pub pending_compose_editor: Option<String>,
    pub pending_prompt_editor: Option<String>,
    pending_prompt_form: Option<ClaudeForm>,
    /// number of diff context lines (GitHub-style expand context; default 3).
    pub diff_context: usize,
    /// split (side-by-side) diff view instead of unified.
    pub diff_split: bool,
    /// directory paths collapsed in the Files tree.
    pub collapsed_dirs: std::collections::HashSet<String>,
    /// flattened, currently-visible Files-tree rows (rebuilt on render).
    pub file_rows: Vec<crate::tree::FileRow>,
    pub comment_filter: u8,
    pub timeline_filter: u8,
    pub thread_drawer: bool,
    pub claude_session_index: usize,
    pub marked_threads: std::collections::HashSet<String>,
    pub comment_query: String,
    pub comment_searching: bool,
    pub location_history: Vec<(String, u32)>,
    raw_diff_cache: HashMap<DiffCacheKey, String>,
    ui_dirty_since: Option<Instant>,
    refresh_rx: Option<Receiver<Result<Source, String>>>,
    pending_claude_form: Option<ClaudeForm>,
    pending_claude_prompt: Option<String>,
    diff_prefetch_rx: Option<Receiver<DiffPrefetch>>,
    diff_generation: u64,
    implementation_action_rx: Option<Receiver<Result<(), String>>>,
}

impl App {
    pub fn new(source: Source, mut store: Store, cfg: Config) -> App {
        // Pull in the PR's existing review conversation so it shows on the diff/Comments.
        if source.caps.has_threads {
            crate::data::github_sync::import(&mut store, &source);
        }
        let mut files_state = ListState::default();
        if !source.files.is_empty() {
            files_state.select(Some(0));
        }
        let mut commits_state = ListState::default();
        if !source.commits.is_empty() {
            commits_state.select(Some(0));
        }
        let claude_session = store.latest_session().cloned();
        let saved_ui = store.ui.clone();
        let mut app = App {
            source,
            store,
            cfg,
            panel: Panel::Files,
            main_tab: Self::tab_from_u8(saved_ui.tab),
            files_state,
            commits_state,
            current_file: None,
            diff: vec![],
            diff_state: ListState::default(),
            conv_scroll: saved_ui.conv_scroll,
            timeline_scroll: saved_ui.timeline_scroll,
            claude_scroll: saved_ui.claude_scroll,
            claude_rx: None,
            claude_session,
            status: "j/k move · n/N next/prev comment · space expand · 4 comments view · c comment · a Claude · ? help".into(),
            show_help: false,
            modal: None,
            implementation_result: None,
            result_drawer_open: false,
            should_quit: false,
            visual_anchor: None,
            main_h: 20,
            request_picker: false,
            expanded: std::collections::HashSet::new(),
            comments_state: ListState::default(),
            comment_targets: vec![],
            publish: None,
            commit_view: None,
            search: String::new(),
            searching: false,
            pending_editor: None,
            pending_compose_editor: None,
            pending_prompt_editor: None,
            pending_prompt_form: None,
            diff_context: 3,
            diff_split: false,
            collapsed_dirs: saved_ui.collapsed_dirs,
            file_rows: vec![],
            comment_filter: 0,
            timeline_filter: 0,
            thread_drawer: false,
            claude_session_index: 0,
            marked_threads: std::collections::HashSet::new(),
            comment_query: String::new(),
            comment_searching: false,
            location_history: vec![],
            raw_diff_cache: HashMap::new(),
            ui_dirty_since: None,
            refresh_rx: None,
            pending_claude_form: None,
            pending_claude_prompt: None,
            diff_prefetch_rx: None,
            diff_generation: 0,
            implementation_action_rx: None,
        };
        app.rebuild_file_rows();
        if let Some(f) = saved_ui
            .file
            .filter(|p| app.source.files.iter().any(|f| f.path == *p))
            .or_else(|| app.source.files.first().map(|f| f.path.clone()))
        {
            app.current_file = Some(f);
            app.load_diff();
            app.diff_state.select(Some(
                saved_ui.diff_row.min(app.diff.len().saturating_sub(1)),
            ));
        }
        app.start_diff_prefetch();
        app
    }

    fn tab_from_u8(v: u8) -> MainTab {
        [
            MainTab::Diff,
            MainTab::Conversation,
            MainTab::Timeline,
            MainTab::Claude,
            MainTab::Comments,
        ]
        .get(v as usize)
        .copied()
        .unwrap_or(MainTab::Diff)
    }

    fn persist_ui(&mut self) {
        let tab = [
            MainTab::Diff,
            MainTab::Conversation,
            MainTab::Timeline,
            MainTab::Claude,
            MainTab::Comments,
        ]
        .iter()
        .position(|t| *t == self.main_tab)
        .unwrap_or(0) as u8;
        self.store.stage_ui(crate::data::store::UiPrefs {
            tab,
            file: self.current_file.clone(),
            diff_row: self.diff_state.selected().unwrap_or(0),
            conv_scroll: self.conv_scroll,
            timeline_scroll: self.timeline_scroll,
            claude_scroll: self.claude_scroll,
            collapsed_dirs: self.collapsed_dirs.clone(),
        });
        self.ui_dirty_since.get_or_insert_with(Instant::now);
    }

    /// Flush debounced UI preferences. Returns whether a write occurred.
    pub fn flush_ui(&mut self, force: bool) -> bool {
        let due = self
            .ui_dirty_since
            .is_some_and(|at| force || at.elapsed() >= Duration::from_millis(750));
        if due {
            self.store.save();
            self.ui_dirty_since = None;
        }
        due
    }

    fn start_diff_prefetch(&mut self) {
        self.diff_generation = self.diff_generation.wrapping_add(1);
        let generation = self.diff_generation;
        let base = self.source.base_sha.clone();
        let head = self.source.head_sha.clone();
        let root = self.source.repo_root.clone();
        let context = self.diff_context;
        let files: Vec<_> = self.source.files.iter().map(|f| f.path.clone()).collect();
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            for file in files {
                let started = Instant::now();
                let raw = git::file_diff_ctx(&base, &head, &file, context, Some(&root));
                crate::perf::record("git.prefetch_diff", started.elapsed());
                let key = (base.clone(), head.clone(), file, context);
                if tx.send((generation, key, raw)).is_err() {
                    break;
                }
            }
        });
        // Replacing the receiver cancels delivery from the previous generation.
        self.diff_prefetch_rx = Some(rx);
    }

    pub fn context_hint(&self) -> &'static str {
        match (self.panel, self.main_tab) {
            (Panel::Files, _) => {
                "j/k move · l open/collapse · m viewed · R refresh · tab focus · : commands"
            }
            (Panel::Commits, _) => {
                "j/k move · enter inspect commit · R refresh · o editor · tab focus · : commands"
            }
            (_, MainTab::Diff) => {
                "j/k move · c comment · space thread · R refresh · o editor · : commands"
            }
            (_, MainTab::Comments) => "j/k move · enter jump · F filter · O editor · : commands",
            (_, MainTab::Timeline) => "j/k scroll · F filter · O editor · : commands",
            (_, MainTab::Claude) => "h/l session · a review · O editor · : commands",
            _ => "j/k scroll · D thread drawer · O editor · : commands",
        }
    }

    fn cycle_filter(&mut self) {
        match self.main_tab {
            MainTab::Comments => {
                self.comment_filter = (self.comment_filter + 1) % 8;
                self.status = format!(
                    "comments filter: {}",
                    [
                        "all",
                        "unresolved",
                        "resolved",
                        "claude",
                        "clarification",
                        "committed",
                        "unpushed",
                        "selected",
                    ][self.comment_filter as usize]
                );
            }
            MainTab::Timeline => {
                self.timeline_filter = (self.timeline_filter + 1) % 4;
                self.status = format!(
                    "timeline filter: {}",
                    ["all", "commits", "reviews", "decisions"][self.timeline_filter as usize]
                );
            }
            _ => self.status = "Filters are available in Comments and Timeline.".into(),
        }
    }

    fn selected_thread_id(&self) -> Option<String> {
        if self.main_tab == MainTab::Comments {
            return self
                .comments_state
                .selected()
                .and_then(|i| self.comment_targets.get(i))
                .and_then(|x| x.as_ref())
                .map(|x| x.2.clone());
        }
        self.current_root().map(|c| c.id)
    }

    fn toggle_mark_thread(&mut self) {
        let Some(id) = self.selected_thread_id() else {
            self.status = "No thread selected.".into();
            return;
        };
        if !self.marked_threads.remove(&id) {
            self.marked_threads.insert(id);
        }
        self.status = format!("{} thread(s) selected", self.marked_threads.len());
    }

    fn mark_visible_threads(&mut self) {
        self.marked_threads.extend(
            self.comment_targets
                .iter()
                .filter_map(|x| x.as_ref().map(|x| x.2.clone())),
        );
        self.status = format!("{} thread(s) selected", self.marked_threads.len());
    }

    fn assess_thread(&self, id: &str, selected: &[String]) -> String {
        let Some(c) = self.store.get(id) else {
            return "missing".into();
        };
        if c.outdated {
            return "stale/outdated".into();
        }
        if c.status == "resolved" || matches!(c.workflow_state.as_str(), "pushed" | "verified") {
            return "already addressed".into();
        }
        if selected.iter().filter_map(|x| self.store.get(x)).any(|x| {
            x.id != c.id && x.file == c.file && x.line_start == c.line_start && x.body != c.body
        }) {
            return "conflicts with another selected comment".into();
        }
        let body = c.body.to_lowercase();
        if ["clarify", "which behavior", "product decision", "not sure"]
            .iter()
            .any(|x| body.contains(x))
        {
            "needs clarification".into()
        } else {
            "actionable".into()
        }
    }

    fn preview_address_threads(&mut self) {
        let mut ids: Vec<String> = if self.marked_threads.is_empty() {
            self.selected_thread_id().into_iter().collect()
        } else {
            self.marked_threads.iter().cloned().collect()
        };
        ids.sort();
        if ids.is_empty() {
            self.status = "Select or mark at least one thread.".into();
            return;
        }
        let assessments: Vec<_> = ids
            .iter()
            .map(|id| (id.clone(), self.assess_thread(id, &ids)))
            .collect();
        let rows = assessments
            .iter()
            .map(|(id, assessment)| {
                if let Some(c) = self.store.get(id) {
                    format!("{}:{}  {}  — {assessment}", c.file, c.line_start, c.author)
                } else {
                    format!("{id} — missing")
                }
            })
            .collect();
        for (id, assessment) in &assessments {
            self.store
                .update_workflow(id, "assessed", Some(assessment.as_str()));
        }
        let actionable_ids = assessments
            .into_iter()
            .filter_map(|(id, assessment)| (assessment == "actionable").then_some(id))
            .collect();
        self.modal = Some(Modal::AddressPreview {
            ids: actionable_ids,
            rows,
        });
    }

    fn set_thread_workflow(&mut self, state: &str) {
        if let Some(id) = self.selected_thread_id() {
            self.store.update_workflow(&id, state, None);
            self.status = format!("thread: {state}");
        }
    }

    fn cycle_thread_label(&mut self) {
        if let Some(id) = self.selected_thread_id() {
            self.store.cycle_label(&id);
            self.status = format!(
                "label: {}",
                self.store.get(&id).map(|c| c.label.as_str()).unwrap_or("")
            );
        }
    }

    fn cycle_thread_priority(&mut self) {
        if let Some(id) = self.selected_thread_id() {
            self.store.cycle_priority(&id);
            self.status = format!(
                "priority: P{}",
                self.store.get(&id).map(|c| c.priority).unwrap_or(0)
            );
        }
    }

    fn cycle_thread_owner(&mut self) {
        if let Some(id) = self.selected_thread_id() {
            self.store.cycle_owner(&id);
            self.status = format!(
                "next action: {}",
                self.store
                    .get(&id)
                    .map(|c| c.action_owner.as_str())
                    .unwrap_or("")
            );
        }
    }

    fn jump_workflow(&mut self, actionable: bool) {
        let mut roots = self.store.all_threads();
        roots.sort_by(|a, b| a.file.cmp(&b.file).then(a.line_start.cmp(&b.line_start)));
        let wanted: Vec<_> = roots
            .into_iter()
            .filter(|c| {
                !c.outdated
                    && c.status != "resolved"
                    && (!actionable
                        || !matches!(
                            c.workflow_state.as_str(),
                            "needs_clarification" | "deferred" | "task" | "pushed" | "verified"
                        ))
            })
            .collect();
        if let Some(c) = wanted.first() {
            self.jump_to_comment(&c.file, c.line_start, &c.id);
        } else {
            self.status = "no matching thread".into();
        }
    }

    fn palette_action(&mut self, idx: usize) {
        match idx {
            0 => self.main_tab = MainTab::Diff,
            1 => self.main_tab = MainTab::Conversation,
            2 => self.main_tab = MainTab::Timeline,
            3 => self.main_tab = MainTab::Claude,
            4 => self.main_tab = MainTab::Comments,
            5 => self.open_view_in_editor(),
            6 => self.thread_drawer = !self.thread_drawer,
            7 => self.cycle_filter(),
            8 => self.open_claude_form(),
            _ => self.show_help = true,
        }
        self.panel = Panel::Main;
    }

    // --- diff loading ---------------------------------------------------------
    pub fn load_diff(&mut self) {
        let Some(file) = self.current_file.clone() else {
            return;
        };
        // Remember which source line the cursor was on so a rebuild (expand/comment/
        // refresh) keeps the cursor there instead of jumping to the top. If the cursor
        // is on an inline thread row (new_ln == None), fall back to the nearest anchor
        // line above it so we stay on the thread rather than snapping to the top.
        let keep_ln = self.diff_state.selected().and_then(|i| {
            if self.diff.is_empty() {
                return None;
            }
            let i = i.min(self.diff.len() - 1);
            self.diff[i]
                .new_ln
                .or_else(|| self.diff[..=i].iter().rev().find_map(|d| d.new_ln))
        });
        let cache_key = (
            self.source.base_sha.clone(),
            self.source.head_sha.clone(),
            file.clone(),
            self.diff_context,
        );
        let raw = if let Some(raw) = self.raw_diff_cache.get(&cache_key) {
            raw.clone()
        } else {
            let started = Instant::now();
            let raw = git::file_diff_ctx(
                &self.source.base_sha,
                &self.source.head_sha,
                &file,
                self.diff_context,
                Some(&self.source.repo_root),
            );
            crate::perf::record("git.file_diff", started.elapsed());
            self.raw_diff_cache.insert(cache_key, raw.clone());
            raw
        };
        // Map new-side line -> trimmed code, used to reposition/outdate comments whose
        // anchored line moved or changed since they were written.
        let code_at = Self::code_by_line(&raw);
        self.reconcile_file(&file, &code_at);
        let counts = self.comment_counts(&file);
        // Precompute line -> visible root-thread id ONCE (was an O(lines×comments) rescan
        // inside the loop). Outdated/hidden threads aren't shown inline.
        let anchor_by_line: std::collections::HashMap<u32, String> = self
            .store
            .threads_for_file(&file)
            .into_iter()
            .filter(|r| r.side == "RIGHT" && !r.hidden && !r.outdated)
            .map(|r| (r.line_start, r.id))
            .collect();
        let mut lines = vec![];
        let mut new_ln: u32 = 0;
        let mut old_ln: u32 = 0;
        for l in raw.lines() {
            let (kind, nl, ol) = if l.starts_with("diff --git")
                || l.starts_with("index ")
                || l.starts_with("--- ")
                || l.starts_with("+++ ")
            {
                (DiffKind::Meta, None, None)
            } else if l.starts_with("@@") {
                if let Some(seg) = l.split('+').nth(1) {
                    if let Some(n) = seg
                        .split([',', ' '])
                        .next()
                        .and_then(|x| x.parse::<u32>().ok())
                    {
                        new_ln = n.saturating_sub(1);
                    }
                }
                if let Some(seg) = l.split('-').nth(1) {
                    if let Some(n) = seg
                        .split([',', ' '])
                        .next()
                        .and_then(|x| x.parse::<u32>().ok())
                    {
                        old_ln = n.saturating_sub(1);
                    }
                }
                (DiffKind::Hunk, None, None)
            } else if let Some(_r) = l.strip_prefix('+') {
                new_ln += 1;
                (DiffKind::Add, Some(new_ln), None)
            } else if l.starts_with('-') {
                old_ln += 1;
                (DiffKind::Del, None, Some(old_ln))
            } else if l.starts_with(' ') {
                new_ln += 1;
                old_ln += 1;
                (DiffKind::Ctx, Some(new_ln), Some(old_ln))
            } else {
                // Header/mode lines ("new file mode", "rename from", …) and blanks: metadata.
                (DiffKind::Meta, None, None)
            };
            let (comments, has_claude, has_github) = nl
                .and_then(|n| counts.get(&n).copied())
                .unwrap_or((0, false, false));
            // The root thread anchored on this line, if any — so acting from the anchor
            // line (not just from inside an expanded thread) targets the right comment.
            let anchor_root = nl.and_then(|n| anchor_by_line.get(&n).cloned());
            lines.push(DiffLine {
                text: l.to_string(),
                kind,
                new_ln: nl,
                old_ln: ol,
                comments,
                has_claude,
                has_github,
                comment_id: anchor_root.clone(),
                ..Default::default()
            });
            // If a thread is anchored here and expanded, render it inline below the line.
            if let (Some(_), Some(rid)) = (nl, &anchor_root) {
                if self.expanded.contains(rid) {
                    if let Some(root) = self.store.get(rid).cloned() {
                        self.push_thread_rows(&mut lines, &root);
                    }
                }
            }
        }
        if lines.is_empty() {
            lines.push(DiffLine {
                text: "(no changes)".into(),
                kind: DiffKind::Meta,
                ..Default::default()
            });
        } else if raw.contains("Binary files") {
            lines.push(DiffLine {
                text: "(binary file — not shown)".into(),
                kind: DiffKind::Meta,
                ..Default::default()
            });
        } else if !lines
            .iter()
            .any(|d| matches!(d.kind, DiffKind::Add | DiffKind::Del | DiffKind::Ctx))
        {
            lines.push(DiffLine {
                text: "(no textual changes — mode/rename only)".into(),
                kind: DiffKind::Meta,
                ..Default::default()
            });
        }
        crate::diffview::annotate_word_diff(&mut lines);
        let idx = keep_ln
            .and_then(|n| lines.iter().position(|d| d.new_ln == Some(n)))
            .unwrap_or(0);
        self.diff = lines;
        self.diff_state.select(Some(idx));
    }

    /// Load a single commit's diff into the Diff tab (read-only, no comments).
    pub fn load_commit_diff(&mut self, sha: &str) {
        let raw = crate::data::git::commit_diff(sha, Some(&self.source.repo_root));
        let mut lines = vec![];
        let mut new_ln: u32 = 0;
        let mut old_ln: u32 = 0;
        for l in raw.lines() {
            let (kind, nl, ol) = if l.starts_with("diff --git")
                || l.starts_with("index ")
                || l.starts_with("--- ")
                || l.starts_with("+++ ")
            {
                (DiffKind::Meta, None, None)
            } else if l.starts_with("@@") {
                if let Some(seg) = l.split('+').nth(1) {
                    if let Some(n) = seg
                        .split([',', ' '])
                        .next()
                        .and_then(|x| x.parse::<u32>().ok())
                    {
                        new_ln = n.saturating_sub(1);
                    }
                }
                if let Some(seg) = l.split('-').nth(1) {
                    if let Some(n) = seg
                        .split([',', ' '])
                        .next()
                        .and_then(|x| x.parse::<u32>().ok())
                    {
                        old_ln = n.saturating_sub(1);
                    }
                }
                (DiffKind::Hunk, None, None)
            } else if l.starts_with('+') {
                new_ln += 1;
                (DiffKind::Add, Some(new_ln), None)
            } else if l.starts_with('-') {
                old_ln += 1;
                (DiffKind::Del, None, Some(old_ln))
            } else if l.starts_with(' ') {
                new_ln += 1;
                old_ln += 1;
                (DiffKind::Ctx, Some(new_ln), Some(old_ln))
            } else {
                (DiffKind::Meta, None, None)
            };
            lines.push(DiffLine {
                text: l.to_string(),
                kind,
                new_ln: nl,
                old_ln: ol,
                ..Default::default()
            });
        }
        if lines.is_empty() {
            lines.push(DiffLine {
                text: "(empty commit)".into(),
                kind: DiffKind::Meta,
                ..Default::default()
            });
        }
        crate::diffview::annotate_word_diff(&mut lines);
        self.diff = lines;
        self.diff_state.select(Some(0));
        self.commit_view = Some(sha.to_string());
        self.panel = Panel::Main;
        self.main_tab = MainTab::Diff;
        self.status = format!(
            "commit {} (read-only) — select a file to return",
            &sha[..sha.len().min(8)]
        );
    }

    /// Toggle the "Viewed" flag for the file under the Files cursor (or the current file).
    fn toggle_viewed(&mut self) {
        let file = if self.panel == Panel::Files {
            self.selected_file()
        } else {
            self.current_file.clone()
        };
        if let Some(f) = file {
            self.store.toggle_viewed(&f);
            let n = self
                .source
                .files
                .iter()
                .filter(|x| self.store.is_viewed(&x.path))
                .count();
            self.status = format!(
                "{} — {}/{} files viewed",
                if self.store.is_viewed(&f) {
                    "viewed"
                } else {
                    "unviewed"
                },
                n,
                self.source.files.len()
            );
        }
    }

    /// Apply a `suggestion` thread: write the replacement into a worktree at head and commit
    /// it (never pushed) — GitHub's "commit suggestion".
    fn apply_suggestion(&mut self) {
        let Some(root) = self.current_root() else {
            self.status = "Select a suggestion thread first.".into();
            return;
        };
        let sug = root
            .suggestion_text
            .clone()
            .or_else(|| extract_suggestion(&root.body).1);
        let Some(sug) = sug else {
            self.status = "That thread has no suggestion block.".into();
            return;
        };
        let wt = match crate::data::worktree::ensure(&self.source.repo_root, &self.source.head_sha)
        {
            Ok(p) => p,
            Err(e) => {
                self.status = format!("worktree failed: {e}");
                return;
            }
        };
        let path = wt.join(&root.file);
        let Ok(content) = std::fs::read_to_string(&path) else {
            self.status = format!("cannot read {} in worktree", root.file);
            return;
        };
        let mut lines: Vec<&str> = content.lines().collect();
        let (lo, hi) = (
            (root.line_start as usize).saturating_sub(1),
            (root.line_end as usize).saturating_sub(1),
        );
        if lo >= lines.len() {
            self.status = "suggestion target line is out of range".into();
            return;
        }
        let hi = hi.min(lines.len() - 1);
        let sug_lines: Vec<&str> = sug.lines().collect();
        let mut out: Vec<&str> = Vec::new();
        out.extend_from_slice(&lines[..lo]);
        out.extend_from_slice(&sug_lines);
        out.extend_from_slice(&lines[hi + 1..]);
        let _ = &mut lines;
        let new_content = out.join("\n") + "\n";
        if std::fs::write(&path, new_content).is_err() {
            self.status = "failed to write the suggestion".into();
            return;
        }
        let rel = root.file.clone();
        let wt_s = wt.to_string_lossy().to_string();
        crate::data::proc::git(&["add", &rel], Some(&wt_s));
        let (ok, _, err) = crate::data::proc::git(
            &["commit", "-m", &format!("Apply suggestion to {rel}")],
            Some(&wt_s),
        );
        if ok {
            self.status = format!("suggestion committed in worktree {wt_s} (not pushed)");
        } else {
            self.status = format!("commit failed: {}", err.lines().next().unwrap_or(""));
        }
    }

    /// Request opening the current diff's file at the reviewed head (or commit) in $EDITOR.
    fn open_in_editor(&mut self) {
        let Some(file) = self.current_file.clone() else {
            self.status = "Open a file's diff first.".into();
            return;
        };
        let sha = self
            .commit_view
            .clone()
            .unwrap_or_else(|| self.source.head_sha.clone());
        match crate::data::worktree::ensure(&self.source.repo_root, &sha) {
            Ok(wt) => {
                self.pending_editor = Some(wt.join(&file).to_string_lossy().to_string());
                self.status = "opening in $EDITOR…".into();
            }
            Err(e) => self.status = format!("worktree failed: {e}"),
        }
    }

    /// Export the active view as a complete Markdown or diff buffer for the editor.
    fn open_view_in_editor(&mut self) {
        let (text, extension) = if self.main_tab == MainTab::Diff {
            let text = if let Some(sha) = &self.commit_view {
                git::commit_diff(sha, Some(&self.source.repo_root))
            } else if let Some(file) = &self.current_file {
                git::file_diff_ctx(
                    &self.source.base_sha,
                    &self.source.head_sha,
                    file,
                    self.diff_context,
                    Some(&self.source.repo_root),
                )
            } else {
                git::full_diff(
                    &self.source.base_sha,
                    &self.source.head_sha,
                    Some(&self.source.repo_root),
                )
            };
            (text, "diff")
        } else {
            let Some(text) = crate::view_export::markdown(self.main_tab, &self.source, &self.store)
            else {
                return;
            };
            (text, "md")
        };
        let name = format!(
            "prtui-{}-{}-{}.{}",
            std::process::id(),
            crate::view_export::slug(self.main_tab),
            crate::data::store::timestamp(),
            extension,
        );
        let path = std::env::temp_dir().join(name);
        match std::fs::write(&path, text) {
            Ok(()) => {
                self.pending_editor = Some(path.to_string_lossy().to_string());
                self.status = format!(
                    "opening {} view in $EDITOR…",
                    crate::view_export::slug(self.main_tab)
                );
            }
            Err(e) => self.status = format!("view export failed: {e}"),
        }
    }

    fn open_compose_in_editor(&mut self, buffer: &str) {
        let path = std::env::temp_dir().join(format!(
            "prtui-compose-{}-{}.md",
            std::process::id(),
            crate::data::store::timestamp()
        ));
        match std::fs::write(&path, buffer) {
            Ok(()) => {
                let path = path.to_string_lossy().to_string();
                self.pending_compose_editor = Some(path.clone());
                self.pending_editor = Some(path);
                self.status = "editing comment in $EDITOR…".into();
            }
            Err(e) => self.status = format!("could not open comment editor: {e}"),
        }
    }

    fn open_prompt_in_editor(&mut self, prompt: &str, form: ClaudeForm) {
        let path = std::env::temp_dir().join(format!(
            "prtui-prompt-{}-{}.md",
            std::process::id(),
            crate::data::store::timestamp()
        ));
        match std::fs::write(&path, prompt) {
            Ok(()) => {
                let path = path.to_string_lossy().to_string();
                self.pending_prompt_editor = Some(path.clone());
                self.pending_prompt_form = Some(form);
                self.pending_editor = Some(path);
                self.status = "editing final Claude prompt in $EDITOR…".into();
            }
            Err(e) => self.status = format!("could not open prompt editor: {e}"),
        }
    }

    /// Reload compose text after the synchronous editor process exits.
    pub fn editor_closed(&mut self, path: &str) {
        if self.pending_prompt_editor.as_deref() == Some(path) {
            self.pending_prompt_editor = None;
            match std::fs::read_to_string(path) {
                Ok(text) => {
                    let form = self.pending_prompt_form.take().unwrap_or(ClaudeForm {
                        profiles: vec!["(none)".into()],
                        selected: 0,
                        direction: String::new(),
                        allow_edits: false,
                        auto_resolve: false,
                        address_comments: false,
                        address_ids: vec![],
                        push_changes: false,
                    });
                    self.modal = Some(Modal::PromptPreview { prompt: text, form });
                    self.status = "revised prompt ready to copy".into();
                }
                Err(e) => self.status = format!("could not reload edited prompt: {e}"),
            }
            return;
        }
        if self.pending_compose_editor.as_deref() != Some(path) {
            return;
        }
        self.pending_compose_editor = None;
        match std::fs::read_to_string(path) {
            Ok(text) => {
                if let Some(Modal::Compose(compose)) = self.modal.as_mut() {
                    compose.buffer = text;
                    self.status = "comment updated from $EDITOR".into();
                }
            }
            Err(e) => self.status = format!("could not reload edited comment: {e}"),
        }
    }

    fn search_key(&mut self, key: KeyEvent) {
        match key.code {
            KeyCode::Esc => {
                self.searching = false;
                self.search.clear();
            }
            KeyCode::Enter => {
                self.searching = false;
            }
            KeyCode::Backspace => {
                self.search.pop();
                self.search_jump();
            }
            KeyCode::Char(c) => {
                self.search.push(c);
                self.search_jump();
            }
            _ => {}
        }
    }

    /// Move the diff cursor to the first line containing the query (case-insensitive).
    fn search_jump(&mut self) {
        if self.search.is_empty() {
            return;
        }
        let q = self.search.to_lowercase();
        let start = self.diff_state.selected().unwrap_or(0);
        let n = self.diff.len();
        // Search from the current position forward, wrapping around.
        for off in 0..n {
            let i = (start + off) % n;
            if self.diff[i].text.to_lowercase().contains(&q) {
                self.diff_state.select(Some(i));
                return;
            }
        }
    }

    fn push_thread_rows(&self, lines: &mut Vec<DiffLine>, root: &crate::data::store::Comment) {
        // Each row is tagged with the id of the comment it belongs to (root or reply) so
        // reply/edit/delete/react act on exactly the comment under the cursor.
        let row = |text: String,
                   claude: bool,
                   reply: bool,
                   id: &str,
                   code_ext: Option<String>|
         -> DiffLine {
            DiffLine {
                text,
                kind: DiffKind::Comment,
                claude_author: claude,
                reply_row: reply,
                comment_id: Some(id.to_string()),
                code_ext,
                ..Default::default()
            }
        };
        let claude = root.origin == "claude";
        let icon = if claude { "★" } else { "▸" };
        let status = if root.status == "resolved" {
            "  (resolved)"
        } else {
            ""
        };
        lines.push(row(
            format!("{icon} {}{status}", root.author),
            claude,
            false,
            &root.id,
            None,
        ));
        let fallback_ext = crate::syntax::ext_of(&root.file);
        let push_body = |lines: &mut Vec<DiffLine>,
                         body: &str,
                         indent: &str,
                         author: bool,
                         reply: bool,
                         id: &str| {
            let mut code: Option<String> = None;
            for l in body.lines() {
                if let Some(lang) = l.trim_start().strip_prefix("```") {
                    if code.is_some() {
                        code = None;
                    } else {
                        let lang = lang.trim();
                        code = Some(if lang.is_empty() || lang == "suggestion" {
                            fallback_ext.clone()
                        } else {
                            match lang {
                                "rust" => "rs",
                                "python" => "py",
                                "javascript" => "js",
                                "typescript" => "ts",
                                "c++" => "cpp",
                                "golang" => "go",
                                "shell" | "bash" => "sh",
                                other => other,
                            }
                            .to_string()
                        });
                    }
                    continue;
                }
                lines.push(row(format!("{indent}{l}"), author, reply, id, code.clone()));
            }
        };
        push_body(lines, &root.body, "  ", claude, false, &root.id);
        let chips = |c: &crate::data::store::Comment| -> Option<String> {
            (!c.reactions.is_empty()).then(|| {
                c.reactions
                    .iter()
                    .map(|(n, who)| format!("[{n} {}]", who.len()))
                    .collect::<Vec<_>>()
                    .join(" ")
            })
        };
        if let Some(ch) = chips(root) {
            lines.push(row(format!("  {ch}"), claude, false, &root.id, None));
        }
        if root.kind == "suggestion" {
            if let Some(sug) = &root.suggestion_text {
                lines.push(row("  suggestion:".into(), claude, false, &root.id, None));
                for l in sug.lines() {
                    lines.push(row(
                        format!("    {l}"),
                        claude,
                        false,
                        &root.id,
                        Some(fallback_ext.clone()),
                    ));
                }
            }
        }
        for rep in self.store.replies(&root.id) {
            let rc = rep.origin == "claude";
            lines.push(row(format!("  ↳ {}", rep.author), rc, true, &rep.id, None));
            push_body(lines, &rep.body, "      ", rc, true, &rep.id);
            if let Some(ch) = chips(&rep) {
                lines.push(row(format!("      {ch}"), rc, true, &rep.id, None));
            }
        }
        lines.push(row(
            "  ╰─ space: collapse · r: reply · e: edit · E: react".into(),
            claude,
            true,
            &root.id,
            None,
        ));
    }

    /// Toggle the inline thread under the cursor. Works both from a thread's anchor line
    /// and from within its expanded rows (so `space` collapses it from anywhere inside).
    /// Returns true if a thread was found (so callers know the key was consumed).
    pub fn toggle_thread_inline(&mut self) -> bool {
        let Some(id) = self.current_comment_id() else {
            return false;
        };
        let root = self.store.root_of(&id);
        if !self.expanded.remove(&root) {
            self.expanded.insert(root);
        }
        self.load_diff();
        true
    }

    /// Parse a unified diff into a map of new-side line number -> trimmed code, for the
    /// added and context lines (the ones a RIGHT-side comment can anchor to).
    fn code_by_line(raw: &str) -> std::collections::HashMap<u32, String> {
        let mut map = std::collections::HashMap::new();
        let mut new_ln: u32 = 0;
        for l in raw.lines() {
            if l.starts_with("@@") {
                if let Some(seg) = l.split('+').nth(1) {
                    if let Some(n) = seg
                        .split([',', ' '])
                        .next()
                        .and_then(|x| x.parse::<u32>().ok())
                    {
                        new_ln = n.saturating_sub(1);
                    }
                }
            } else if let Some(code) = l.strip_prefix('+') {
                new_ln += 1;
                map.insert(new_ln, code.trim().to_string());
            } else if l.starts_with('-')
                || l.starts_with("diff --git")
                || l.starts_with("index ")
                || l.starts_with("--- ")
                || l.starts_with("+++ ")
            {
                // deletions and headers don't advance the new-side counter
            } else if let Some(code) = l.strip_prefix(' ') {
                new_ln += 1;
                map.insert(new_ln, code.trim().to_string());
            }
        }
        map
    }

    /// Reconcile a file's RIGHT-side comments against the current diff: if a comment's
    /// anchored code moved, reposition it; if the code is gone, mark it outdated (GitHub
    /// "Outdated"). GitHub-imported threads keep the server's own outdated flag.
    fn reconcile_file(&mut self, file: &str, code_at: &std::collections::HashMap<u32, String>) {
        let roots: Vec<crate::data::store::Comment> = self
            .store
            .threads_for_file(file)
            .into_iter()
            .filter(|r| r.side == "RIGHT" && r.origin != "github")
            .collect();
        let mut changed = false;
        for r in roots {
            // Outdated is sticky (like GitHub): once the code changed, don't resurrect the
            // thread just because an identical line reappears elsewhere.
            if r.outdated {
                continue;
            }
            let anchor = match r.anchor_text.clone() {
                Some(a) if !a.is_empty() => a,
                _ => {
                    // Legacy comment without a snapshot: backfill from the current line so
                    // future reconciles work, but don't judge it outdated this pass.
                    if let Some(code) = code_at.get(&r.line_start) {
                        changed |= self.store.backfill_anchor(&r.id, code);
                    }
                    continue;
                }
            };
            match crate::diffview::locate_anchor(r.line_start, &anchor, code_at) {
                crate::diffview::Anchor::InPlace => {}
                crate::diffview::Anchor::MoveTo(n) => changed |= self.store.reposition(&r.id, n),
                crate::diffview::Anchor::Outdated => {
                    changed |= self.store.set_outdated(&r.id, true)
                }
            }
        }
        if changed {
            self.store.save();
        }
    }

    /// The trimmed code currently shown on `line` of the open diff (for anchoring a new
    /// comment), if that line is an added/context line.
    fn code_at_line(&self, line: u32) -> Option<String> {
        self.diff
            .iter()
            .find(|d| d.new_ln == Some(line) && matches!(d.kind, DiffKind::Add | DiffKind::Ctx))
            .map(|d| d.text.get(1..).unwrap_or("").trim().to_string())
    }

    #[allow(clippy::type_complexity)]
    fn comment_counts(&self, file: &str) -> std::collections::HashMap<u32, (u32, bool, bool)> {
        let mut m: std::collections::HashMap<u32, (u32, bool, bool)> =
            std::collections::HashMap::new();
        for root in self.store.threads_for_file(file) {
            if root.side == "RIGHT" && !root.hidden && !root.outdated {
                let replies = self.store.replies(&root.id);
                let n = 1 + replies.len() as u32;
                let claude =
                    root.origin == "claude" || replies.iter().any(|r| r.origin == "claude");
                let github =
                    root.origin == "github" || replies.iter().any(|r| r.origin == "github");
                let e = m.entry(root.line_start).or_insert((0, false, false));
                e.0 += n;
                e.1 = e.1 || claude;
                e.2 = e.2 || github;
            }
        }
        m
    }

    /// True if any thread anchors to this file.
    pub fn file_has_comments(&self, file: &str) -> bool {
        !self.store.threads_for_file(file).is_empty()
    }

    /// First changed file (in panel order) that has any comment thread.
    fn first_file_with_comments(&self) -> Option<String> {
        self.source
            .files
            .iter()
            .map(|f| f.path.clone())
            .find(|p| self.file_has_comments(p))
    }

    /// Rebuild the flattened Files-tree rows from the changed files + collapse state.
    pub fn rebuild_file_rows(&mut self) {
        self.file_rows = crate::tree::build_rows(&self.source.files, &self.collapsed_dirs);
        // Keep the selection in range.
        if self.file_rows.is_empty() {
            self.files_state.select(None);
        } else {
            let sel = self
                .files_state
                .selected()
                .unwrap_or(0)
                .min(self.file_rows.len() - 1);
            self.files_state.select(Some(sel));
        }
    }

    /// The changed-file path under the Files cursor, if the selected row is a file (not a dir).
    fn selected_file(&self) -> Option<String> {
        let row = self
            .files_state
            .selected()
            .and_then(|i| self.file_rows.get(i))?;
        match row {
            crate::tree::FileRow::File { idx, .. } => {
                self.source.files.get(*idx).map(|f| f.path.clone())
            }
            crate::tree::FileRow::Dir { .. } => None,
        }
    }

    fn diff_target(&self) -> Option<(String, u32)> {
        if self.commit_view.is_some() {
            return None; // commenting is disabled in the read-only commit view
        }
        let file = self.current_file.clone()?;
        let idx = self.diff_state.selected()?;
        let line = self.diff.get(idx)?.new_ln?;
        Some((file, line))
    }

    fn thread_at(&self, file: &str, line: u32) -> Option<crate::data::store::Comment> {
        self.store
            .threads_for_file(file)
            .into_iter()
            .find(|r| r.side == "RIGHT" && !r.hidden && !r.outdated && r.line_start == line)
    }

    // --- navigation helpers ---------------------------------------------------
    fn move_list(state: &mut ListState, len: usize, delta: i32) {
        if len == 0 {
            return;
        }
        let cur = state.selected().unwrap_or(0) as i32;
        let next = (cur + delta).clamp(0, len as i32 - 1);
        state.select(Some(next as usize));
    }

    // --- claude ---------------------------------------------------------------
    pub fn poll_claude(&mut self) -> bool {
        // Take the receiver out so we can freely mutate self while draining it.
        let Some(rx) = self.claude_rx.take() else {
            return false;
        };
        let mut events = vec![];
        while let Ok(ev) = rx.try_recv() {
            events.push(ev);
        }
        let mut done = false;
        let changed = !events.is_empty();
        for ev in events {
            match ev {
                ClaudeEvent::Started => {
                    if let Some(s) = self.claude_session.as_mut() {
                        s.log.push("Claude process initialized".into());
                    }
                    self.status = "★ Claude initialized; analyzing the review…".into();
                }
                ClaudeEvent::Progress(t) => {
                    if let Some(s) = self.claude_session.as_mut() {
                        s.log.push(t.clone());
                    }
                    let summary = t.lines().next().unwrap_or("working");
                    self.status = format!(
                        "★ Claude: {}",
                        summary.chars().take(100).collect::<String>()
                    );
                }
                ClaudeEvent::Result(findings) => {
                    if let Some(session) = self.claude_session.take() {
                        let mut applied =
                            claude::apply(&mut self.store, &self.source, session, &findings);
                        self.finish_edit_session(&mut applied);
                        let verdict = applied
                            .verdict
                            .clone()
                            .unwrap_or_else(|| "commented".into());
                        let n_new = applied.new_comment_ids.len();
                        let n_replies = applied.replied.len();
                        // Jump the diff to a file Claude actually commented on, so the
                        // markers are immediately visible instead of hidden on another file.
                        if let Some(f) = self.first_file_with_comments() {
                            let cur_has = self
                                .current_file
                                .as_ref()
                                .map(|c| self.file_has_comments(c))
                                .unwrap_or(false);
                            if !cur_has {
                                self.current_file = Some(f);
                            }
                        }
                        self.claude_session = Some(applied);
                        self.status = format!(
                            "★ Claude review done: {verdict} · {n_new} new comment(s), {n_replies} repl(y/ies) — see markers & Claude tab"
                        );
                        self.main_tab = MainTab::Claude;
                        self.load_diff();
                    }
                    done = true;
                }
                ClaudeEvent::Error(e) => {
                    if let Some(s) = self.claude_session.as_mut() {
                        s.state = "error".into();
                        s.error = Some(e.clone());
                    }
                    self.status = format!("Claude error: {e}");
                    done = true;
                }
            }
        }
        if !done {
            // Not finished — keep polling next tick.
            self.claude_rx = Some(rx);
        }
        changed
    }

    fn start_refresh(&mut self) {
        if self.refresh_rx.is_some() {
            self.status = "refresh already in progress…".into();
            return;
        }
        let root = self.source.repo_root.clone();
        let head_ref = self.source.head_ref.clone();
        // Preserve the already-resolved comparison base. Re-running "auto" on a local
        // repository without a remote can incorrectly choose the current feature branch.
        let base = self.source.base_sha.clone();
        let pr = self.source.pr_coords().map(|(_, _, n)| n);
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let started = Instant::now();
            let refreshed = match pr {
                Some(number) => Source::pr(number, &root),
                None => Source::local(&root, Some(&base), Some(&head_ref)),
            };
            crate::perf::record("source.refresh", started.elapsed());
            let _ = tx.send(refreshed);
        });
        self.refresh_rx = Some(rx);
        self.status = "↻ refreshing PR, checks, threads, commits, and diffs…".into();
    }

    /// Poll asynchronous work. Returns true when visible state changed.
    pub fn poll_background(&mut self) -> bool {
        let mut changed = self.poll_claude();
        let implementation_action = self
            .implementation_action_rx
            .as_ref()
            .and_then(|rx| rx.try_recv().ok());
        if let Some(result) = implementation_action {
            self.implementation_action_rx = None;
            if let Some(implementation) = self.implementation_result.as_mut() {
                implementation.busy = None;
            }
            match result {
                Ok(()) => {
                    if let Some(implementation) = self.implementation_result.as_mut() {
                        implementation.pushed = true;
                    }
                    self.status = format!("implementation pushed to {}", self.source.head_ref);
                    if self.source.pr_coords().is_some() {
                        self.start_refresh();
                    }
                }
                Err(error) => self.status = format!("push failed: {error}"),
            }
            changed = true;
        }
        if let Some(rx) = &self.diff_prefetch_rx {
            while let Ok((generation, key, raw)) = rx.try_recv() {
                if generation == self.diff_generation {
                    self.raw_diff_cache.entry(key).or_insert(raw);
                }
            }
        }
        let refresh = self.refresh_rx.as_ref().and_then(|rx| rx.try_recv().ok());
        if let Some(result) = refresh {
            self.refresh_rx = None;
            let mut refreshed = false;
            match result {
                Ok(source) => {
                    let previous_file = self.current_file.clone();
                    self.source = source;
                    if self.source.caps.has_threads {
                        crate::data::github_sync::import(&mut self.store, &self.source);
                    }
                    self.raw_diff_cache.clear();
                    self.rebuild_file_rows();
                    self.current_file = previous_file
                        .filter(|path| self.source.files.iter().any(|f| &f.path == path))
                        .or_else(|| self.source.files.first().map(|f| f.path.clone()));
                    self.commit_view = None;
                    self.load_diff();
                    self.start_diff_prefetch();
                    self.status = "↻ refresh complete".into();
                    refreshed = true;
                }
                Err(error) => {
                    self.pending_claude_form = None;
                    self.pending_claude_prompt = None;
                    self.status = format!("refresh failed; Claude not started: {error}");
                }
            }
            if refreshed {
                if let Some(form) = self.pending_claude_form.take() {
                    let prompt = self.pending_claude_prompt.take();
                    self.start_claude_with_prompt(&form, prompt);
                }
            }
            changed = true;
        }
        self.flush_ui(false);
        changed
    }

    fn claude_context(&self, form: &ClaudeForm) -> (ClaudeOpts, Vec<crate::data::store::Comment>) {
        let base = form
            .profiles
            .get(form.selected)
            .and_then(|name| {
                self.cfg
                    .saved_instructions
                    .iter()
                    .find(|(k, _)| k == name)
                    .map(|(_, v)| v.clone())
            })
            .filter(|_| form.selected != 0)
            .unwrap_or_default();
        let instruction = format!("{}\n{}", base, form.direction).trim().to_string();
        let opts = ClaudeOpts {
            claude_bin: self.cfg.claude_bin.clone(),
            instruction,
            allow_edits: form.allow_edits || form.address_comments,
            auto_resolve: form.auto_resolve,
            address_comments: form.address_comments,
            test_commands: self.cfg.address_test_commands.clone(),
            protected_paths: self.cfg.protected_paths.clone(),
            commit_strategy: self.cfg.commit_strategy.clone(),
            push_changes: form.push_changes,
        };
        let threads: Vec<_> = self
            .store
            .all_threads()
            .into_iter()
            .filter(|t| t.status != "resolved")
            .filter(|t| form.address_ids.is_empty() || form.address_ids.contains(&t.id))
            .collect();
        (opts, threads)
    }

    fn claude_request(
        &self,
        form: &ClaudeForm,
    ) -> (ClaudeOpts, String, Vec<crate::data::store::Comment>) {
        let (opts, threads) = self.claude_context(form);
        let diff = git::full_diff(
            &self.source.base_sha,
            &self.source.head_sha,
            Some(&self.source.repo_root),
        );
        let prompt = claude::user_prompt(&self.source, &diff, &self.store, &threads, &opts);
        (opts, prompt, threads)
    }

    fn final_claude_prompt(&self, form: &ClaudeForm) -> String {
        let (opts, threads) = self.claude_context(form);
        claude::portable_prompt(&self.source, &self.store, &threads, &opts)
    }

    fn start_claude_with_prompt(&mut self, form: &ClaudeForm, revised_prompt: Option<String>) {
        let portable_prompt = revised_prompt.is_some();
        let (opts, prompt, threads) = if let Some(prompt) = revised_prompt {
            let (opts, threads) = self.claude_context(form);
            (opts, prompt, threads)
        } else {
            self.claude_request(form)
        };
        let session_id = crate::data::store::new_uuid();
        let roots_ids = threads.iter().map(|t| t.id.clone()).collect::<Vec<_>>();
        let cwd = if opts.allow_edits || portable_prompt {
            match crate::data::worktree::ensure_task(
                &self.source.repo_root,
                &self.source.head_sha,
                &session_id,
            ) {
                Ok(path) => path.to_string_lossy().to_string(),
                Err(e) => {
                    self.status = format!("worktree failed: {e}");
                    return;
                }
            }
        } else {
            self.source.repo_root.clone()
        };
        let mut session = Session {
            id: session_id.clone(),
            state: "running".into(),
            instruction: opts.instruction.clone(),
            allow_edits: opts.allow_edits,
            auto_resolve: opts.auto_resolve,
            started_at: crate::data::store::timestamp(),
            address_comments: opts.address_comments,
            worktree: (opts.allow_edits || portable_prompt).then(|| cwd.clone()),
            target_branch: (opts.allow_edits || portable_prompt)
                .then(|| self.source.head_ref.clone()),
            address_comment_ids: roots_ids,
            push_changes: opts.push_changes,
            reviewed_head: self.source.head_sha.clone(),
            ..Default::default()
        };
        session
            .log
            .push("Preparing prompt and review context".into());
        session.log.push("Starting Claude process".into());
        self.store
            .sessions
            .insert(session_id.clone(), session.clone());
        self.store.save();
        self.claude_session = Some(session);
        self.claude_rx = Some(claude::start(
            self.cfg.claude_bin.clone(),
            cwd,
            prompt,
            session_id,
            opts.allow_edits,
            opts.address_comments,
        ));
        self.status = "★ Claude review started (async)…".into();
        self.main_tab = MainTab::Claude;
    }

    fn queue_claude(&mut self, form: ClaudeForm) {
        self.queue_claude_prompt(form, None);
    }

    fn queue_claude_prompt(&mut self, form: ClaudeForm, prompt: Option<String>) {
        let needs_refresh = form.allow_edits || form.address_comments || prompt.is_some();
        if needs_refresh {
            self.pending_claude_prompt = prompt;
            self.pending_claude_form = Some(form);
            self.start_refresh();
            if self.refresh_rx.is_some() {
                self.status = "↻ updating the review branch before creating a worktree…".into();
            }
        } else {
            self.start_claude_with_prompt(&form, prompt);
        }
    }

    fn finish_edit_session(&mut self, session: &mut Session) {
        if !session.allow_edits {
            return;
        }
        let Some(cwd) = session.worktree.clone() else {
            return;
        };
        let original_head = if session.reviewed_head.is_empty() {
            self.source.head_sha.clone()
        } else {
            session.reviewed_head.clone()
        };
        let head = git::rev_parse("HEAD", Some(&cwd)).unwrap_or_else(|| original_head.clone());
        let short = head.chars().take(12).collect::<String>();
        let mut validation = Vec::new();
        let ancestry_ok = crate::data::proc::git(
            &["merge-base", "--is-ancestor", &original_head, &head],
            Some(&cwd),
        )
        .0;
        if !ancestry_ok {
            validation.push("FAIL commit is not based on reviewed head".into());
        }
        let changed = crate::data::proc::git(
            &["diff", "--name-only", &format!("{original_head}..{head}")],
            Some(&cwd),
        )
        .1;
        for protected in &self.cfg.protected_paths {
            if changed.lines().any(|p| p.starts_with(protected)) {
                validation.push(format!("FAIL protected path changed: {protected}"));
            }
        }
        for command in &self.cfg.address_test_commands {
            let (ok, _, err) = crate::data::proc::run(&["sh", "-c", command], Some(&cwd));
            validation.push(if ok {
                format!("PASS {command}")
            } else {
                format!("FAIL {command}: {}", err.lines().next().unwrap_or("failed"))
            });
        }
        let validation_ok = validation.iter().all(|v| !v.starts_with("FAIL"));
        let sandboxed = ["CODEX_SANDBOX", "CLAUDE_CODE_REMOTE", "PRTUI_SANDBOX"]
            .iter()
            .any(|k| std::env::var_os(k).is_some());
        let (outcome, push_state) = if head == original_head {
            (
                "Claude did not create an implementation commit; changes may still be uncommitted."
                    .to_string(),
                "no_commit",
            )
        } else if !validation_ok {
            (format!("Implemented in commit `{short}` at `{cwd}`, but not pushed because validation failed: {}", validation.join("; ")), "validation_failed")
        } else if !session.push_changes {
            (
                format!("Implemented in commit `{short}` at `{cwd}`. Push was not requested."),
                "committed",
            )
        } else if sandboxed {
            (format!("Implemented in commit `{short}` at `{cwd}`. Not pushed because this review is running in a sandbox."), "sandboxed")
        } else {
            let pushed = if self.source.pr_coords().is_some() {
                git::push_head_github(
                    &self.source.github_head_url,
                    &self.source.head_ref,
                    Some(&cwd),
                )
            } else {
                git::push_head_origin(&self.source.head_ref, Some(&cwd))
            };
            match pushed {
                Ok(()) => (
                    format!(
                        "Implemented in commit `{short}` and pushed to `{}`.",
                        self.source.head_ref
                    ),
                    "pushed",
                ),
                Err(e) => (
                    format!("Implemented in commit `{short}` at `{cwd}`. Not pushed: {e}"),
                    "push_failed",
                ),
            }
        };
        if session.address_comments {
            for id in session.address_comment_ids.clone() {
                if self.store.get(&id).is_some() {
                    self.store.reply(&id, &outcome, "claude");
                    self.store.set_thread_metadata(
                        &id,
                        (head != original_head).then_some(head.as_str()),
                        Some(&cwd),
                        push_state,
                        validation.clone(),
                    );
                }
            }
        }
        session.notes.push(outcome.clone());
        self.store
            .sessions
            .insert(session.id.clone(), session.clone());
        self.store.save();
        let mut summary = if session.address_comments {
            vec![
                format!("{} thread(s) processed", session.address_comment_ids.len()),
                outcome,
            ]
        } else {
            vec!["Edit-enabled review completed".into(), outcome]
        };
        summary.extend(validation);
        let pushed = push_state == "pushed";
        if head != original_head {
            self.show_implementation_head(&head);
        }
        self.implementation_result = Some(ImplementationResult {
            rows: summary,
            commit: head,
            worktree: cwd,
            original_head,
            pushed,
            showing_implementation: true,
            busy: None,
        });
        self.result_drawer_open = true;
        if pushed && self.source.pr_coords().is_some() {
            self.start_refresh();
        }
    }

    fn show_implementation_head(&mut self, head: &str) {
        self.source.head_sha = head.to_string();
        self.source.commits =
            git::commits(&self.source.base_sha, head, Some(&self.source.repo_root));
        self.source.files =
            git::changed_files(&self.source.base_sha, head, Some(&self.source.repo_root));
        self.raw_diff_cache.clear();
        self.rebuild_file_rows();
        self.current_file = self
            .current_file
            .clone()
            .filter(|path| self.source.files.iter().any(|file| &file.path == path))
            .or_else(|| self.source.files.first().map(|file| file.path.clone()));
        self.commit_view = None;
        self.load_diff();
        self.start_diff_prefetch();
    }

    fn implementation_result_action(&mut self, action: char) {
        if action == 'z' {
            self.result_drawer_open = false;
            self.status = "implementation actions closed; press z to reopen".into();
            return;
        }
        let Some(result) = self.implementation_result.as_ref() else {
            return;
        };
        let commit = result.commit.clone();
        let worktree = result.worktree.clone();
        let original_head = result.original_head.clone();
        let pushed = result.pushed;
        let busy = result.busy.is_some();
        let showing_implementation = result.showing_implementation;
        match action {
            'p' if busy => self.status = "push already in progress".into(),
            'p' if !pushed => {
                if git::rev_parse("HEAD", Some(&worktree)).as_deref() != Some(commit.as_str()) {
                    self.status =
                        "push blocked: worktree HEAD no longer matches the implementation commit"
                            .into();
                    return;
                }
                let branch = self.source.head_ref.clone();
                let repo_url = self.source.github_head_url.clone();
                let is_pr = self.source.pr_coords().is_some();
                let (tx, rx) = std::sync::mpsc::channel();
                std::thread::spawn(move || {
                    let result = if is_pr {
                        git::push_head_github(&repo_url, &branch, Some(&worktree))
                    } else {
                        git::push_head_origin(&branch, Some(&worktree))
                    };
                    let _ = tx.send(result);
                });
                self.implementation_action_rx = Some(rx);
                if let Some(result) = self.implementation_result.as_mut() {
                    result.busy = Some("pushing in background…".into());
                }
                self.status = "pushing implementation in background…".into();
            }
            'p' => self.status = "implementation is already pushed".into(),
            'b' => match self.update_local_branch(&commit, &original_head) {
                Ok(()) => self.status = format!("local branch {} updated", self.source.head_ref),
                Err(error) => self.status = format!("branch unchanged: {error}"),
            },
            'o' => {
                self.pending_editor = Some(worktree);
                self.status = "opening implementation worktree in $EDITOR…".into();
            }
            'i' => {
                let showing = !showing_implementation;
                self.show_implementation_head(if showing { &commit } else { &original_head });
                if let Some(result) = self.implementation_result.as_mut() {
                    result.showing_implementation = showing;
                }
                self.status = if showing {
                    "showing implementation diff".into()
                } else {
                    "showing original reviewed diff".into()
                };
            }
            _ => {}
        }
    }

    fn update_local_branch(&mut self, commit: &str, original_head: &str) -> Result<(), String> {
        let branch = self.source.head_ref.clone();
        if git::current_branch(Some(&self.source.repo_root)).as_deref() == Some(branch.as_str()) {
            let dirty =
                !crate::data::proc::git(&["status", "--porcelain"], Some(&self.source.repo_root))
                    .1
                    .trim()
                    .is_empty();
            if dirty {
                return Err("checked-out branch is dirty; leaving it unchanged".into());
            }
            let (ok, _, err) = crate::data::proc::git(
                &["merge", "--ff-only", commit],
                Some(&self.source.repo_root),
            );
            if !ok {
                return Err(err.lines().next().unwrap_or("fast-forward failed").into());
            }
        } else {
            let reference = format!("refs/heads/{branch}");
            let (ok, _, err) = crate::data::proc::git(
                &["update-ref", &reference, commit, original_head],
                Some(&self.source.repo_root),
            );
            if !ok {
                return Err(err.lines().next().unwrap_or("branch update failed").into());
            }
        }
        Ok(())
    }

    // --- input ---------------------------------------------------------------
    pub fn on_key(&mut self, key: KeyEvent) {
        if self.publish.is_some() {
            self.publish_key(key);
            return;
        }
        if self.searching {
            self.search_key(key);
            return;
        }
        if self.comment_searching {
            match key.code {
                KeyCode::Esc | KeyCode::Enter => self.comment_searching = false,
                KeyCode::Backspace => {
                    self.comment_query.pop();
                }
                KeyCode::Char(c) => self.comment_query.push(c),
                _ => {}
            }
            return;
        }
        if self.show_help {
            self.show_help = false;
            return;
        }
        if self.modal.is_some() {
            self.modal_key(key);
            return;
        }
        if key.code == KeyCode::Char('z') && self.implementation_result.is_some() {
            self.result_drawer_open = !self.result_drawer_open;
            self.status = if self.result_drawer_open {
                "implementation actions opened; diff remains navigable".into()
            } else {
                "implementation actions closed; press z to reopen".into()
            };
            return;
        }
        if self.result_drawer_open {
            let action = match key.code {
                KeyCode::Esc => Some('z'),
                KeyCode::Char('p') => Some('p'),
                KeyCode::Char('b') => Some('b'),
                KeyCode::Char('o') => Some('o'),
                KeyCode::Char('i') => Some('i'),
                _ => None,
            };
            if let Some(action) = action {
                self.implementation_result_action(action);
                return;
            }
        }
        // Ctrl-based half/full page scrolling (vim-style).
        if key.modifiers.contains(KeyModifiers::CONTROL) {
            let half = (self.main_h / 2).max(1) as i32;
            let full = self.main_h.saturating_sub(2).max(1) as i32;
            match key.code {
                KeyCode::Char('d') => {
                    self.scroll_page(half);
                    return;
                }
                KeyCode::Char('u') => {
                    self.scroll_page(-half);
                    return;
                }
                KeyCode::Char('f') => {
                    self.scroll_page(full);
                    return;
                }
                KeyCode::Char('b') => {
                    self.scroll_page(-full);
                    return;
                }
                _ => {}
            }
        }
        match key.code {
            KeyCode::Char('q') => self.should_quit = true,
            KeyCode::Char('S') => self.open_publish(),
            KeyCode::Char('X') => self.open_actions(),
            KeyCode::Char('P') => self.request_picker = true,
            KeyCode::Char('t') => {
                let name = crate::theme::cycle();
                self.status = format!("theme: {name}");
            }
            KeyCode::Char('?') => self.show_help = true,
            KeyCode::Esc => self.visual_anchor = None,
            KeyCode::Char('v') | KeyCode::Char('V') => self.toggle_visual(),
            KeyCode::Tab => self.cycle_panel(1),
            KeyCode::BackTab => self.cycle_panel(-1),
            KeyCode::Char('1') => self.panel = Panel::Files,
            KeyCode::Char('2') => self.panel = Panel::Commits,
            KeyCode::Char('3') => {
                self.panel = Panel::Main;
                self.main_tab = MainTab::Diff;
            }
            KeyCode::Char('4') => {
                self.panel = Panel::Main;
                self.main_tab = MainTab::Comments;
            }
            KeyCode::Char('5') => {
                self.panel = Panel::Main;
                self.main_tab = MainTab::Timeline;
            }
            KeyCode::Char('6') => {
                self.panel = Panel::Main;
                self.main_tab = MainTab::Claude;
            }
            KeyCode::Char(':') => {
                self.modal = Some(Modal::Palette {
                    query: String::new(),
                    selected: 0,
                })
            }
            KeyCode::Char('F') => self.cycle_filter(),
            KeyCode::Char('D') => {
                self.thread_drawer = !self.thread_drawer;
            }
            KeyCode::Char('[') => self.cycle_main_tab(-1),
            KeyCode::Char(']') => self.cycle_main_tab(1),
            KeyCode::Char('n') => self.jump_comment(1),
            KeyCode::Char('N') => self.jump_comment(-1),
            KeyCode::Char('\\') => {
                self.diff_split = !self.diff_split;
                self.status = if self.diff_split {
                    "split (side-by-side) diff".into()
                } else {
                    "unified diff".into()
                };
            }
            KeyCode::Char('/') if self.main_tab == MainTab::Comments => {
                self.comment_searching = true;
                self.comment_query.clear();
            }
            KeyCode::Char('/') => {
                self.searching = true;
                self.search.clear();
            }
            KeyCode::Char('o') => self.open_in_editor(),
            KeyCode::Char('O') => self.open_view_in_editor(),
            KeyCode::Char('m') if self.main_tab == MainTab::Comments => self.toggle_mark_thread(),
            KeyCode::Char('M') if self.main_tab == MainTab::Comments => self.mark_visible_threads(),
            KeyCode::Char('u') if self.main_tab == MainTab::Comments => {
                self.marked_threads.clear();
                self.status = "thread selection cleared".into();
            }
            KeyCode::Char('m') => self.toggle_viewed(),
            KeyCode::Char('A') if self.main_tab == MainTab::Comments => {
                self.preview_address_threads()
            }
            KeyCode::Char('A') => self.apply_suggestion(),
            KeyCode::Char('C') if self.main_tab == MainTab::Comments => {
                self.set_thread_workflow("needs_clarification")
            }
            KeyCode::Char('Z') if self.main_tab == MainTab::Comments => {
                self.set_thread_workflow("deferred")
            }
            KeyCode::Char('T') if self.main_tab == MainTab::Comments => {
                self.set_thread_workflow("task")
            }
            KeyCode::Char('L') if self.main_tab == MainTab::Comments => self.cycle_thread_label(),
            KeyCode::Char('R') if self.main_tab == MainTab::Comments => {
                self.preview_address_threads()
            }
            KeyCode::Char('R') => {
                if self.refresh_rx.take().is_some() {
                    self.pending_claude_form = None;
                    self.pending_claude_prompt = None;
                    self.status = "refresh cancelled".into();
                } else {
                    self.start_refresh();
                }
            }
            KeyCode::Char('!') if self.main_tab == MainTab::Comments => {
                self.cycle_thread_priority()
            }
            KeyCode::Char('W') if self.main_tab == MainTab::Comments => self.cycle_thread_owner(),
            KeyCode::Char('U') if self.main_tab == MainTab::Comments => self.jump_workflow(false),
            KeyCode::Char('I') if self.main_tab == MainTab::Comments => self.jump_workflow(true),
            KeyCode::Backspace if !self.location_history.is_empty() => {
                if let Some((file, line)) = self.location_history.pop() {
                    self.current_file = Some(file.clone());
                    self.load_diff();
                    if let Some(row) = self.diff.iter().position(|d| d.new_ln == Some(line)) {
                        self.diff_state.select(Some(row));
                    }
                    self.panel = Panel::Main;
                    self.main_tab = MainTab::Diff;
                    self.status = format!("back to {file}:{line}");
                }
            }
            KeyCode::Char('+') | KeyCode::Char('=') => {
                self.diff_context = (self.diff_context + 10).min(9999);
                self.load_diff();
                self.status = format!("context: {} lines (+/- to change)", self.diff_context);
            }
            KeyCode::Char('-') => {
                self.diff_context = self.diff_context.saturating_sub(10).max(3);
                self.load_diff();
                self.status = format!("context: {} lines", self.diff_context);
            }
            KeyCode::Char('a') => self.open_claude_form(),
            KeyCode::Char('c') => self.compose_comment(false),
            KeyCode::Char('s') => self.compose_comment(true),
            KeyCode::Char('r') => self.compose_reply(),
            KeyCode::Char('x') => self.toggle_resolve(),
            KeyCode::Char('d') => self.delete_thread(),
            KeyCode::Char('e') => self.compose_edit(),
            KeyCode::Char('y') => self.copy_thread(),
            KeyCode::Char('H') => self.toggle_hide(),
            KeyCode::Char('E') => self.open_reactions(),
            KeyCode::Char(' ') => {
                self.toggle_thread_inline();
            }
            KeyCode::Char('j') | KeyCode::Down => self.nav(1),
            KeyCode::Char('k') | KeyCode::Up => self.nav(-1),
            KeyCode::Char('g') => self.nav_top(),
            KeyCode::Char('G') => self.nav_bottom(),
            KeyCode::Char('h') | KeyCode::Left if self.main_tab == MainTab::Claude => {
                self.claude_session_index = self.claude_session_index.saturating_sub(1);
            }
            KeyCode::Char('l') | KeyCode::Right if self.main_tab == MainTab::Claude => {
                self.claude_session_index = self.claude_session_index.saturating_add(1);
            }
            KeyCode::Char('h') | KeyCode::Left => self.panel = Panel::Files,
            KeyCode::Char('l') | KeyCode::Right | KeyCode::Enter => self.activate(),
            _ => {}
        }
        self.persist_ui();
    }

    fn cycle_panel(&mut self, d: i32) {
        let order = [Panel::Files, Panel::Commits, Panel::Main];
        let i = order.iter().position(|p| *p == self.panel).unwrap_or(0) as i32;
        self.panel = order[((i + d).rem_euclid(3)) as usize];
    }

    fn cycle_main_tab(&mut self, d: i32) {
        let order = [
            MainTab::Diff,
            MainTab::Conversation,
            MainTab::Timeline,
            MainTab::Claude,
            MainTab::Comments,
        ];
        let i = order.iter().position(|t| *t == self.main_tab).unwrap_or(0) as i32;
        self.main_tab = order[((i + d).rem_euclid(order.len() as i32)) as usize];
        self.panel = Panel::Main;
    }

    fn nav(&mut self, d: i32) {
        match self.panel {
            Panel::Files => {
                let len = self.file_rows.len();
                Self::move_list(&mut self.files_state, len, d);
            }
            Panel::Commits => {
                let len = self.source.commits.len();
                Self::move_list(&mut self.commits_state, len, d);
            }
            Panel::Main => match self.main_tab {
                MainTab::Diff => Self::move_list(&mut self.diff_state, self.diff.len(), d),
                MainTab::Conversation => {
                    self.conv_scroll = (self.conv_scroll as i32 + d).max(0) as u16
                }
                MainTab::Timeline => {
                    self.timeline_scroll = (self.timeline_scroll as i32 + d).max(0) as u16
                }
                MainTab::Claude => {
                    self.claude_scroll = (self.claude_scroll as i32 + d).max(0) as u16
                }
                MainTab::Comments => {
                    Self::move_list(&mut self.comments_state, self.comment_targets.len(), d)
                }
            },
        }
    }

    fn nav_top(&mut self) {
        match self.panel {
            Panel::Files => self.files_state.select(Some(0)),
            Panel::Commits => self.commits_state.select(Some(0)),
            Panel::Main => match self.main_tab {
                MainTab::Diff => self.diff_state.select(Some(0)),
                MainTab::Conversation => self.conv_scroll = 0,
                MainTab::Timeline => self.timeline_scroll = 0,
                MainTab::Claude => self.claude_scroll = 0,
                MainTab::Comments => self.comments_state.select(Some(0)),
            },
        }
    }

    fn nav_bottom(&mut self) {
        match self.panel {
            Panel::Files => {
                Self::move_list(&mut self.files_state, self.file_rows.len(), i32::MAX / 2)
            }
            Panel::Commits => Self::move_list(
                &mut self.commits_state,
                self.source.commits.len(),
                i32::MAX / 2,
            ),
            Panel::Main => match self.main_tab {
                MainTab::Diff => {
                    Self::move_list(&mut self.diff_state, self.diff.len(), i32::MAX / 2)
                }
                MainTab::Comments => {
                    // Land on the last *actionable* row, not a trailing blank/header.
                    let last = self
                        .comment_targets
                        .iter()
                        .rposition(|t| t.is_some())
                        .unwrap_or(self.comment_targets.len().saturating_sub(1));
                    self.comments_state.select(Some(last));
                }
                _ => {}
            },
        }
    }

    fn activate(&mut self) {
        match self.panel {
            Panel::Files => {
                // A directory row toggles collapse; a file row opens its diff.
                let row = self
                    .files_state
                    .selected()
                    .and_then(|i| self.file_rows.get(i))
                    .cloned();
                match row {
                    Some(crate::tree::FileRow::Dir { path, .. }) => {
                        if !self.collapsed_dirs.remove(&path) {
                            self.collapsed_dirs.insert(path);
                        }
                        self.rebuild_file_rows();
                    }
                    Some(crate::tree::FileRow::File { .. }) => {
                        if let Some(f) = self.selected_file() {
                            self.current_file = Some(f);
                            self.commit_view = None; // leaving commit view back to the PR diff
                            self.load_diff();
                            self.main_tab = MainTab::Diff;
                            self.panel = Panel::Main;
                        }
                    }
                    None => {}
                }
            }
            Panel::Commits => {
                if let Some(sha) = self
                    .commits_state
                    .selected()
                    .and_then(|i| self.source.commits.get(i))
                    .map(|c| c.sha.clone())
                {
                    self.load_commit_diff(&sha);
                }
            }
            Panel::Main => match self.main_tab {
                // Enter on a commented diff line expands/collapses its thread inline.
                MainTab::Diff => {
                    self.toggle_thread_inline();
                }
                // Enter on a Comments-view row jumps to that thread's diff position.
                MainTab::Comments => self.jump_selected_comment(),
                _ => {}
            },
        }
    }

    /// Jump the diff to the comment selected in the Comments view.
    fn jump_selected_comment(&mut self) {
        let Some(sel) = self.comments_state.selected() else {
            return;
        };
        if let Some(Some((file, line, root))) = self.comment_targets.get(sel).cloned() {
            self.jump_to_comment(&file, line, &root);
        }
    }

    /// Move the diff cursor to the next/previous commented line across all files.
    fn jump_comment(&mut self, dir: i32) {
        // Ordered list of (file, line, root_id) for all RIGHT-side threads.
        let mut all: Vec<(String, u32, String)> = self
            .store
            .all_threads()
            .into_iter()
            .filter(|t| t.side == "RIGHT" && !t.outdated && !t.hidden)
            .map(|t| (t.file.clone(), t.line_start, t.id.clone()))
            .collect();
        all.sort_by(|a, b| a.0.cmp(&b.0).then(a.1.cmp(&b.1)));
        if all.is_empty() {
            self.status = "no comments to jump to".into();
            return;
        }
        // Current position = (current_file, cursor line).
        let cur_file = self.current_file.clone().unwrap_or_default();
        let cur_line = self
            .diff_state
            .selected()
            .and_then(|i| self.diff.get(i))
            .and_then(|d| d.new_ln)
            .unwrap_or(0);
        let cur_key = (cur_file, cur_line);
        let idx = if dir > 0 {
            all.iter()
                .position(|(f, l, _)| (f.clone(), *l) > cur_key)
                .unwrap_or(0)
        } else {
            all.iter()
                .rposition(|(f, l, _)| (f.clone(), *l) < cur_key)
                .unwrap_or(all.len() - 1)
        };
        let (file, line, root) = all[idx].clone();
        self.jump_to_comment(&file, line, &root);
    }

    fn jump_to_comment(&mut self, file: &str, line: u32, root: &str) {
        if let Some(cur) = self.current_file.clone() {
            let ln = self
                .diff_state
                .selected()
                .and_then(|i| self.diff.get(i))
                .and_then(|d| d.new_ln)
                .unwrap_or(1);
            if cur != file || ln != line {
                self.location_history.push((cur, ln));
            }
        }
        self.current_file = Some(file.to_string());
        if !root.is_empty() {
            self.expanded.insert(root.to_string());
        }
        self.load_diff();
        if let Some(r) = self.diff.iter().position(|d| d.new_ln == Some(line)) {
            self.diff_state.select(Some(r));
        }
        self.panel = Panel::Main;
        self.main_tab = MainTab::Diff;
        self.status = format!("comment at {file}:{line}");
    }

    /// Ensure the diff has focus so j/k move the diff cursor (not the file list).
    fn focus_diff(&mut self) {
        self.panel = Panel::Main;
        self.main_tab = MainTab::Diff;
    }

    fn toggle_visual(&mut self) {
        // Visual-line selection acts on the diff — focus it first so it always works,
        // even if the user was on the Files/Commits panel.
        self.focus_diff();
        if self.visual_anchor.is_some() {
            self.visual_anchor = None;
            self.status = "visual off".into();
        } else {
            self.visual_anchor = self.diff_state.selected();
            self.status = "-- VISUAL --  j/k extend · c comment · esc cancel".into();
        }
    }

    /// Inclusive [lo, hi] diff-row range of the current visual selection (or the cursor
    /// row when not selecting).
    pub fn visual_rows(&self) -> Option<(usize, usize)> {
        let cur = self.diff_state.selected()?;
        match self.visual_anchor {
            Some(a) => Some((a.min(cur), a.max(cur))),
            None => Some((cur, cur)),
        }
    }

    /// The (file, start_line, end_line) to comment on, from the visual range or cursor.
    fn range_target(&self) -> Option<(String, u32, u32)> {
        let file = self.current_file.clone()?;
        let (lo, hi) = self.visual_rows()?;
        let mut lines: Vec<u32> = (lo..=hi)
            .filter_map(|i| self.diff.get(i).and_then(|d| d.new_ln))
            .collect();
        lines.sort_unstable();
        let (start, end) = (*lines.first()?, *lines.last()?);
        Some((file, start, end))
    }

    fn scroll_page(&mut self, delta: i32) {
        match self.panel {
            Panel::Files => Self::move_list(&mut self.files_state, self.file_rows.len(), delta),
            Panel::Commits => {
                Self::move_list(&mut self.commits_state, self.source.commits.len(), delta)
            }
            Panel::Main => match self.main_tab {
                MainTab::Diff => Self::move_list(&mut self.diff_state, self.diff.len(), delta),
                MainTab::Conversation => {
                    self.conv_scroll = (self.conv_scroll as i32 + delta).max(0) as u16
                }
                MainTab::Timeline => {
                    self.timeline_scroll = (self.timeline_scroll as i32 + delta).max(0) as u16
                }
                MainTab::Claude => {
                    self.claude_scroll = (self.claude_scroll as i32 + delta).max(0) as u16
                }
                MainTab::Comments => {
                    Self::move_list(&mut self.comments_state, self.comment_targets.len(), delta)
                }
            },
        }
    }

    fn compose_comment(&mut self, suggestion: bool) {
        let Some((file, start, end)) = self.range_target() else {
            self.status =
                "Put the cursor on an added/context diff line (in Diff, focus Main).".into();
            return;
        };
        let loc = if start == end {
            format!("{start}")
        } else {
            format!("{start}-{end}")
        };
        self.modal = Some(Modal::Compose(Compose {
            title: format!(
                "{} — {}:{}",
                if suggestion { "Suggestion" } else { "Comment" },
                file,
                loc
            ),
            buffer: if suggestion {
                "```suggestion\n\n```".into()
            } else {
                String::new()
            },
            is_suggestion: suggestion,
            file,
            line: start,
            line_end: end,
            reply_to: None,
            edit_of: None,
        }));
        self.visual_anchor = None; // selection consumed
    }

    /// The id of the specific comment under the cursor — a reply id when on a reply row,
    /// else the root id (from an anchor line or a thread-root row, or the Comments view).
    fn current_comment_id(&self) -> Option<String> {
        if self.panel == Panel::Main && self.main_tab == MainTab::Comments {
            let sel = self.comments_state.selected()?;
            let (_, _, root) = self.comment_targets.get(sel)?.clone()?;
            return Some(root);
        }
        // Prefer the id tagged on the diff row (anchor line or inline thread row).
        if let Some(id) = self
            .diff_state
            .selected()
            .and_then(|i| self.diff.get(i))
            .and_then(|d| d.comment_id.clone())
        {
            return Some(id);
        }
        // Fallback: a thread anchored on the cursor's line.
        let (file, line) = self.diff_target()?;
        self.thread_at(&file, line).map(|r| r.id)
    }

    /// The exact comment under the cursor (root or reply).
    fn current_comment(&self) -> Option<crate::data::store::Comment> {
        let id = self.current_comment_id()?;
        self.store.get(&id).cloned()
    }

    /// The thread root the user is acting on (root of whatever comment is under the cursor).
    fn current_root(&self) -> Option<crate::data::store::Comment> {
        let id = self.current_comment_id()?;
        let root = self.store.root_of(&id);
        self.store.get(&root).cloned()
    }

    fn compose_reply(&mut self) {
        let Some(root) = self.current_root() else {
            self.status = "No thread selected.".into();
            return;
        };
        self.modal = Some(Modal::Compose(Compose {
            title: format!("Reply — {}:{}", root.file, root.line_start),
            buffer: String::new(),
            is_suggestion: false,
            file: root.file.clone(),
            line: root.line_start,
            line_end: root.line_end,
            reply_to: Some(root.id),
            edit_of: None,
        }));
    }

    fn compose_edit(&mut self) {
        let Some(c) = self.current_comment() else {
            self.status = "No comment selected.".into();
            return;
        };
        let what = if c.in_reply_to.is_some() {
            "Edit reply"
        } else {
            "Edit"
        };
        self.modal = Some(Modal::Compose(Compose {
            title: format!("{what} — {}:{}", c.file, c.line_start),
            buffer: c.body.clone(),
            is_suggestion: c.kind == "suggestion",
            file: c.file.clone(),
            line: c.line_start,
            line_end: c.line_end,
            reply_to: None,
            edit_of: Some(c.id),
        }));
    }

    fn delete_thread(&mut self) {
        let Some(c) = self.current_comment() else {
            self.status = "No comment selected.".into();
            return;
        };
        let prompt = if c.in_reply_to.is_some() {
            "Delete this reply?  (y/n)".to_string()
        } else {
            format!("Delete this thread at {}:{}?  (y/n)", c.file, c.line_start)
        };
        self.modal = Some(Modal::Confirm {
            prompt,
            action: ConfirmAction::DeleteThread(c.id),
        });
    }

    fn copy_thread(&mut self) {
        let Some(root) = self.current_root() else {
            self.status = "No thread selected.".into();
            return;
        };
        let mut md = format!(
            "{}:{} — {}\n{}\n",
            root.file, root.line_start, root.author, root.body
        );
        for r in self.store.replies(&root.id) {
            md.push_str(&format!("↳ {}: {}\n", r.author, r.body));
        }
        crate::osc52_copy(&md);
        self.status = format!("copied thread ({} chars) to clipboard", md.len());
    }

    fn toggle_hide(&mut self) {
        let Some(root) = self.current_root() else {
            self.status = "No thread selected.".into();
            return;
        };
        let hide = !root.hidden;
        self.store.set_hidden(&root.id, hide);
        self.load_diff();
        self.status = if hide {
            "thread hidden (H to unhide, in Comments view)"
        } else {
            "thread shown"
        }
        .into();
    }

    fn toggle_resolve(&mut self) {
        let Some(root) = self.current_root() else {
            self.status = "No thread selected.".into();
            return;
        };
        let resolve = root.status != "resolved";
        // A GitHub-imported thread resolves on GitHub too.
        if let Some(tid) = &root.gh_thread_id {
            match crate::data::gh::set_thread_resolved(tid, resolve, Some(&self.source.repo_root)) {
                Ok(_) => {}
                Err(e) => {
                    self.status =
                        format!("GitHub resolve failed: {}", e.lines().next().unwrap_or(""));
                    return;
                }
            }
        }
        self.store.set_resolved(&root.id, resolve);
        self.load_diff();
        self.status = if resolve { "resolved" } else { "unresolved" }.into();
    }

    /// Open the reaction picker for the exact comment under the cursor (root or reply).
    fn open_reactions(&mut self) {
        let Some(id) = self.current_comment_id() else {
            self.status = "No comment selected.".into();
            return;
        };
        self.modal = Some(Modal::React { comment_id: id });
    }

    /// Toggle a reaction (by index into store::REACTIONS) on a comment, syncing to GitHub
    /// when the comment has a GitHub id.
    fn react(&mut self, comment_id: &str, idx: usize) {
        let Some(&name) = crate::data::store::REACTIONS.get(idx) else {
            return;
        };
        let author = std::env::var("USER").unwrap_or_else(|_| "you".into());
        let github_id = self
            .store
            .comments
            .get(comment_id)
            .and_then(|c| c.github_id.clone());
        let added = self.store.toggle_reaction(comment_id, name, &author);
        // GitHub sync for imported review comments (add only; GitHub has no single-call
        // toggle, so removals stay local). Surface a failure instead of silently diverging.
        let mut warn = None;
        if added {
            if let (Some(gid), Some((owner, repo, _))) = (&github_id, self.source.pr_coords()) {
                if let Err(e) = crate::data::gh::react_to_comment(
                    &owner,
                    &repo,
                    gid,
                    name,
                    Some(&self.source.repo_root),
                ) {
                    warn = Some(e.lines().next().unwrap_or("").to_string());
                }
            }
        }
        self.load_diff();
        self.status = match warn {
            Some(e) => format!("reacted {name} (local only — GitHub sync failed: {e})"),
            None => format!(
                "{} {name}",
                if added { "reacted" } else { "removed reaction" }
            ),
        };
    }

    fn open_actions(&mut self) {
        let Some((_, _, n)) = self.source.pr_coords() else {
            self.status = "PR actions need a GitHub PR.".into();
            return;
        };
        let n = n.to_string();
        let cmd = |a: &[&str]| ConfirmAction::PrCommand(a.iter().map(|s| s.to_string()).collect());
        self.modal = Some(Modal::Actions(vec![
            (
                'm',
                "Merge (squash)".into(),
                cmd(&["merge", &n, "--squash"]),
            ),
            ('c', "Close PR".into(), cmd(&["close", &n])),
            ('o', "Reopen PR".into(), cmd(&["reopen", &n])),
            ('r', "Mark ready for review".into(), cmd(&["ready", &n])),
            (
                'd',
                "Convert to draft".into(),
                cmd(&["ready", &n, "--undo"]),
            ),
        ]));
    }

    fn run_pr_command(&mut self, args: &[String]) {
        let argv: Vec<&str> = args.iter().map(String::as_str).collect();
        match crate::data::gh::pr_command(&argv, Some(&self.source.repo_root)) {
            Ok(_) => self.status = format!("✓ gh pr {}", args.join(" ")),
            Err(e) => {
                self.status = format!(
                    "gh pr {} failed: {}",
                    args.join(" "),
                    e.lines().next().unwrap_or("")
                )
            }
        }
    }

    fn open_publish(&mut self) {
        if self.source.kind != "pr" {
            self.status =
                "Publishing needs a GitHub PR (local branches can't be published).".into();
            return;
        }
        let summary = self
            .claude_session
            .as_ref()
            .map(|s| s.summary.clone())
            .unwrap_or_default();
        let view = crate::publish::PublishView::new(&self.store, &summary);
        if view.items.is_empty() {
            self.status = "No draft comments to publish.".into();
            return;
        }
        self.publish = Some(view);
    }

    fn publish_key(&mut self, key: KeyEvent) {
        let Some(view) = self.publish.as_mut() else {
            return;
        };
        let action = view.on_key(key);
        match action {
            crate::publish::PublishAction::None => {}
            crate::publish::PublishAction::Cancel => {
                self.publish = None;
                self.status = "publish cancelled (drafts kept)".into();
            }
            crate::publish::PublishAction::Submit => self.do_publish(),
        }
    }

    fn do_publish(&mut self) {
        let Some((owner, repo, number)) = self.source.pr_coords() else {
            self.status = "cannot resolve PR coordinates".into();
            self.publish = None;
            return;
        };
        let Some(view) = self.publish.as_ref() else {
            self.status = "publish view is no longer open".into();
            return;
        };
        let included = view.included();
        let payload = crate::publish::build_payload(
            &self.source.head_sha,
            view.verdict,
            &view.body,
            &included,
        );
        let root_ids: Vec<String> = included.iter().map(|i| i.root_id.clone()).collect();
        let payload_str = serde_json::to_string(&payload).unwrap_or_default();

        match crate::data::gh::submit_review(
            &owner,
            &repo,
            number,
            &payload_str,
            Some(&self.source.repo_root),
        ) {
            Ok(response) => {
                for (index, id) in root_ids.iter().enumerate() {
                    self.store.mark_published(id);
                    if let Some(node_id) = response
                        .get("comments")
                        .and_then(|v| v.as_array())
                        .and_then(|comments| comments.get(index))
                        .and_then(|comment| {
                            comment
                                .get("node_id")
                                .and_then(|v| v.as_str())
                                .map(str::to_owned)
                                .or_else(|| comment.get("id").map(ToString::to_string))
                        })
                    {
                        let root = self.store.root_of(id);
                        if let Some(comment) = self.store.comments.get_mut(&root) {
                            comment.github_id = Some(node_id.trim_matches('"').to_owned());
                            comment.origin = "github".into();
                        }
                    }
                }
                self.store.save();
                let verdict = view.verdict.event();
                self.publish = None;
                self.load_diff();
                self.status = format!(
                    "★ review submitted to #{number}: {verdict} ({} comment(s))",
                    root_ids.len()
                );
            }
            Err(e) => {
                if let Some(v) = self.publish.as_mut() {
                    v.error = Some(e.lines().next().unwrap_or("submit failed").to_string());
                }
            }
        }
    }

    fn open_claude_form(&mut self) {
        let mut profiles = vec!["(none)".to_string()];
        profiles.extend(self.cfg.saved_instructions.iter().map(|(k, _)| k.clone()));
        self.modal = Some(Modal::Claude(ClaudeForm {
            profiles,
            selected: 0,
            direction: String::new(),
            allow_edits: false,
            auto_resolve: false,
            address_comments: false,
            address_ids: vec![],
            push_changes: false,
        }));
    }

    fn modal_key(&mut self, key: KeyEvent) {
        let mut submit_compose: Option<Compose> = None;
        let mut submit_claude: Option<ClaudeForm> = None;
        let mut edit_compose: Option<String> = None;
        let mut copy_prompt: Option<ClaudeForm> = None;
        let mut edit_prompt: Option<String> = None;
        let mut edit_prompt_form: Option<ClaudeForm> = None;
        let mut run_prompt: Option<(ClaudeForm, String)> = None;
        let Some(modal) = self.modal.as_mut() else {
            return;
        };
        match modal {
            Modal::Compose(c) => match key.code {
                KeyCode::Esc => {
                    self.modal = None;
                    return;
                }
                KeyCode::Char('s') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                    submit_compose = Some(std::mem::replace(
                        c,
                        Compose {
                            title: String::new(),
                            buffer: String::new(),
                            is_suggestion: false,
                            file: String::new(),
                            line: 0,
                            line_end: 0,
                            reply_to: None,
                            edit_of: None,
                        },
                    ));
                }
                KeyCode::Char('o') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                    edit_compose = Some(c.buffer.clone());
                }
                KeyCode::Enter => c.buffer.push('\n'),
                KeyCode::Backspace => {
                    c.buffer.pop();
                }
                KeyCode::Char(ch) => c.buffer.push(ch),
                _ => {}
            },
            Modal::Confirm { action, .. } => {
                match key.code {
                    KeyCode::Char('y') | KeyCode::Char('Y') | KeyCode::Enter => {
                        let act = action.clone();
                        self.modal = None;
                        match act {
                            ConfirmAction::DeleteThread(id) => {
                                self.store.delete(&id);
                                self.load_diff();
                                self.status = "thread deleted".into();
                            }
                            ConfirmAction::PrCommand(args) => self.run_pr_command(&args),
                        }
                    }
                    _ => {
                        self.modal = None;
                    }
                }
                return;
            }
            Modal::Actions(items) => {
                match key.code {
                    KeyCode::Esc => {
                        self.modal = None;
                        return;
                    }
                    KeyCode::Char(ch) => {
                        if let Some((_, label, action)) = items.iter().find(|(c, _, _)| *c == ch) {
                            let prompt = format!("{label}? (y/n)");
                            let action = action.clone();
                            self.modal = Some(Modal::Confirm { prompt, action });
                        }
                    }
                    _ => {}
                }
                return;
            }
            Modal::React { comment_id } => {
                let cid = comment_id.clone();
                match key.code {
                    KeyCode::Esc => {
                        self.modal = None;
                    }
                    KeyCode::Char(ch @ '1'..='8') => {
                        let idx = ch as usize - '1' as usize;
                        self.modal = None;
                        self.react(&cid, idx);
                    }
                    _ => {
                        self.modal = None;
                    }
                }
                return;
            }
            Modal::Palette { query, selected } => {
                const N: usize = 10;
                match key.code {
                    KeyCode::Esc => self.modal = None,
                    KeyCode::Up | KeyCode::Char('k') => *selected = selected.saturating_sub(1),
                    KeyCode::Down | KeyCode::Char('j') => *selected = (*selected + 1).min(N - 1),
                    KeyCode::Backspace => {
                        query.pop();
                    }
                    KeyCode::Enter => {
                        let i = *selected;
                        self.modal = None;
                        self.palette_action(i);
                    }
                    KeyCode::Char(c) => query.push(c),
                    _ => {}
                }
                return;
            }
            Modal::AddressPreview { ids, .. } => match key.code {
                KeyCode::Char('y') | KeyCode::Char('Y') | KeyCode::Enter => {
                    if ids.is_empty() {
                        self.status = "No actionable threads in this selection.".into();
                        self.modal = None;
                        return;
                    }
                    submit_claude = Some(ClaudeForm {
                        profiles: vec!["(none)".into()],
                        selected: 0,
                        direction: "Address only the selected review threads.".into(),
                        allow_edits: true,
                        auto_resolve: false,
                        address_comments: true,
                        address_ids: ids.clone(),
                        push_changes: false,
                    });
                    self.modal = None;
                }
                _ => {
                    self.modal = None;
                    return;
                }
            },
            Modal::Summary(_) => {
                self.modal = None;
                return;
            }
            Modal::PromptPreview { prompt, form } => match key.code {
                KeyCode::Esc => {
                    self.modal = None;
                    return;
                }
                KeyCode::Char('y') | KeyCode::Char('c') => {
                    crate::osc52_copy(prompt);
                    self.status = "final Claude prompt copied".into();
                    return;
                }
                KeyCode::Char('o') | KeyCode::Char('e')
                    if key.modifiers.is_empty()
                        || key.modifiers.contains(KeyModifiers::CONTROL) =>
                {
                    edit_prompt = Some(prompt.clone());
                    edit_prompt_form = Some(form.clone());
                }
                KeyCode::Char('s') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                    run_prompt = Some((form.clone(), prompt.clone()));
                }
                _ => return,
            },
            Modal::Claude(f) => match key.code {
                KeyCode::Esc => {
                    self.modal = None;
                    return;
                }
                KeyCode::Up | KeyCode::Char('\u{10}') => {
                    if f.selected > 0 {
                        f.selected -= 1;
                    }
                }
                KeyCode::Down => {
                    if f.selected + 1 < f.profiles.len() {
                        f.selected += 1;
                    }
                }
                KeyCode::Char('e') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                    f.allow_edits = !f.allow_edits
                }
                KeyCode::Char('r') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                    f.auto_resolve = !f.auto_resolve
                }
                KeyCode::Char('w') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                    f.address_comments = !f.address_comments;
                    if f.address_comments {
                        f.allow_edits = true;
                    }
                }
                KeyCode::Char('p') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                    f.push_changes = !f.push_changes;
                    if f.push_changes {
                        f.allow_edits = true;
                    }
                }
                KeyCode::Char('y') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                    copy_prompt = Some(f.clone());
                }
                KeyCode::Char('o') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                    edit_prompt_form = Some(f.clone());
                }
                KeyCode::Char('s') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                    submit_claude = Some(std::mem::replace(
                        f,
                        ClaudeForm {
                            profiles: vec![],
                            selected: 0,
                            direction: String::new(),
                            allow_edits: f.allow_edits,
                            auto_resolve: f.auto_resolve,
                            address_comments: f.address_comments,
                            address_ids: f.address_ids.clone(),
                            push_changes: f.push_changes,
                        },
                    ));
                }
                KeyCode::Enter => f.direction.push('\n'),
                KeyCode::Backspace => {
                    f.direction.pop();
                }
                KeyCode::Char(ch) => f.direction.push(ch),
                _ => {}
            },
        }
        if let Some(buffer) = edit_compose {
            self.open_compose_in_editor(&buffer);
        }
        if let Some(form) = copy_prompt {
            crate::osc52_copy(&self.final_claude_prompt(&form));
            self.status = "final Claude prompt copied".into();
        }
        if let Some(form) = edit_prompt_form {
            let prompt = edit_prompt.unwrap_or_else(|| self.final_claude_prompt(&form));
            self.open_prompt_in_editor(&prompt, form);
        }
        if let Some((form, prompt)) = run_prompt {
            self.modal = None;
            self.queue_claude_prompt(form, Some(prompt));
        }
        if let Some(c) = submit_compose {
            self.modal = None;
            self.submit_compose(c);
        }
        if let Some(f) = submit_claude {
            self.modal = None;
            self.queue_claude(f);
        }
    }

    fn submit_compose(&mut self, c: Compose) {
        let body = c.buffer.trim().to_string();
        if body.is_empty() {
            self.status = "empty comment discarded".into();
            return;
        }
        if let Some(id) = c.edit_of {
            self.store.update_body(&id, &body);
            self.status = "comment edited".into();
        } else if let Some(parent) = c.reply_to {
            // If replying to a GitHub thread, post the reply to GitHub first.
            let gh_tid = self.store.get(&parent).and_then(|r| r.gh_thread_id.clone());
            if let Some(tid) = gh_tid {
                match crate::data::gh::reply_to_thread(&tid, &body, Some(&self.source.repo_root)) {
                    Ok(comment_id) => {
                        // Mirror locally, tagged with the returned id so a re-import dedupes it.
                        if let Some(rid) = self.store.reply(&parent, &body, "local") {
                            if !comment_id.is_empty() {
                                if let Some(c) = self.store.comments.get_mut(&rid) {
                                    c.github_id = Some(comment_id);
                                }
                            }
                        }
                        self.store.save();
                        self.status = "reply posted to GitHub".into();
                    }
                    Err(e) => {
                        self.status =
                            format!("GitHub reply failed: {}", e.lines().next().unwrap_or(""));
                        self.load_diff();
                        return;
                    }
                }
            } else {
                self.store.reply(&parent, &body, "local");
                self.status = "reply added".into();
            }
        } else {
            let (kind, sug) = extract_suggestion(&body);
            // Snapshot the anchored line's code so the comment can be repositioned or
            // flagged outdated later if the code changes (one write via add_range_anchored).
            let anchor = self.code_at_line(c.line);
            self.store.add_range_anchored(
                &c.file,
                "RIGHT",
                c.line,
                c.line_end,
                &body,
                "local",
                kind,
                sug,
                anchor.as_deref(),
            );
            self.status = "comment added".into();
        }
        self.load_diff();
    }
}

fn extract_suggestion(body: &str) -> (&'static str, Option<String>) {
    // last ```suggestion ... ``` block
    let mut last = None;
    let mut rest = body;
    while let Some(i) = rest.find("```suggestion") {
        let after = &rest[i + 13..];
        if let Some(e) = after.find("```") {
            let block = after[..e].trim();
            if !block.is_empty() {
                last = Some(block.to_string());
            }
            rest = &after[e + 3..];
        } else {
            break;
        }
    }
    if last.is_some() {
        ("suggestion", last)
    } else {
        ("normal", None)
    }
}
