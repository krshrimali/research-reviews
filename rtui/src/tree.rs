//! Files-changed directory tree: turn a flat list of changed-file paths into a
//! collapsible directory tree, flattened into the rows the Files panel renders.
//!
//! Rows are produced in depth-first order. A directory whose path is in `collapsed`
//! hides its descendants (but the directory row itself still shows, so it can be
//! re-expanded). File rows carry the index back into the original `files` slice.

use std::collections::HashSet;

use crate::data::git::ChangedFile;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum FileRow {
    Dir {
        path: String,
        name: String,
        depth: usize,
        collapsed: bool,
        nfiles: usize,
    },
    File {
        idx: usize,
        depth: usize,
    },
}

// Internal tree node built from the path segments.
#[derive(Default)]
struct Node {
    dirs: Vec<(String, Node)>, // (segment, child) preserving insertion, sorted later
    files: Vec<(String, usize)>, // (leaf name, index into files slice)
}

impl Node {
    fn dir_mut(&mut self, seg: &str) -> &mut Node {
        if let Some(pos) = self.dirs.iter().position(|(s, _)| s == seg) {
            &mut self.dirs[pos].1
        } else {
            self.dirs.push((seg.to_string(), Node::default()));
            &mut self.dirs.last_mut().unwrap().1
        }
    }
    fn count_files(&self) -> usize {
        self.files.len()
            + self
                .dirs
                .iter()
                .map(|(_, n)| n.count_files())
                .sum::<usize>()
    }
}

/// Build the visible, flattened tree rows for `files`, honoring `collapsed` dir paths.
pub fn build_rows(files: &[ChangedFile], collapsed: &HashSet<String>) -> Vec<FileRow> {
    let mut root = Node::default();
    for (idx, f) in files.iter().enumerate() {
        let parts: Vec<&str> = f.path.split('/').collect();
        let mut node = &mut root;
        for seg in &parts[..parts.len().saturating_sub(1)] {
            node = node.dir_mut(seg);
        }
        let leaf = parts.last().copied().unwrap_or(&f.path);
        node.files.push((leaf.to_string(), idx));
    }

    let mut out = Vec::new();
    emit(&mut root, "", 0, collapsed, &mut out);
    out
}

fn emit(
    node: &mut Node,
    prefix: &str,
    depth: usize,
    collapsed: &HashSet<String>,
    out: &mut Vec<FileRow>,
) {
    // Directories first (sorted), then files (sorted) — GitHub's ordering.
    node.dirs.sort_by(|a, b| a.0.cmp(&b.0));
    node.files.sort_by(|a, b| a.0.cmp(&b.0));
    for (seg, child) in node.dirs.iter_mut() {
        let path = if prefix.is_empty() {
            seg.clone()
        } else {
            format!("{prefix}/{seg}")
        };
        let is_collapsed = collapsed.contains(&path);
        out.push(FileRow::Dir {
            path: path.clone(),
            name: seg.clone(),
            depth,
            collapsed: is_collapsed,
            nfiles: child.count_files(),
        });
        if !is_collapsed {
            emit(child, &path, depth + 1, collapsed, out);
        }
    }
    for (_, idx) in &node.files {
        out.push(FileRow::File { idx: *idx, depth });
    }
}
