//! Export a rendered ratatui Buffer to an SVG (for headless visual verification).

use ratatui::buffer::Buffer;
use ratatui::style::{Color, Modifier};

const CW: f32 = 8.4; // cell width px
const CH: f32 = 18.0; // cell height px

fn hex(c: Color, default: &str) -> String {
    match c {
        Color::Rgb(r, g, b) => format!("#{r:02x}{g:02x}{b:02x}"),
        Color::Black => "#0d1117".into(),
        Color::White => "#ffffff".into(),
        Color::Red => "#f85149".into(),
        Color::Green => "#3fb950".into(),
        Color::Yellow => "#d29922".into(),
        Color::Blue => "#58a6ff".into(),
        Color::Magenta => "#bc8cff".into(),
        Color::Cyan => "#39c5cf".into(),
        Color::Gray => "#8b949e".into(),
        Color::DarkGray => "#484f58".into(),
        Color::Reset => default.into(),
        _ => default.into(),
    }
}

fn esc(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

/// Render a buffer to an SVG string.
pub fn buffer_to_svg(buf: &Buffer) -> String {
    let w = buf.area.width;
    let h = buf.area.height;
    let px_w = (w as f32 * CW).ceil() as u32;
    let px_h = (h as f32 * CH).ceil() as u32;
    let root_bg = hex(crate::theme::cur().bg, "#0d1117");
    let mut s = String::new();
    s.push_str(&format!(
        "<svg xmlns='http://www.w3.org/2000/svg' width='{px_w}' height='{px_h}' \
         viewBox='0 0 {px_w} {px_h}' font-family='DejaVu Sans Mono, monospace' font-size='14'>"
    ));
    s.push_str(&format!(
        "<rect width='{px_w}' height='{px_h}' fill='{root_bg}'/>"
    ));

    // Backgrounds first.
    for y in 0..h {
        for x in 0..w {
            let cell = &buf[(x, y)];
            let bg = hex(cell.bg, &root_bg);
            if bg != root_bg {
                let px = x as f32 * CW;
                let py = y as f32 * CH;
                s.push_str(&format!(
                    "<rect x='{px:.1}' y='{py:.1}' width='{CW:.1}' height='{CH:.1}' fill='{bg}'/>"
                ));
            }
        }
    }
    // Glyphs.
    for y in 0..h {
        let mut x = 0u16;
        while x < w {
            let cell = &buf[(x, y)];
            let sym = cell.symbol();
            if !sym.trim().is_empty() {
                let fg = hex(cell.fg, "#c9d1d9");
                let px = x as f32 * CW;
                let py = y as f32 * CH + 14.0;
                let bold = if cell.modifier.contains(Modifier::BOLD) {
                    " font-weight='bold'"
                } else {
                    ""
                };
                s.push_str(&format!(
                    "<text x='{px:.1}' y='{py:.1}' fill='{fg}'{bold} xml:space='preserve'>{}</text>",
                    esc(sym)
                ));
            }
            x += 1;
        }
    }
    s.push_str("</svg>");
    s
}
