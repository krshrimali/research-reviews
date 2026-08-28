//! Unit tests for the collapsible Files directory tree.

use std::collections::HashSet;

use prtui::data::git::ChangedFile;
use prtui::tree::{build_rows, FileRow};

fn cf(path: &str) -> ChangedFile {
    ChangedFile {
        path: path.into(),
        status: "modified".into(),
        additions: 1,
        deletions: 0,
        old_path: None,
    }
}

#[test]
fn builds_nested_tree_dirs_before_files() {
    let files = vec![cf("src/a.rs"), cf("src/sub/b.rs"), cf("README.md")];
    let rows = build_rows(&files, &HashSet::new());
    // Expected DFS order: src/, src/sub/, b.rs, a.rs, README.md.
    match &rows[0] {
        FileRow::Dir { name, depth, .. } => {
            assert_eq!(name, "src");
            assert_eq!(*depth, 0);
        }
        _ => panic!("row0 dir"),
    }
    match &rows[1] {
        FileRow::Dir { name, depth, .. } => {
            assert_eq!(name, "sub");
            assert_eq!(*depth, 1);
        }
        _ => panic!("row1 sub dir"),
    }
    match &rows[2] {
        FileRow::File { depth, idx } => {
            assert_eq!(*depth, 2);
            assert_eq!(files[*idx].path, "src/sub/b.rs");
        }
        _ => panic!("row2 b.rs"),
    }
    match &rows[3] {
        FileRow::File { idx, .. } => assert_eq!(files[*idx].path, "src/a.rs"),
        _ => panic!("row3 a.rs"),
    }
    match &rows[4] {
        FileRow::File { idx, depth } => {
            assert_eq!(*depth, 0);
            assert_eq!(files[*idx].path, "README.md");
        }
        _ => panic!("row4 README"),
    }
}

#[test]
fn collapsing_a_dir_hides_its_descendants() {
    let files = vec![cf("src/a.rs"), cf("src/sub/b.rs"), cf("README.md")];
    let mut collapsed = HashSet::new();
    collapsed.insert("src".to_string());
    let rows = build_rows(&files, &collapsed);
    // Only the collapsed src/ dir and the top-level README.md remain.
    assert_eq!(rows.len(), 2);
    match &rows[0] {
        FileRow::Dir {
            name, collapsed, ..
        } => {
            assert_eq!(name, "src");
            assert!(*collapsed);
        }
        _ => panic!("collapsed dir"),
    }
    match &rows[1] {
        FileRow::File { idx, .. } => assert_eq!(files[*idx].path, "README.md"),
        _ => panic!("README visible"),
    }
}

#[test]
fn dir_file_counts_are_recursive() {
    let files = vec![cf("src/a.rs"), cf("src/sub/b.rs"), cf("src/sub/c.rs")];
    let rows = build_rows(&files, &HashSet::new());
    match &rows[0] {
        FileRow::Dir { name, nfiles, .. } => {
            assert_eq!(name, "src");
            assert_eq!(*nfiles, 3);
        }
        _ => panic!("src count"),
    }
    match &rows[1] {
        FileRow::Dir { name, nfiles, .. } => {
            assert_eq!(name, "sub");
            assert_eq!(*nfiles, 2);
        }
        _ => panic!("sub count"),
    }
}

#[test]
fn flat_files_produce_no_dir_rows() {
    let files = vec![cf("a.rs"), cf("b.rs")];
    let rows = build_rows(&files, &HashSet::new());
    assert_eq!(rows.len(), 2);
    assert!(rows.iter().all(|r| matches!(r, FileRow::File { .. })));
}
