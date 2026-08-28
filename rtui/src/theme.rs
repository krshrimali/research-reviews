//! Runtime-switchable color themes. Every component reads colors through the accessor
//! functions (`theme::bg()`, `theme::accent()`, …), so cycling the theme recolors the
//! whole UI at once.

use std::sync::atomic::{AtomicUsize, Ordering};

use ratatui::style::Color;

#[derive(Clone, Copy)]
pub struct Theme {
    pub bg: Color,
    pub panel: Color,
    pub border: Color,
    pub border_focus: Color,
    pub text: Color,
    pub muted: Color,
    pub accent: Color,
    pub green: Color,
    pub red: Color,
    pub yellow: Color,
    pub purple: Color,
    pub add_bg: Color,
    pub del_bg: Color,
    pub sel_bg: Color,
    pub hunk: Color,
}

const fn rgb(r: u8, g: u8, b: u8) -> Color {
    Color::Rgb(r, g, b)
}

pub const GITHUB_DARK: Theme = Theme {
    bg: rgb(13, 17, 23),
    panel: rgb(22, 27, 34),
    border: rgb(48, 54, 61),
    border_focus: rgb(88, 166, 255),
    text: rgb(201, 209, 217),
    muted: rgb(139, 148, 158),
    accent: rgb(88, 166, 255),
    green: rgb(63, 185, 80),
    red: rgb(248, 81, 73),
    yellow: rgb(210, 153, 34),
    purple: rgb(188, 140, 255),
    add_bg: rgb(18, 38, 30),
    del_bg: rgb(37, 23, 28),
    sel_bg: rgb(31, 42, 64),
    hunk: rgb(56, 139, 253),
};

pub const GITHUB_LIGHT: Theme = Theme {
    bg: rgb(255, 255, 255),
    panel: rgb(246, 248, 250),
    border: rgb(208, 215, 222),
    border_focus: rgb(9, 105, 218),
    text: rgb(31, 35, 40),
    muted: rgb(101, 109, 118),
    accent: rgb(9, 105, 218),
    green: rgb(26, 127, 55),
    red: rgb(207, 34, 46),
    yellow: rgb(154, 103, 0),
    purple: rgb(130, 80, 223),
    add_bg: rgb(230, 255, 236),
    del_bg: rgb(255, 235, 233),
    sel_bg: rgb(221, 244, 255),
    hunk: rgb(9, 105, 218),
};

pub const DRACULA: Theme = Theme {
    bg: rgb(40, 42, 54),
    panel: rgb(33, 34, 44),
    border: rgb(68, 71, 90),
    border_focus: rgb(189, 147, 249),
    text: rgb(248, 248, 242),
    muted: rgb(98, 114, 164),
    accent: rgb(189, 147, 249),
    green: rgb(80, 250, 123),
    red: rgb(255, 85, 85),
    yellow: rgb(241, 250, 140),
    purple: rgb(255, 121, 198),
    add_bg: rgb(34, 51, 31),
    del_bg: rgb(58, 31, 40),
    sel_bg: rgb(68, 71, 90),
    hunk: rgb(139, 233, 253),
};

pub const GRUVBOX_DARK: Theme = Theme {
    bg: rgb(40, 40, 40),
    panel: rgb(50, 48, 47),
    border: rgb(80, 73, 69),
    border_focus: rgb(131, 165, 152),
    text: rgb(235, 219, 178),
    muted: rgb(168, 153, 132),
    accent: rgb(131, 165, 152),
    green: rgb(184, 187, 38),
    red: rgb(251, 73, 52),
    yellow: rgb(250, 189, 47),
    purple: rgb(211, 134, 155),
    add_bg: rgb(38, 46, 31),
    del_bg: rgb(60, 31, 30),
    sel_bg: rgb(60, 56, 54),
    hunk: rgb(131, 165, 152),
};

pub const PRESETS: &[(&str, Theme)] = &[
    ("github-dark", GITHUB_DARK),
    ("github-light", GITHUB_LIGHT),
    ("dracula", DRACULA),
    ("gruvbox-dark", GRUVBOX_DARK),
];

static IDX: AtomicUsize = AtomicUsize::new(0);

pub fn cur() -> Theme {
    PRESETS[IDX.load(Ordering::Relaxed) % PRESETS.len()].1
}

pub fn name() -> &'static str {
    PRESETS[IDX.load(Ordering::Relaxed) % PRESETS.len()].0
}

/// Advance to the next theme and return its name.
pub fn cycle() -> &'static str {
    let n = PRESETS.len();
    let next = (IDX.load(Ordering::Relaxed) + 1) % n;
    IDX.store(next, Ordering::Relaxed);
    PRESETS[next].0
}

/// Set a theme by name (used at startup / by tests). Returns true if found.
pub fn set_by_name(name: &str) -> bool {
    if let Some(i) = PRESETS.iter().position(|(n, _)| *n == name) {
        IDX.store(i, Ordering::Relaxed);
        true
    } else {
        false
    }
}

// Accessors — every component uses these so a theme switch recolors everything.
pub fn bg() -> Color {
    cur().bg
}
pub fn panel() -> Color {
    cur().panel
}
pub fn border() -> Color {
    cur().border
}
pub fn border_focus() -> Color {
    cur().border_focus
}
pub fn text() -> Color {
    cur().text
}
pub fn muted() -> Color {
    cur().muted
}
pub fn accent() -> Color {
    cur().accent
}
pub fn green() -> Color {
    cur().green
}
pub fn red() -> Color {
    cur().red
}
pub fn yellow() -> Color {
    cur().yellow
}
pub fn purple() -> Color {
    cur().purple
}
pub fn add_bg() -> Color {
    cur().add_bg
}
pub fn del_bg() -> Color {
    cur().del_bg
}

/// Blend two colors (only meaningful for Rgb, which all presets use).
fn mix(a: Color, b: Color, t: f32) -> Color {
    match (a, b) {
        (Color::Rgb(ar, ag, ab), Color::Rgb(br, bg2, bb)) => {
            let m = |x: u8, y: u8| (x as f32 * (1.0 - t) + y as f32 * t).round() as u8;
            Color::Rgb(m(ar, br), m(ag, bg2), m(ab, bb))
        }
        _ => a,
    }
}

/// Stronger add/del backgrounds for the changed *words* inside a modified line
/// (word-diff), so the actual edit stands out from the surrounding unchanged text.
pub fn add_emph_bg() -> Color {
    mix(cur().add_bg, cur().green, 0.40)
}
pub fn del_emph_bg() -> Color {
    mix(cur().del_bg, cur().red, 0.40)
}
pub fn sel_bg() -> Color {
    cur().sel_bg
}
pub fn hunk() -> Color {
    cur().hunk
}
