//! Diff presentation helpers used by the Diff tab:
//!   * `word_diff` — intra-line (word-level) diff between a deleted and added line,
//!     so a modified line highlights only the words that actually changed.
//!   * `split_rows` — pair a unified diff's lines into side-by-side (old | new) rows
//!     for the split/side-by-side view.
//!
//! Both are pure functions over the already-parsed `DiffLine`s, computed offline (no
//! `git` word-diff dependency), so they work the same for PRs, branches, and commits.

use crate::app::{DiffKind, DiffLine};

/// Where a comment's anchored code is, relative to the current diff.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Anchor {
    InPlace,     // still on its original line
    MoveTo(u32), // unchanged but moved to this new-side line
    Outdated,    // the code is gone — GitHub "Outdated"
}

/// How far a comment may be repositioned before we treat an ambiguous (duplicate-line)
/// match as untrustworthy and mark the comment outdated instead of hopping to it.
const REPOSITION_WINDOW: i64 = 12;

/// Decide what happened to a comment anchored at `line_start` with original code `anchor`,
/// given the current new-side `code_at` (line -> trimmed code):
/// - unchanged at `line_start` → `InPlace`;
/// - a **unique** occurrence elsewhere → `MoveTo` it;
/// - **duplicate** occurrences → `MoveTo` the nearest only if within `REPOSITION_WINDOW`
///   lines (a small shift), otherwise `Outdated` (too ambiguous to trust);
/// - no occurrence → `Outdated`.
pub fn locate_anchor(
    line_start: u32,
    anchor: &str,
    code_at: &std::collections::HashMap<u32, String>,
) -> Anchor {
    if code_at
        .get(&line_start)
        .map(|s| s == anchor)
        .unwrap_or(false)
    {
        return Anchor::InPlace;
    }
    let matches: Vec<u32> = code_at
        .iter()
        .filter(|(_, v)| v.as_str() == anchor)
        .map(|(k, _)| *k)
        .collect();
    match matches.len() {
        0 => Anchor::Outdated,
        1 => Anchor::MoveTo(matches[0]),
        _ => {
            let nearest = *matches
                .iter()
                .min_by_key(|k| (**k as i64 - line_start as i64).abs())
                .unwrap();
            if (nearest as i64 - line_start as i64).abs() <= REPOSITION_WINDOW {
                Anchor::MoveTo(nearest)
            } else {
                Anchor::Outdated
            }
        }
    }
}

/// Tokenize a line into word / non-word runs (words = alphanumerics + `_`; every other
/// run is punctuation/whitespace kept verbatim), so the diff aligns on word boundaries.
fn tokens(s: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = String::new();
    let mut cur_word: Option<bool> = None;
    for ch in s.chars() {
        let is_word = ch.is_alphanumeric() || ch == '_';
        match cur_word {
            Some(w) if w == is_word => cur.push(ch),
            _ => {
                if !cur.is_empty() {
                    out.push(std::mem::take(&mut cur));
                }
                cur.push(ch);
                cur_word = Some(is_word);
            }
        }
    }
    if !cur.is_empty() {
        out.push(cur);
    }
    out
}

/// Longest-common-subsequence membership: returns two boolean vectors marking which
/// tokens of `a` / `b` are part of the LCS (i.e. unchanged). Tokens not in the LCS are
/// the changed ones. O(n·m) — lines are short, so this is fine per changed pair.
fn lcs_keep(a: &[String], b: &[String]) -> (Vec<bool>, Vec<bool>) {
    let (n, m) = (a.len(), b.len());
    let mut dp = vec![vec![0u16; m + 1]; n + 1];
    for i in (0..n).rev() {
        for j in (0..m).rev() {
            dp[i][j] = if a[i] == b[j] {
                dp[i + 1][j + 1] + 1
            } else {
                dp[i + 1][j].max(dp[i][j + 1])
            };
        }
    }
    let mut keep_a = vec![false; n];
    let mut keep_b = vec![false; m];
    let (mut i, mut j) = (0, 0);
    while i < n && j < m {
        if a[i] == b[j] {
            keep_a[i] = true;
            keep_b[j] = true;
            i += 1;
            j += 1;
        } else if dp[i + 1][j] >= dp[i][j + 1] {
            i += 1;
        } else {
            j += 1;
        }
    }
    (keep_a, keep_b)
}

/// Word-diff between an old and a new line. Returns per-side spans of
/// `(text, changed)` where `changed == true` marks an inserted/deleted word to
/// emphasize. `old`/`new` are the code *without* the leading `+`/`-` sign.
#[allow(clippy::type_complexity)]
pub fn word_diff(old: &str, new: &str) -> (Vec<(String, bool)>, Vec<(String, bool)>) {
    let (ta, tb) = (tokens(old), tokens(new));
    let (keep_a, keep_b) = lcs_keep(&ta, &tb);
    let merge = |toks: Vec<String>, keep: Vec<bool>| {
        let mut spans: Vec<(String, bool)> = Vec::new();
        for (t, k) in toks.into_iter().zip(keep) {
            let changed = !k;
            match spans.last_mut() {
                Some((s, c)) if *c == changed => s.push_str(&t),
                _ => spans.push((t, changed)),
            }
        }
        spans
    };
    (merge(ta, keep_a), merge(tb, keep_b))
}

