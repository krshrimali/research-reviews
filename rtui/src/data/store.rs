//! Persistent comment + Claude-session store (serde_json, atomic writes, tombstones).

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;

use super::source::Source;

fn now() -> String {
    // Monotonic, fixed-width so lexical order == chronological order (nanoseconds are
    // too coarse when several comments are created in the same instant — e.g. a review).
    use std::sync::atomic::{AtomicU64, Ordering};
    static SEQ: AtomicU64 = AtomicU64::new(0);
    let seq = SEQ.fetch_add(1, Ordering::Relaxed);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("{nanos:039}-{seq:012}")
}

/// Normalize a `created_at` stamp to epoch nanoseconds for chronological sorting.
/// Handles both local stamps ("{epoch_nanos}-{seq}") and GitHub ISO-8601 ("2026-08-01T…Z").
fn ts_key(created_at: &str) -> u128 {
    let s = created_at.trim();
    if let Some((date, time)) = s.split_once('T') {
        if let Some(secs) = iso_epoch_secs(date, time) {
            return (secs.max(0) as u128) * 1_000_000_000;
        }
    }
    // Local stamp: leading digits are epoch nanos.
    s.chars()
        .take_while(|c| c.is_ascii_digit())
        .collect::<String>()
        .parse()
        .unwrap_or(0)
}

/// Convert an ISO date ("YYYY-MM-DD") + time ("HH:MM:SS[.fff][Z]") to epoch seconds (UTC).
/// Uses Howard Hinnant's days-from-civil algorithm; ignores sub-second and timezone offset.
fn iso_epoch_secs(date: &str, time: &str) -> Option<i64> {
    let d: Vec<i64> = date.split('-').filter_map(|x| x.parse().ok()).collect();
    if d.len() != 3 {
        return None;
    }
    let (y, m, day) = (d[0], d[1], d[2]);
    let t = time.trim_end_matches('Z');
    let tp: Vec<i64> = t
        .split(':')
        .map(|x| x.split('.').next().unwrap_or("").parse().unwrap_or(0))
        .collect();
    let (hh, mm, ss) = (
        tp.first().copied().unwrap_or(0),
        tp.get(1).copied().unwrap_or(0),
        tp.get(2).copied().unwrap_or(0),
    );
    let yy = if m <= 2 { y - 1 } else { y };
    let era = (if yy >= 0 { yy } else { yy - 399 }) / 400;
    let yoe = yy - era * 400;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146097 + doe - 719468;
    Some(days * 86400 + hh * 3600 + mm * 60 + ss)
}

fn author_for(origin: &str) -> String {
    match origin {
        "claude" => "claude".to_string(),
        "github" => "github".to_string(),
        _ => std::env::var("USER").unwrap_or_else(|_| "you".into()),
    }
}

fn uuid() -> String {
    // A valid RFC-4122 v4-format UUID (claude --session-id requires this). Not
    // cryptographic — seeded from time + pid + a counter via splitmix64.
    use std::sync::atomic::{AtomicU64, Ordering};
    static C: AtomicU64 = AtomicU64::new(0);
    let counter = C.fetch_add(1, Ordering::Relaxed);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0);
    let mut seed =
        nanos ^ counter.wrapping_mul(0x9E37_79B9_7F4A_7C15) ^ ((std::process::id() as u64) << 32);
    let mut next = || {
        seed = seed.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = seed;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    };
    let (a, b) = (next(), next());
    let mut by = [0u8; 16];
    by[..8].copy_from_slice(&a.to_le_bytes());
    by[8..].copy_from_slice(&b.to_le_bytes());
    by[6] = (by[6] & 0x0f) | 0x40; // version 4
    by[8] = (by[8] & 0x3f) | 0x80; // variant 10xx
    format!(
        "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        by[0], by[1], by[2], by[3], by[4], by[5], by[6], by[7],
        by[8], by[9], by[10], by[11], by[12], by[13], by[14], by[15]
    )
}

