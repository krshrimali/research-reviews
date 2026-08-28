pub mod app;
pub mod config;
pub mod data;
pub mod diffview;
pub mod markdown;
pub mod perf;
pub mod publish;
pub mod syntax;
pub mod timeline;
pub mod tree;

/// Copy `text` to the system clipboard via the OSC52 terminal escape (works over SSH and
/// in most modern terminals; no external dependency).
pub fn osc52_copy(text: &str) {
    fn b64(data: &[u8]) -> String {
        const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        let mut out = String::new();
        for chunk in data.chunks(3) {
            let b0 = chunk[0];
            let b1 = *chunk.get(1).unwrap_or(&0);
            let b2 = *chunk.get(2).unwrap_or(&0);
            let n = ((b0 as u32) << 16) | ((b1 as u32) << 8) | (b2 as u32);
            out.push(T[((n >> 18) & 63) as usize] as char);
            out.push(T[((n >> 12) & 63) as usize] as char);
            out.push(if chunk.len() > 1 {
                T[((n >> 6) & 63) as usize] as char
            } else {
                '='
            });
            out.push(if chunk.len() > 2 {
                T[(n & 63) as usize] as char
            } else {
                '='
            });
        }
        out
    }
    use std::io::Write;
    let seq = format!("\x1b]52;c;{}\x07", b64(text.as_bytes()));
    let mut out = std::io::stdout();
    let _ = out.write_all(seq.as_bytes());
    let _ = out.flush();
}
pub mod picker;
pub mod screenshot;
pub mod theme;
pub mod ui;
pub mod view_export;