/// Attach word-diff highlighting to modified lines in a parsed unified diff: within each
/// contiguous run of `-` lines immediately followed by `+` lines, pair del[i] with add[i]
/// and mark the changed words on both. Pure insertions / deletions are left un-paired
/// (fully colored). Mutates `lines` in place, setting `DiffLine::word_hl`.
pub fn annotate_word_diff(lines: &mut [DiffLine]) {
    let mut i = 0;
    while i < lines.len() {
        if lines[i].kind == DiffKind::Del {
            // Gather the del-run then the following add-run.
            let del_start = i;
            while i < lines.len() && lines[i].kind == DiffKind::Del {
                i += 1;
            }
            let add_start = i;
            while i < lines.len() && lines[i].kind == DiffKind::Add {
                i += 1;
            }
            let dels = add_start - del_start;
            let adds = i - add_start;
            // Only pair when both sides exist; pair by position up to the shorter run.
            for k in 0..dels.min(adds) {
                let old = lines[del_start + k].text.get(1..).unwrap_or("").to_string();
                let new = lines[add_start + k].text.get(1..).unwrap_or("").to_string();
                let (ho, hn) = word_diff(&old, &new);
                lines[del_start + k].word_hl = Some(ho);
                lines[add_start + k].word_hl = Some(hn);
            }
        } else {
            i += 1;
        }
    }
}

/// One side of a split row: a line number and its text/kind (or empty filler).
#[derive(Clone)]
pub struct Cell {
    pub ln: Option<u32>,
    pub text: String, // code without the +/- sign
    pub kind: DiffKind,
    pub word_hl: Option<Vec<(String, bool)>>,
}

/// A side-by-side row for the split view. Comment/marker info is anchored to the new
/// (right) side via `comments`/`has_claude`/`has_github`.
#[derive(Clone)]
pub struct SplitRow {
    pub left: Option<Cell>,
    pub right: Option<Cell>,
    pub hunk: Option<String>, // Some(text) => full-width hunk/meta header row
    pub comments: u32,
    pub has_claude: bool,
    pub has_github: bool,
}

/// Find the split row that corresponds to the unified cursor, matching on the new-side
/// line (right cell) or, when the cursor is on a deletion, the old-side line (left cell).
/// Returns None if neither side matches (e.g. cursor on a hunk/meta row).
pub fn split_cursor_row(
    rows: &[SplitRow],
    new_ln: Option<u32>,
    old_ln: Option<u32>,
) -> Option<usize> {
    rows.iter().position(|r| {
        (new_ln.is_some() && r.right.as_ref().and_then(|c| c.ln) == new_ln)
            || (old_ln.is_some() && r.left.as_ref().and_then(|c| c.ln) == old_ln)
    })
}

/// Whether a split row falls within a visual selection, given the sets of selected
/// new-side and old-side line numbers.
pub fn split_row_selected(
    row: &SplitRow,
    sel_new: &std::collections::HashSet<u32>,
    sel_old: &std::collections::HashSet<u32>,
) -> bool {
    row.right
        .as_ref()
        .and_then(|c| c.ln)
        .map(|n| sel_new.contains(&n))
        .unwrap_or(false)
        || row
            .left
            .as_ref()
            .and_then(|c| c.ln)
            .map(|n| sel_old.contains(&n))
            .unwrap_or(false)
}

/// Turn a parsed unified diff into side-by-side rows. Context lines appear on both sides;
/// a change block pairs deletions on the left with additions on the right; leftover
/// del/add lines get an empty filler cell on the opposite side. Inline expanded-thread
/// (`Comment`) rows are skipped here — the split view shows markers, not inline threads.
pub fn split_rows(lines: &[DiffLine]) -> Vec<SplitRow> {
    let mut rows = Vec::new();
    let mut i = 0;
    let strip = |dl: &DiffLine| dl.text.get(1..).unwrap_or("").to_string();
    while i < lines.len() {
        let dl = &lines[i];
        match dl.kind {
            DiffKind::Comment => {
                i += 1; // not shown in split view
            }
            DiffKind::Meta | DiffKind::Hunk => {
                rows.push(SplitRow {
                    left: None,
                    right: None,
                    hunk: Some(dl.text.clone()),
                    comments: 0,
                    has_claude: false,
                    has_github: false,
                });
                i += 1;
            }
            DiffKind::Ctx => {
                let cell = Cell {
                    ln: dl.new_ln,
                    text: strip(dl),
                    kind: DiffKind::Ctx,
                    word_hl: None,
                };
                rows.push(SplitRow {
                    left: Some(Cell {
                        ln: dl.old_ln,
                        ..cell.clone()
                    }),
                    right: Some(cell),
                    hunk: None,
                    comments: dl.comments,
                    has_claude: dl.has_claude,
                    has_github: dl.has_github,
                });
                i += 1;
            }
            DiffKind::Del | DiffKind::Add => {
                let del_start = i;
                while i < lines.len() && lines[i].kind == DiffKind::Del {
                    i += 1;
                }
                let add_start = i;
                while i < lines.len() && lines[i].kind == DiffKind::Add {
                    i += 1;
                }
                let dels = add_start - del_start;
                let adds = i - add_start;
                let pairs = dels.max(adds);
                for k in 0..pairs {
                    let left = (k < dels).then(|| {
                        let d = &lines[del_start + k];
                        Cell {
                            ln: d.old_ln,
                            text: strip(d),
                            kind: DiffKind::Del,
                            word_hl: d.word_hl.clone(),
                        }
                    });
                    let radd = (k < adds).then(|| &lines[add_start + k]);
                    let right = radd.map(|a| Cell {
                        ln: a.new_ln,
                        text: strip(a),
                        kind: DiffKind::Add,
                        word_hl: a.word_hl.clone(),
                    });
                    rows.push(SplitRow {
                        left,
                        right,
                        hunk: None,
                        comments: radd.map(|a| a.comments).unwrap_or(0),
                        has_claude: radd.map(|a| a.has_claude).unwrap_or(false),
                        has_github: radd.map(|a| a.has_github).unwrap_or(false),
                    });
                }
            }
        }
    }
    rows
}