fn short_hash(s: &str) -> String {
    let mut h: u32 = 2166136261;
    for b in s.bytes() {
        h ^= b as u32;
        h = h.wrapping_mul(16777619);
    }
    format!("{h:08x}")
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Comment {
    pub id: String,
    pub file: String,
    pub side: String,
    pub line_start: u32,
    pub line_end: u32,
    pub body: String,
    #[serde(default = "default_local")]
    pub origin: String, // local|github|claude
    #[serde(default = "default_draft")]
    pub status: String, // draft|resolved|outdated
    #[serde(default = "default_normal")]
    pub kind: String, // normal|suggestion
    #[serde(default)]
    pub suggestion_text: Option<String>,
    #[serde(default)]
    pub in_reply_to: Option<String>,
    #[serde(default)]
    pub github_id: Option<String>, // the GH review-comment node id (for dedupe)
    #[serde(default)]
    pub gh_thread_id: Option<String>, // the GH review-thread node id (for reply/resolve)
    #[serde(default)]
    pub author: String,
    #[serde(default)]
    pub created_at: String,
    #[serde(default)]
    pub hidden: bool,
    /// reaction name -> the set of reactors (usernames). Count is the vec length.
    #[serde(default)]
    pub reactions: std::collections::BTreeMap<String, Vec<String>>,
    /// trimmed source code of the anchored line when the comment was made. Used to
    /// reposition the comment if the line moved, or mark it outdated if the code changed.
    #[serde(default)]
    pub anchor_text: Option<String>,
    /// true when the anchored code has changed since the comment was written (GitHub's
    /// "Outdated"): hidden from the inline diff, shown in the Comments/Conversation views.
    #[serde(default)]
    pub outdated: bool,
    #[serde(default)]
    pub workflow_state: String,
    #[serde(default)]
    pub assessment: String,
    #[serde(default)]
    pub label: String,
    #[serde(default)]
    pub priority: u8,
    #[serde(default)]
    pub action_owner: String,
    #[serde(default)]
    pub implementation_commit: Option<String>,
    #[serde(default)]
    pub implementation_worktree: Option<String>,
    #[serde(default)]
    pub push_state: String,
    #[serde(default)]
    pub validation: Vec<String>,
}
fn default_local() -> String {
    "local".into()
}

/// The reaction names we support, in display order (ASCII labels — no emoji, per the
/// no-glyph-tofu rule). Mirrors GitHub's reaction content values.
pub const REACTIONS: &[&str] = &[
    "+1", "-1", "laugh", "hooray", "confused", "heart", "rocket", "eyes",
];
fn default_draft() -> String {
    "draft".into()
}
fn default_normal() -> String {
    "normal".into()
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct Session {
    pub id: String,
    pub state: String, // running|done|error
    #[serde(default)]
    pub verdict: Option<String>,
    #[serde(default)]
    pub summary: String,
    #[serde(default)]
    pub instruction: String,
    #[serde(default)]
    pub allow_edits: bool,
    #[serde(default)]
    pub auto_resolve: bool,
    #[serde(default)]
    pub started_at: String,
    #[serde(default)]
    pub ended_at: Option<String>,
    #[serde(default)]
    pub replied: Vec<String>,
    #[serde(default)]
    pub new_comment_ids: Vec<String>,
    #[serde(default)]
    pub notes: Vec<String>,
    #[serde(default)]
    pub log: Vec<String>,
    #[serde(default)]
    pub error: Option<String>,
    #[serde(default)]
    pub applied: bool,
    #[serde(default)]
    pub address_comments: bool,
    #[serde(default)]
    pub worktree: Option<String>,
    #[serde(default)]
    pub target_branch: Option<String>,
    #[serde(default)]
    pub address_comment_ids: Vec<String>,
    #[serde(default)]
    pub push_changes: bool,
    #[serde(default)]
    pub reviewed_head: String,
}

#[derive(Debug, Serialize, Deserialize, Default)]
struct Doc {
    #[serde(default)]
    schema_version: u32,
    #[serde(default)]
    comments: HashMap<String, Comment>,
    #[serde(default)]
    sessions: HashMap<String, Session>,
    #[serde(default)]
    tombstones: HashMap<String, String>,
    #[serde(default)]
    viewed: std::collections::HashSet<String>,
    #[serde(default)]
    ui: UiPrefs,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct UiPrefs {
    pub tab: u8,
    pub file: Option<String>,
    pub diff_row: usize,
    pub conv_scroll: u16,
    pub timeline_scroll: u16,
    pub claude_scroll: u16,
    pub collapsed_dirs: std::collections::HashSet<String>,
}

pub struct Store {
    pub source_key: String,
    pub repo_root: String,
    pub comments: HashMap<String, Comment>,
    pub sessions: HashMap<String, Session>,
    pub tombstones: HashMap<String, String>,
    /// files the user marked "Viewed" (GitHub-style).
    pub viewed: std::collections::HashSet<String>,
    pub ui: UiPrefs,
    /// State directory captured at construction (mirrors app startup), so later changes to
    /// `$PRTUI_STATE_DIR` can't repoint an already-open store — and tests don't race on it.
    state_dir: PathBuf,
    legacy_source_key: Option<String>,
    /// Lazily-built root -> chronologically sorted reply ids. Invalidated by every save.
    reply_index: std::cell::RefCell<Option<HashMap<String, Vec<String>>>>,
}

fn state_root() -> PathBuf {
    if let Ok(d) = std::env::var("PRTUI_STATE_DIR") {
        return PathBuf::from(d);
    }
    let base = std::env::var("XDG_STATE_HOME")
        .unwrap_or_else(|_| format!("{}/.local/state", std::env::var("HOME").unwrap_or_default()));
    PathBuf::from(base).join("prtui")
}

impl Store {
    pub fn for_source(source: &Source) -> Store {
        Self::for_source_in(source, state_root())
    }

    /// Construct a store rooted at an explicit state directory (bypassing `$PRTUI_STATE_DIR`).
    /// Useful for tests that need a stable dir immune to the process-global env var.
    pub fn for_source_in(source: &Source, state_dir: PathBuf) -> Store {
        let mut s = Store {
            source_key: source.key.clone(),
            repo_root: source.repo_root.clone(),
            comments: HashMap::new(),
            sessions: HashMap::new(),
            tombstones: HashMap::new(),
            viewed: std::collections::HashSet::new(),
            ui: UiPrefs::default(),
            state_dir,
            legacy_source_key: source.legacy_pr_key(),
            reply_index: std::cell::RefCell::new(None),
        };
        s.load();
        s
    }

    fn path(&self) -> PathBuf {
        self.path_for(&self.source_key)
    }

    fn path_for(&self, key: &str) -> PathBuf {
        self.state_dir
            .join(short_hash(&self.repo_root))
            .join(format!("{}.json", short_hash(key)))
    }

    fn load(&mut self) {
        let p = self.path();
        let text = std::fs::read_to_string(&p).ok().or_else(|| {
            self.legacy_source_key
                .as_deref()
                .and_then(|key| std::fs::read_to_string(self.path_for(key)).ok())
        });
        let Some(text) = text else {
            return;
        };
        let Ok(doc) = serde_json::from_str::<Doc>(&text) else {
            return;
        };
        self.tombstones = doc.tombstones;
        for (id, c) in doc.comments {
            if !self.tombstones.contains_key(&id) {
                self.comments.insert(id, c);
            }
        }
        self.sessions = doc.sessions;
        self.viewed = doc.viewed;
        self.ui = doc.ui;
    }

    pub fn save(&self) {
        let started = std::time::Instant::now();
        *self.reply_index.borrow_mut() = None;
        let p = self.path();
        if let Some(parent) = p.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        // Merge with whatever is on disk (another process) before writing.
        let mut disk: Doc = std::fs::read_to_string(&p)
            .ok()
            .and_then(|t| serde_json::from_str(&t).ok())
            .unwrap_or_default();
        for (k, v) in &self.tombstones {
            disk.tombstones.insert(k.clone(), v.clone());
        }
        for (id, c) in &self.comments {
            disk.comments.insert(id.clone(), c.clone());
        }
        for (id, s) in &self.sessions {
            disk.sessions.insert(id.clone(), s.clone());
        }
        disk.comments
            .retain(|id, _| !disk.tombstones.contains_key(id));
        disk.viewed = self.viewed.clone();
        disk.ui = self.ui.clone();
        disk.schema_version = 1;

        let Ok(json) = serde_json::to_string(&disk) else {
            return;
        };
        let tmp = p.with_extension(format!("tmp{}", std::process::id()));
        if std::fs::write(&tmp, json).is_ok() {
            let _ = std::fs::rename(&tmp, &p);
        }
        crate::perf::record("store.save", started.elapsed());
    }

    #[allow(clippy::too_many_arguments)]
    pub fn add(
        &mut self,
        file: &str,
        side: &str,
        line: u32,
        body: &str,
        origin: &str,
        kind: &str,
        suggestion: Option<String>,
    ) -> String {
        self.add_range(file, side, line, line, body, origin, kind, suggestion)
    }

    #[allow(clippy::too_many_arguments)]
    pub fn add_range(
        &mut self,
        file: &str,
        side: &str,
        start: u32,
        end: u32,
        body: &str,
        origin: &str,
        kind: &str,
        suggestion: Option<String>,
    ) -> String {
        self.add_range_anchored(file, side, start, end, body, origin, kind, suggestion, None)
    }

    /// Like `add_range` but records the anchored line's code in the same write (one `save()`
    /// instead of add-then-set_anchor).
    #[allow(clippy::too_many_arguments)]
    pub fn add_range_anchored(
        &mut self,
        file: &str,
        side: &str,
        start: u32,
        end: u32,
        body: &str,
        origin: &str,
        kind: &str,
        suggestion: Option<String>,
        anchor: Option<&str>,
    ) -> String {
        let (start, end) = (start.min(end), start.max(end));
        let id = uuid();
        self.comments.insert(
            id.clone(),
            Comment {
                id: id.clone(),
                file: file.into(),
                side: side.into(),
                line_start: start,
                line_end: end,
                body: body.into(),
                origin: origin.into(),
                status: "draft".into(),
                kind: kind.into(),
                suggestion_text: suggestion,
                in_reply_to: None,
                github_id: None,
                gh_thread_id: None,
                author: author_for(origin),
                created_at: now(),
                hidden: false,
                reactions: Default::default(),
                anchor_text: anchor.map(|a| a.trim().to_string()),
                outdated: false,
                workflow_state: "unresolved".into(),
                assessment: String::new(),
                label: String::new(),
                priority: 0,
                action_owner: "author".into(),
                implementation_commit: None,
                implementation_worktree: None,
                push_state: String::new(),
                validation: vec![],
            },
        );
        self.save();
        id
    }

    pub fn reply(&mut self, parent_id: &str, body: &str, origin: &str) -> Option<String> {
        let parent = self.comments.get(parent_id)?.clone();
        let root = parent
            .in_reply_to
            .clone()
            .unwrap_or_else(|| parent_id.to_string());
        let id = uuid();
        self.comments.insert(
            id.clone(),
            Comment {
                id: id.clone(),
                file: parent.file,
                side: parent.side,
                line_start: parent.line_start,
                line_end: parent.line_end,
                body: body.into(),
                origin: origin.into(),
                status: "draft".into(),
                kind: "normal".into(),
                suggestion_text: None,
                in_reply_to: Some(root),
                github_id: None,
                gh_thread_id: None,
                author: author_for(origin),
                created_at: now(),
                hidden: false,
                reactions: Default::default(),
                anchor_text: None,
                outdated: false,
                workflow_state: "unresolved".into(),
                assessment: String::new(),
                label: String::new(),
                priority: 0,
                action_owner: "author".into(),
                implementation_commit: None,
                implementation_worktree: None,
                push_state: String::new(),
                validation: vec![],
            },
        );
        self.save();
        Some(id)
    }

    /// Toggle `author`'s `reaction` on comment `id`. Returns true if the reaction is now
    /// present (added), false if it was removed. Empty reaction buckets are pruned.
    pub fn toggle_reaction(&mut self, id: &str, reaction: &str, author: &str) -> bool {
        let Some(c) = self.comments.get_mut(id) else {
            return false;
        };
        let bucket = c.reactions.entry(reaction.to_string()).or_default();
        let added = if let Some(pos) = bucket.iter().position(|a| a == author) {
            bucket.remove(pos);
            false
        } else {
            bucket.push(author.to_string());
            true
        };
        if bucket.is_empty() {
            c.reactions.remove(reaction);
        }
        self.save();
        added
    }

    /// Record the anchored line's code (trimmed) so the comment can later be repositioned
    /// or flagged outdated when the code changes.
    pub fn set_anchor(&mut self, id: &str, code: &str) {
        if let Some(c) = self.comments.get_mut(id) {
            c.anchor_text = Some(code.trim().to_string());
            self.save();
        }
    }

    /// Move a root thread (and shift its end) to a new start line — used when the anchored
    /// code moved but is unchanged. Returns true if anything changed.
    pub fn reposition(&mut self, id: &str, new_start: u32) -> bool {
        let Some(c) = self.comments.get_mut(id) else {
            return false;
        };
        if c.line_start == new_start && !c.outdated {
            return false;
        }
        let span = c.line_end.saturating_sub(c.line_start);
        c.line_start = new_start;
        c.line_end = new_start + span;
        c.outdated = false;
        true
    }

    /// Flag/unflag a comment as outdated. Returns true if the flag changed. Does not save
    /// (callers batch a single save).
    pub fn set_outdated(&mut self, id: &str, outdated: bool) -> bool {
        let Some(c) = self.comments.get_mut(id) else {
            return false;
        };
        if c.outdated == outdated {
            return false;
        }
        c.outdated = outdated;
        true
    }

    /// Backfill the anchor code for a comment that has none (pre-feature comments), assuming
    /// the code currently at its line is the intended anchor. No-op if it already has one.
    /// Returns true if set (caller batches the save).
    pub fn backfill_anchor(&mut self, id: &str, code: &str) -> bool {
        let Some(c) = self.comments.get_mut(id) else {
            return false;
        };
        if c.anchor_text
            .as_deref()
            .map(|s| !s.is_empty())
            .unwrap_or(false)
        {
            return false;
        }
        c.anchor_text = Some(code.trim().to_string());
        true
    }

    pub fn root_of(&self, id: &str) -> String {
        self.comments
            .get(id)
            .and_then(|c| c.in_reply_to.clone())
            .unwrap_or_else(|| id.to_string())
    }

    pub fn delete(&mut self, id: &str) -> bool {
        let Some(c) = self.comments.get(id).cloned() else {
            return false;
        };
        let n = now();
        if c.in_reply_to.is_none() {
            let children: Vec<String> = self
                .comments
                .values()
                .filter(|o| o.in_reply_to.as_deref() == Some(id))
                .map(|o| o.id.clone())
                .collect();
            for cid in children {
                self.comments.remove(&cid);
                self.tombstones.insert(cid, n.clone());
            }
        }
        self.comments.remove(id);
        self.tombstones.insert(id.to_string(), n);
        self.save();
        true
    }

    pub fn set_resolved(&mut self, id: &str, resolved: bool) {
        let root = self.root_of(id);
        let status = if resolved { "resolved" } else { "draft" };
        for c in self.comments.values_mut() {
            if c.id == root || c.in_reply_to.as_deref() == Some(&root) {
                c.status = status.into();
            }
        }
        self.save();
    }

    /// Toggle/set hidden on a whole thread (root + replies).
    pub fn set_hidden(&mut self, id: &str, hidden: bool) {
        let root = self.root_of(id);
        for c in self.comments.values_mut() {
            if c.id == root || c.in_reply_to.as_deref() == Some(&root) {
                c.hidden = hidden;
            }
        }
        self.save();
    }

    pub fn is_viewed(&self, file: &str) -> bool {
        self.viewed.contains(file)
    }

    pub fn toggle_viewed(&mut self, file: &str) {
        if !self.viewed.remove(file) {
            self.viewed.insert(file.to_string());
        }
        self.save();
    }

    /// Replace a single comment's body (used by edit).
    pub fn update_body(&mut self, id: &str, body: &str) -> bool {
        if let Some(c) = self.comments.get_mut(id) {
            c.body = body.to_string();
            self.save();
            true
        } else {
            false
        }
    }

    pub fn update_workflow(&mut self, id: &str, state: &str, assessment: Option<&str>) -> bool {
        let root = self.root_of(id);
        let Some(c) = self.comments.get_mut(&root) else {
            return false;
        };
        c.workflow_state = state.into();
        if let Some(a) = assessment {
            c.assessment = a.into();
        }
        self.save();
        true
    }

    pub fn set_thread_metadata(
        &mut self,
        id: &str,
        commit: Option<&str>,
        worktree: Option<&str>,
        push_state: &str,
        validation: Vec<String>,
    ) {
        let root = self.root_of(id);
        if let Some(c) = self.comments.get_mut(&root) {
            c.implementation_commit = commit.map(str::to_string);
            c.implementation_worktree = worktree.map(str::to_string);
            c.push_state = push_state.into();
            c.validation = validation;
            c.workflow_state = if push_state == "pushed" {
                "pushed"
            } else {
                "committed"
            }
            .into();
            self.save();
        }
    }

    pub fn cycle_label(&mut self, id: &str) {
        const LABELS: &[&str] = &[
            "",
            "bug",
            "security",
            "performance",
            "style",
            "question",
            "suggestion",
            "blocking",
        ];
        let root = self.root_of(id);
        if let Some(c) = self.comments.get_mut(&root) {
            let i = LABELS.iter().position(|x| *x == c.label).unwrap_or(0);
            c.label = LABELS[(i + 1) % LABELS.len()].into();
            self.save();
        }
    }

    pub fn cycle_priority(&mut self, id: &str) {
        let root = self.root_of(id);
        if let Some(c) = self.comments.get_mut(&root) {
            c.priority = (c.priority + 1) % 4;
            self.save();
        }
    }

    pub fn cycle_owner(&mut self, id: &str) {
        const OWNERS: &[&str] = &["author", "reviewer", "claude", "nobody"];
        let root = self.root_of(id);
        if let Some(c) = self.comments.get_mut(&root) {
            let i = OWNERS
                .iter()
                .position(|x| *x == c.action_owner)
                .unwrap_or(0);
            c.action_owner = OWNERS[(i + 1) % OWNERS.len()].into();
            self.save();
        }
    }

    /// Mark a thread (and replies) as published to GitHub; optionally store the review id.
    pub fn mark_published(&mut self, id: &str) {
        let root = self.root_of(id);
        for c in self.comments.values_mut() {
            if c.id == root || c.in_reply_to.as_deref() == Some(&root) {
                c.status = "published".into();
            }
        }
        self.save();
    }

    pub fn threads_for_file(&self, file: &str) -> Vec<Comment> {
        let mut v: Vec<Comment> = self
            .comments
            .values()
            .filter(|c| c.file == file && c.in_reply_to.is_none())
            .cloned()
            .collect();
        v.sort_by_key(|c| c.line_start);
        v
    }

    pub fn all_threads(&self) -> Vec<Comment> {
        self.comments
            .values()
            .filter(|c| c.in_reply_to.is_none())
            .cloned()
            .collect()
    }

    pub fn replies(&self, root_id: &str) -> Vec<Comment> {
        if self.reply_index.borrow().is_none() {
            let mut index: HashMap<String, Vec<String>> = HashMap::new();
            for c in self.comments.values() {
                if let Some(root) = &c.in_reply_to {
                    index.entry(root.clone()).or_default().push(c.id.clone());
                }
            }
            for ids in index.values_mut() {
                ids.sort_by(|a, b| {
                    let a = &self.comments[a];
                    let b = &self.comments[b];
                    ts_key(&a.created_at)
                        .cmp(&ts_key(&b.created_at))
                        .then_with(|| a.created_at.cmp(&b.created_at))
                });
            }
            *self.reply_index.borrow_mut() = Some(index);
        }
        self.reply_index
            .borrow()
            .as_ref()
            .and_then(|index| index.get(root_id))
            .into_iter()
            .flatten()
            .filter_map(|id| self.comments.get(id).cloned())
            .collect()
    }

    pub fn get(&self, id: &str) -> Option<&Comment> {
        self.comments.get(id)
    }

    /// One-pass summary of visible comments per file: (total, has_claude, has_github),
    /// counting a root and its replies, skipping threads whose root is hidden. Lets the
    /// Files panel render its markers without an O(files×comments) rescan every frame.
    pub fn file_comment_summary(&self) -> HashMap<String, (usize, bool, bool)> {
        let roots: HashMap<&str, &Comment> = self
            .comments
            .values()
            .filter(|c| c.in_reply_to.is_none())
            .map(|c| (c.id.as_str(), c))
            .collect();
        let mut m: HashMap<String, (usize, bool, bool)> = HashMap::new();
        for c in self.comments.values() {
            let root = match &c.in_reply_to {
                Some(p) => match roots.get(p.as_str()) {
                    Some(r) => *r,
                    None => continue,
                },
                None => c,
            };
            if root.hidden {
                continue;
            }
            let e = m.entry(root.file.clone()).or_insert((0, false, false));
            e.0 += 1;
            e.1 |= c.origin == "claude";
            e.2 |= c.origin == "github";
        }
        m
    }

    pub fn latest_session(&self) -> Option<&Session> {
        self.sessions
            .values()
            .max_by(|a, b| a.started_at.cmp(&b.started_at))
    }

    pub fn save_ui(&mut self, ui: UiPrefs) {
        self.ui = ui;
        self.save();
    }

    /// Update transient UI preferences without forcing synchronous disk I/O.
    pub fn stage_ui(&mut self, ui: UiPrefs) {
        self.ui = ui;
    }
}

pub fn new_uuid() -> String {
    uuid()
}
pub fn timestamp() -> String {
    now()
}
