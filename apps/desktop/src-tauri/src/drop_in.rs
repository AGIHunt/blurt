//! Things another app drops on the island hang as cards (docs/design/drag-drop.md §3; the Mac's DropIn + DropCards):
//!  • a picture (an image file, a browser's picture as data or as a virtual file) → a picture card, copied in: png /
//!    jpg as they are, anything else Windows can decode (gif, webp, bmp, heic, tiff) as a PNG, its long side at most
//!    6000 px; one that can't be decoded becomes a file card — never lost
//!  • any other file (a PDF, a video, a document) → a file card: its face is the file's thumbnail (else its icon) with
//!    its name on a dark band at the bottom (`compose_face`); the card refers to the file (shots.jsonl "ref") and never
//!    moves, writes or trashes it. A file in a temporary place (%TEMP%, a browser's download still being written, a cache) is copied into the
//!    batch first: it would be gone.
//!  • text, a link (an Internet shortcut's URL) → a text card
//!  • folders are not taken (the main window's sidebar opens them as projects)
//! They hang in Unassigned whatever the current project ("hang it" is what was asked); dropped on a project of the
//! island's drawer, they are filed straight into it.
//!
//! The pure parts (sorting what came, the Windows clipboard layouts read here, where a drop lands, when the catcher
//! shows and the drawer opens — `Watch` — and a file card's face) are tested below; reading the drag itself is
//! island_drop_win.rs.
#![cfg_attr(not(windows), allow(dead_code))]

use std::path::{Path, PathBuf};

use serde_json::{json, Value};

/// What a drag from another app carries.
#[derive(Debug, Default, Clone, PartialEq)]
pub struct DropIn {
    /// picture files
    pub images: Vec<PathBuf>,
    /// any other files
    pub files: Vec<PathBuf>,
    /// folders (not taken; counted for the summary)
    pub folders: usize,
    /// text or a link (only when nothing else came)
    pub text: Option<String>,
    /// pictures as PNG bytes (image data with no file: CF_DIB, "PNG"), read at the drop
    pub image_data: Vec<Vec<u8>>,
    /// pictures known only by the formats a drag offers (before the drop reads them)
    pub data_pictures: usize,
    /// a browser's virtual files (FileGroupDescriptorW): their names; `virtual_data` their bytes once dropped
    pub virtual_names: Vec<String>,
    pub virtual_data: Vec<Vec<u8>>,
}

impl DropIn {
    pub fn is_empty(&self) -> bool {
        self.images.is_empty()
            && self.files.is_empty()
            && self.text.is_none()
            && self.image_data.is_empty()
            && self.data_pictures == 0
            && self.virtual_names.is_empty()
    }

    /// How many pictures and other files, as the drawer's first row says it ("1 picture, 2 files").
    pub fn counts(&self) -> (usize, usize) {
        let vpics = self.virtual_names.iter().filter(|n| is_picture(Path::new(n))).count();
        let pictures = self.images.len() + self.image_data.len().max(self.data_pictures) + vpics;
        (pictures, self.files.len() + self.virtual_names.len() - vpics)
    }

    /// What the island's page shows while it is dragged over: `{pictures, files, text, folders}`.
    pub fn summary(&self) -> Value {
        let (pictures, files) = self.counts();
        json!({"pictures": pictures, "files": files, "text": self.text.is_some(), "folders": self.folders})
    }
}

/// Picture formats a card can be made of (png / jpg copied as they are, the rest decoded).
pub const PICTURES: &[&str] = &["png", "jpg", "jpeg", "gif", "webp", "bmp", "heic", "heif", "tif", "tiff"];

fn ext(p: &Path) -> String {
    p.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default()
}

pub fn is_picture(p: &Path) -> bool {
    PICTURES.contains(&ext(p).as_str())
}

/// A picture the card can keep as it is (the island and every app read it).
pub fn copies_as_is(p: &Path) -> bool {
    matches!(ext(p).as_str(), "png" | "jpg" | "jpeg")
}

/// Files dropped (CF_HDROP's paths), sorted: pictures, other files, folders; an Internet shortcut (.url, what a
/// browser's address bar drags) is its link. `is_dir` and `read` look at the disk (tests pass their own).
pub fn sort_paths(paths: &[PathBuf], is_dir: impl Fn(&Path) -> bool, read: impl Fn(&Path) -> Option<String>) -> DropIn {
    let mut d = DropIn::default();
    let mut links = Vec::new();
    for p in paths {
        if is_dir(p) {
            d.folders += 1;
        } else if ext(p) == "url" {
            if let Some(l) = read(p).as_deref().and_then(url_link) {
                links.push(l);
            }
        } else if is_picture(p) {
            d.images.push(p.clone());
        } else {
            d.files.push(p.clone());
        }
    }
    if !links.is_empty() {
        d.text = Some(links.join("\n"));
    }
    d
}

/// The link an Internet shortcut holds (`[InternetShortcut]` … `URL=…`).
pub fn url_link(contents: &str) -> Option<String> {
    contents
        .lines()
        .map(str::trim)
        .find_map(|l| l.strip_prefix("URL=").or_else(|| l.strip_prefix("url=")))
        .map(str::trim)
        .filter(|u| !u.is_empty())
        .map(str::to_owned)
}

/// Text that came with a drag: CRLF as LF, trimmed; None when nothing is left.
pub fn clean_text(s: &str) -> Option<String> {
    let t = s.trim_end_matches('\0').replace("\r\n", "\n").replace('\r', "\n");
    let t = t.trim();
    (!t.is_empty()).then(|| t.to_string())
}

/// The file names in a FILEGROUPDESCRIPTORW (a browser's picture, an Outlook attachment: files that exist only as
/// data): a u32 count, then FILEDESCRIPTORW records of 592 bytes, the name (WCHAR[260]) in their last 520.
pub fn file_group_names(bytes: &[u8]) -> Vec<String> {
    const REC: usize = 592;
    const NAME: usize = 72; // dwFlags 4, clsid 16, sizel 8, pointl 8, attributes 4, three FILETIMEs 24, size 8
    let Some(n) = bytes.get(..4).map(|b| u32::from_le_bytes(b.try_into().unwrap()) as usize) else { return vec![] };
    (0..n.min(256))
        .filter_map(|i| {
            let rec = bytes.get(4 + i * REC..4 + (i + 1) * REC)?;
            let units: Vec<u16> = rec[NAME..].chunks_exact(2).map(|c| u16::from_le_bytes([c[0], c[1]])).take_while(|u| *u != 0).collect();
            let name = String::from_utf16_lossy(&units);
            // a name, never a path the source made up
            let name = name.rsplit(['\\', '/']).next().unwrap_or("").trim().to_string();
            (!name.is_empty()).then_some(name)
        })
        .collect()
}

/// A CF_DIB (BITMAPINFOHEADER, then BI_RGB or BI_BITFIELDS pixels at 24 or 32 bits, bottom-up or top-down) as RGBA.
pub fn dib_rgba(dib: &[u8]) -> Option<(u32, u32, Vec<u8>)> {
    let u32_at = |o: usize| dib.get(o..o + 4).map(|b| u32::from_le_bytes(b.try_into().unwrap()));
    let i32_at = |o: usize| dib.get(o..o + 4).map(|b| i32::from_le_bytes(b.try_into().unwrap()));
    let header = u32_at(0)? as usize;
    let w = i32_at(4)?;
    let h = i32_at(8)?;
    let bits = u16::from_le_bytes(dib.get(14..16)?.try_into().ok()?);
    let compression = u32_at(16)?;
    if w <= 0 || h == 0 || !(bits == 24 || bits == 32) || !(compression == 0 || compression == 3) {
        return None;
    }
    let (w, top_down, h) = (w as usize, h < 0, h.unsigned_abs() as usize);
    // BI_BITFIELDS with a 40-byte header: three masks follow it (assumed the usual BGRA order)
    let start = header + if compression == 3 && header == 40 { 12 } else { 0 };
    let stride = (w * bits as usize / 8).div_ceil(4) * 4;
    let px = dib.get(start..start + stride * h)?;
    // an all-zero alpha channel means none (most CF_DIBs): opaque
    let alpha = bits == 32 && px.chunks_exact(4).any(|p| p[3] != 0);
    let mut out = Vec::with_capacity(w * h * 4);
    for y in 0..h {
        let row = &px[(if top_down { y } else { h - 1 - y }) * stride..][..stride];
        for x in 0..w {
            let p = &row[x * bits as usize / 8..];
            out.extend_from_slice(&[p[2], p[1], p[0], if alpha { p[3] } else { 255 }]);
        }
    }
    Some((w as u32, h as u32, out))
}

/// RGBA pixels as a PNG.
pub fn png(w: u32, h: u32, rgba: &[u8]) -> Option<Vec<u8>> {
    if w == 0 || h == 0 || rgba.len() != (w * h * 4) as usize {
        return None;
    }
    let mut out = Vec::new();
    {
        let mut e = ::png::Encoder::new(&mut out, w, h);
        e.set_color(::png::ColorType::Rgba);
        e.set_depth(::png::BitDepth::Eight);
        let mut wr = e.write_header().ok()?;
        wr.write_image_data(rgba).ok()?;
    }
    Some(out)
}

/// A file card's face when the platform draws none (not Windows): the light sheet and the band, no name.
pub fn plain_face() -> Vec<u8> {
    png(FACE.0, FACE.1, &compose_face(None, None)).unwrap_or_default()
}

/// A file a card can't just point at: the system's temporary places (items::is_temporary: %TEMP%, any user's
/// AppData\Local\Temp, /tmp…), the browsers' and Windows' caches, an app package's own folders, and a download
/// still being written.
pub fn is_temporary(p: &Path) -> bool {
    let s = p.to_string_lossy().replace('\\', "/").to_lowercase();
    crate::items::is_temporary(p, &std::env::temp_dir())
        || ["/inetcache/", "/appdata/local/packages/", "/appdata/local/microsoft/windows/temporary internet files/"].iter().any(|d| s.contains(d))
        || matches!(ext(p).as_str(), "crdownload" | "partial" | "part" | "download" | "tmp")
}

/// Where a drop lands, from the drawer's row under the pointer as the page last said it (`data-drop`): the island
/// itself or the first row ("hang") → hang as cards; a project or Unassigned → filed there; anything else (More…,
/// Organize — not offered for another app's things) takes nothing.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Landing {
    Hang,
    Project(String),
    Refuse,
}

pub fn landing(row: Option<&str>) -> Landing {
    match row {
        None | Some("") | Some("hang") => Landing::Hang,
        Some("inbox") => Landing::Project("inbox".into()),
        Some(r) => match r.strip_prefix("project:").filter(|p| !p.is_empty()) {
            Some(p) => Landing::Project(p.to_string()),
            None => Landing::Refuse,
        },
    }
}

/// What the platform does for `make_cards`: `decode` a picture a card can't keep as it is into PNG bytes (None: it
/// becomes a file card), `face` a file card's face as PNG bytes (its thumbnail or icon with its name on a band; None:
/// the plain sheet), `temporary` whether a file sits where it won't stay (`is_temporary`; tests pass their own: a
/// test's own folder is a temporary one).
pub struct Faces<'a> {
    pub decode: &'a dyn Fn(&Path) -> Option<Vec<u8>>,
    pub face: &'a dyn Fn(&Path) -> Option<Vec<u8>>,
    pub temporary: &'a dyn Fn(&Path) -> bool,
}

/// Hangs what `d` brought as cards in `session` (Unassigned's open batch), in the order they came: pictures, picture
/// data, virtual files, other files, text. Returns the cards made. Copies files: never on the UI thread.
pub fn make_cards(d: &DropIn, faces: &Faces, session: &Path) -> Vec<blurt_capture::overlay::Card> {
    use crate::capture;
    let mut made = Vec::new();
    let file_card = |p: &Path, temporary: bool| capture::add_file_card(session, &(faces.face)(p).unwrap_or_else(plain_face), p, temporary);
    let picture = |p: &Path, temporary: bool| {
        if copies_as_is(p) {
            capture::import_picture(session, None, p, "drop")
        } else {
            match (faces.decode)(p) {
                Some(png) => capture::add_png_card(session, &png, "drop"),
                // a picture nothing here can read (a HEIC without its codec, a broken file): a file card, never lost
                None => file_card(p, temporary || (faces.temporary)(p)),
            }
        }
    };
    for p in &d.images {
        made.extend(picture(p, false));
    }
    for png in &d.image_data {
        made.extend(capture::add_png_card(session, png, "drop"));
    }
    // a browser's virtual files: written to a folder of their own first, then taken as files in a temporary place
    // (a file card copies its file into the batch)
    if !d.virtual_data.is_empty() {
        let dir = std::env::temp_dir().join("blurt-drop").join(crate::projects::timestamp());
        let _ = std::fs::create_dir_all(&dir);
        for (name, bytes) in d.virtual_names.iter().zip(&d.virtual_data) {
            let p = dir.join(name);
            if std::fs::write(&p, bytes).is_err() {
                continue;
            }
            made.extend(if is_picture(&p) { picture(&p, true) } else { file_card(&p, true) });
        }
    }
    for p in &d.files {
        made.extend(file_card(p, (faces.temporary)(p)));
    }
    if let Some(t) = d.text.as_deref().and_then(clean_text) {
        made.extend(capture::add_text_card(session, &t));
    }
    made
}

/// Hang (`project` None) or file what came, then tell the island: the cards fly in (or are pulled into the project).
/// Blocks (copies, thumbnails): a worker thread.
pub fn hang(app: &tauri::AppHandle, d: &DropIn, project: Option<String>, faces: &Faces) {
    use tauri::Manager;
    let session = crate::projects::inbox_shots_session();
    let _ = app.asset_protocol_scope().allow_directory(&session, true);
    let made = make_cards(d, faces, &session);
    if made.is_empty() {
        return super::send(app, json!({"op": "toast", "kind": "line", "msg": "island.drop.nothing", "mark": "warning"}));
    }
    // one thing hung (not filed): its note is offered — the page opens the bubble beside the card without taking the
    // keyboard (`offerNote`; the Mac's DropCards → NoteBubble passive). Several: no bubble.
    let offer = offers_note(made.len(), project.is_some());
    for c in &made {
        super::send(app, json!({"op": "card", "card": c, "pull": project.is_some(), "offerNote": offer}));
    }
    crate::draglog::log(json!({"event": "drop_hang", "cards": made.len(), "project": project, "offer_note": offer}));
    match project {
        Some(p) => crate::capture::file_now(app, &session, made.iter().map(|c| u64::from(c.n)).collect(), &p, Some("user")),
        None => super::refresh_cards(app),
    }
}

/// After a drop on the island: a note is offered only for one thing hung under it (filed into a project: no card stays).
pub fn offers_note(made: usize, filed: bool) -> bool {
    made == 1 && !filed
}

// ------------------------------------------------------------------ Linux: a drop the island page took itself

/// What the island page read from a drop it took itself (Linux: WebKitGTK hands the island's own window the drag over
/// what it draws — the notch, the top strip, the open drawer; island.ts `linuxDrop`): file paths from the drop's
/// text/uri-list, pictures with no path as bytes (base64; a browser's image), the text when nothing else came.
#[derive(Debug, Default, serde::Deserialize)]
#[serde(default)]
pub struct PageDrop {
    pub paths: Vec<String>,
    pub pictures: Vec<PagePicture>,
    pub text: Option<String>,
    /// the drawer's row it was let go on (`data-drop`; none: the notch = hang)
    pub row: Option<String>,
}

#[derive(Debug, Default, serde::Deserialize)]
#[serde(default)]
pub struct PagePicture {
    pub name: String,
    pub data: String,
}

/// The page's drop as a DropIn (`is_dir`, `read` look at the disk): paths sorted as a drag's are (folders counted, not
/// taken), pictures with no path as virtual files (named, written to a temporary folder at hang time and copied in),
/// text only when nothing else came. Relative paths and empty names are dropped.
pub fn page_drop(p: &PageDrop, is_dir: impl Fn(&Path) -> bool, read: impl Fn(&Path) -> Option<String>) -> DropIn {
    let paths: Vec<PathBuf> = p.paths.iter().map(PathBuf::from).filter(|x| x.is_absolute()).collect();
    let mut d = sort_paths(&paths, is_dir, read);
    for pic in &p.pictures {
        let name = Path::new(&pic.name).file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        let Some(bytes) = base64_decode(&pic.data).filter(|b| !b.is_empty()) else { continue };
        d.virtual_names.push(if name.is_empty() { "picture.png".into() } else { name });
        d.virtual_data.push(bytes);
    }
    if d.is_empty() && d.folders == 0 {
        d.text = p.text.as_deref().and_then(clean_text);
    }
    d
}

/// Standard base64 (padding optional, whitespace ignored); a `data:…;base64,` prefix is skipped. None when malformed.
pub fn base64_decode(s: &str) -> Option<Vec<u8>> {
    use base64::Engine;
    let s = s.split_once(";base64,").map_or(s, |(_, b)| b);
    let clean: String = s.chars().filter(|c| !c.is_whitespace()).collect();
    base64::engine::general_purpose::STANDARD_NO_PAD.decode(clean.trim_end_matches('=')).ok()
}

// ------------------------------------------------------------------ the clipboard (Ctrl+V in the main window)

/// What the system clipboard held, as read (Windows: OLE's clipboard data object; Linux: arboard over XWayland's).
#[derive(Debug, Default, Clone)]
pub struct ClipRead {
    /// files copied (Explorer, Files: CF_HDROP / text/uri-list)
    pub paths: Vec<PathBuf>,
    /// a picture as PNG (a screenshot, a browser's Copy Image)
    pub png: Option<Vec<u8>>,
    pub text: Option<String>,
    /// a document's copy: rich text (Word, Excel, LibreOffice), which also carries a picture of itself
    pub rich: bool,
    /// Blurt itself put it there (a card's picture copied on the island): never pasted back as a new file
    pub ours: bool,
}

/// What a paste brings (the Mac's DropIn.clipboard): pictures (copied in), other files (referenced), a picture as
/// data (written to a temporary PNG by the caller), or the text.
#[derive(Debug, Default, Clone, PartialEq)]
pub struct Clip {
    pub images: Vec<PathBuf>,
    pub files: Vec<PathBuf>,
    pub png: Option<Vec<u8>>,
    pub text: Option<String>,
}

/// The paste's rules: Blurt's own copies are only their text; a document's copy (rich text) is its text, never the
/// picture of itself it carries; files in Blurt's own folders (`mine`: a frame, a card) are never pasted back as
/// duplicates; folders aren't taken; a picture as data only when no file came; the text only when nothing else did.
pub fn clipboard_pick(r: ClipRead, is_dir: impl Fn(&Path) -> bool, mine: impl Fn(&Path) -> bool) -> Clip {
    let text = r.text.as_deref().and_then(clean_text);
    let mut c = Clip::default();
    if !r.ours {
        for p in r.paths.iter().filter(|p| !is_dir(p) && !mine(p)) {
            if is_picture(p) {
                c.images.push(p.clone());
            } else {
                c.files.push(p.clone());
            }
        }
        if r.paths.is_empty() && !(r.rich && text.is_some()) {
            c.png = r.png.filter(|b| !b.is_empty());
        }
    }
    if c.images.is_empty() && c.files.is_empty() && c.png.is_none() {
        c.text = text;
    }
    c
}

/// A path in Blurt's own folders: its data (`$BLURT_HOME`, any store's `.blurt`), the workspace's inbox.
pub fn is_mine(p: &Path) -> bool {
    let norm = |p: &Path| p.to_string_lossy().replace('\\', "/").to_lowercase();
    let s = norm(p);
    let under = |root: &Path| {
        let r = norm(root);
        let r = r.trim_end_matches('/');
        !r.is_empty() && s.starts_with(&format!("{r}/"))
    };
    s.contains("/.blurt/") || under(&crate::paths::blurt_home()) || under(&crate::paths::inbox_store())
}

/// The last picture Blurt put on the clipboard (a card's copy): the clipboard's sequence number right after (Windows;
/// 0 elsewhere) and the picture's size. A paste of exactly that is Blurt's own.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Ours {
    pub seq: u32,
    pub size: (u32, u32),
}

pub static OURS: std::sync::Mutex<Option<Ours>> = std::sync::Mutex::new(None);

/// A card's picture was just copied (island.rs): remember it.
pub fn mark_ours(seq: u32, size: (u32, u32)) {
    *OURS.lock().unwrap() = Some(Ours { seq, size });
}

/// Is what the clipboard holds now (its sequence number, its picture's size) Blurt's own last copy? Windows: the
/// sequence number says it exactly (any later copy changes it). Elsewhere there is none (0): the picture's size.
pub fn is_ours(last: Option<Ours>, seq: u32, size: Option<(u32, u32)>) -> bool {
    match last {
        Some(o) if o.seq != 0 || seq != 0 => o.seq == seq,
        Some(o) => size == Some(o.size),
        None => false,
    }
}

// ------------------------------------------------------------------ a file card's face

/// A file card's face (the Mac's DropCards.render, 2x of 150 × 120): a light sheet, the thumbnail (or icon) fitted in
/// it, the file's name on a dark band at the bottom.
pub const FACE: (u32, u32) = (300, 240);
/// The name band's height (px of the face).
pub const BAND: u32 = 46;
/// The box the thumbnail is fitted in, under the band's top: 16 px in from the sides, 12 px from the top and the band.
pub const THUMB: (u32, u32) = (FACE.0 - 32, FACE.1 - BAND - 24);

/// BGRA pixels a Windows bitmap gave (a thumbnail, an icon): whether it has alpha at all (an all-zero alpha channel is
/// none: an opaque thumbnail) and whether its colours are premultiplied (no channel above its alpha — what
/// AlphaBlend-ready bitmaps hold; an icon may come straight).
pub fn alpha_kind(bgra: &[u8]) -> (bool, bool) {
    let any = bgra.chunks_exact(4).any(|p| p[3] != 0);
    let straight = any && bgra.chunks_exact(4).any(|p| p[0] > p[3] || p[1] > p[3] || p[2] > p[3]);
    (any, !straight)
}

/// The face: `thumb` (BGRA, top-down, `w` × `h`, at most THUMB) centred in its box over the light sheet; `band` (BGR(A),
/// top-down, FACE.0 × BAND: the name as GDI drew it, white on dark) at the bottom. RGBA out, opaque.
pub fn compose_face(thumb: Option<(u32, u32, &[u8])>, band: Option<&[u8]>) -> Vec<u8> {
    let (fw, fh) = (FACE.0 as usize, FACE.1 as usize);
    let mut out = [242u8, 241, 238, 255].repeat(fw * fh);
    if let Some((w, h, px)) = thumb.filter(|(w, h, px)| *w > 0 && *h > 0 && px.len() >= (*w * *h * 4) as usize) {
        let (w, h) = (w.min(THUMB.0) as usize, h.min(THUMB.1) as usize);
        let stride = thumb.map(|t| t.0 as usize).unwrap_or(w) * 4;
        let (ox, oy) = (16 + (THUMB.0 as usize - w) / 2, 12 + (THUMB.1 as usize - h) / 2);
        let (alpha, premultiplied) = alpha_kind(px);
        for y in 0..h {
            for x in 0..w {
                let s = &px[y * stride + x * 4..][..4];
                let d = &mut out[((oy + y) * fw + ox + x) * 4..][..4];
                let a = if alpha { s[3] as u32 } else { 255 };
                for (c, src) in [(0, s[2]), (1, s[1]), (2, s[0])] {
                    let src = if premultiplied || !alpha { src as u32 } else { src as u32 * a / 255 };
                    d[c] = (src + d[c] as u32 * (255 - a) / 255).min(255) as u8;
                }
            }
        }
    }
    let top = fh - BAND as usize;
    match band.filter(|b| b.len() >= fw * BAND as usize * 4) {
        Some(b) => {
            for (i, p) in b.chunks_exact(4).take(fw * BAND as usize).enumerate() {
                out[(top * fw + i) * 4..][..4].copy_from_slice(&[p[2], p[1], p[0], 255]);
            }
        }
        // no text drawn (not Windows): the band alone
        None => out[top * fw * 4..].chunks_exact_mut(4).for_each(|p| p.copy_from_slice(&BAND_RGB)),
    }
    out
}

/// The band's colour (the Mac's 12 % grey at 92 % over the light sheet).
pub const BAND_RGB: [u8; 4] = [30, 30, 30, 255];

// ------------------------------------------------------------------ when the catcher shows, when the drawer opens

/// A rectangle on the screen (physical px), edges inclusive-exclusive.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Zone {
    pub l: i32,
    pub t: i32,
    pub r: i32,
    pub b: i32,
}

impl Zone {
    pub fn of(r: blurt_capture::Region) -> Zone {
        Zone { l: r.x, t: r.y, r: r.x + r.w as i32, b: r.y + r.h as i32 }
    }
    pub fn grow(self, m: i32) -> Zone {
        Zone { l: self.l - m, t: self.t - m, r: self.r + m, b: self.b + m }
    }
    pub fn union(self, o: Zone) -> Zone {
        Zone { l: self.l.min(o.l), t: self.t.min(o.t), r: self.r.max(o.r), b: self.b.max(o.b) }
    }
    pub fn contains(self, (x, y): (i32, i32)) -> bool {
        x >= self.l && x < self.r && y >= self.t && y < self.b
    }
}

/// What the island page last said about itself, for the catcher (another thread): where the notch is and the open
/// drawer (screen px), the window's origin and scale (the pointer in the page's CSS px), the drawer's row under another
/// app's drag (`data-drop`; the last one stays while the pointer is between rows, as the Mac's externalTarget).
#[derive(Debug, Clone)]
pub struct Report {
    pub notch: Option<Zone>,
    pub drawer: Option<Zone>,
    pub origin: (i32, i32),
    pub scale: f64,
    pub row: Option<String>,
}

pub static REPORT: std::sync::Mutex<Report> = std::sync::Mutex::new(Report { notch: None, drawer: None, origin: (0, 0), scale: 1.0, row: None });

impl Report {
    /// A screen point (physical px) in the page's CSS px.
    pub fn to_css(&self, (x, y): (i32, i32)) -> (f64, f64) {
        let k = if self.scale > 0.0 { self.scale } else { 1.0 };
        ((x - self.origin.0) as f64 / k, (y - self.origin.1) as f64 / k)
    }
}

/// The page's `drop.zone` (`{notch, drawer}`: CSS rects, drawer null while closed): kept in screen px.
pub fn zone_reported(app: &tauri::AppHandle, v: &Value) {
    let Some(i) = super::island(app) else { return };
    let at = i.rect();
    let scale = i.window().scale_factor().unwrap_or(1.0);
    let notch = super::css_to_screen(app, &v["notch"]).map(Zone::of);
    let drawer = v.get("drawer").filter(|d| !d.is_null()).and_then(|d| super::css_to_screen(app, d)).map(Zone::of);
    let mut r = REPORT.lock().unwrap();
    (r.notch, r.drawer, r.origin, r.scale) = (notch, drawer, (at.x, at.y), scale);
}

/// The page's `ext.row`: the drawer's row now under another app's drag (none: kept, see Report).
pub fn row_reported(v: &Value) {
    if let Some(row) = v["row"].as_str().filter(|r| !r.is_empty()) {
        REPORT.lock().unwrap().row = Some(row.to_string());
    }
}

/// Another app's drag resting on the notch this long opens the drawer (one only passing by doesn't).
pub const DWELL: f64 = 0.25;
/// Off the catcher this long: the drawer closes.
pub const LEAVE: f64 = 0.3;
/// The button comes up before the drop reaches us (OLE delivers it from the source's own loop): the catcher stays
/// this long after mouse-up for it.
pub const GRACE: f64 = 0.5;
/// The catcher shown, the pointer moved over it, and still no drag entered it this long after: the button is held for
/// something else (a browser's tab dragged along its strip, a window moved) — it goes for the rest of that press, so it
/// never sits in that app's way.
pub const DUD: f64 = 0.2;
/// Around the notch (logical px) where another app's drag brings the catcher; around the open drawer.
pub const NEAR: f64 = 40.0;
pub const NEAR_OPEN: f64 = 24.0;

/// What the watcher sees on each tick (~30 Hz).
pub struct Sense {
    /// seconds, any clock
    pub now: f64,
    /// the primary button is down (GetAsyncKeyState, swapped buttons respected)
    pub down: bool,
    /// the pointer (physical px)
    pub pt: (i32, i32),
    /// where the notch is (the page's report; where it would be while hidden at rest)
    pub notch: Option<Zone>,
    /// the open drawer (the island's whole box while it is open)
    pub drawer: Option<Zone>,
    /// how far the pointer must move from the press for a drag (SM_CXDRAG)
    pub slop: i32,
    /// the island's screen scale (margins are logical px)
    pub scale: f64,
}

/// What the watcher wants done.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Do {
    /// the catcher over this rect (shown, or moved)
    Show(Zone),
    Hide,
    /// the drawer opens (the page: Hang, the projects, Unassigned)
    Open,
    /// the drag left the notch: the drawer closes, the drag may still come back
    Close,
    /// the drag is over (dropped, cancelled, mouse-up past the grace): everything goes
    End,
}

#[derive(Debug, Clone, Copy)]
struct Press {
    at: (i32, i32),
    /// Blurt's own window was under it, or Blurt's own card drag is under way: never another app's drag
    ours: bool,
    moved: bool,
    /// the catcher was in the way of something that isn't a drag (DUD): not again this press
    dud: bool,
}

/// Another app's drag over the notch, the Mac's Island.watchDrags on Windows' terms: a drag no app announces, seen as
/// the button held down with the pointer moved since the press, near the notch, from a press that wasn't on Blurt;
/// confirmed only by OLE itself entering the catcher (`entered`). Pure: the clock and the pointer come in `Sense`.
#[derive(Debug, Default)]
pub struct Watch {
    press: Option<Press>,
    shown: Option<Zone>,
    /// a drag the island takes is over the catcher, since then
    over: Option<f64>,
    /// any drag (taken or not) entered the catcher this press: it is OLE's
    entered: bool,
    /// the pointer first moved while over the shown catcher (for DUD)
    moved_over: Option<f64>,
    shown_at: (i32, i32),
    left_at: Option<f64>,
    up_at: Option<f64>,
    open: bool,
}

impl Watch {
    pub fn is_open(&self) -> bool {
        self.open
    }

    fn area(&self, s: &Sense) -> Option<Zone> {
        let near = s.notch.map(|z| z.grow((NEAR * s.scale).round() as i32));
        let drawer = if self.open { s.drawer.map(|z| z.grow((NEAR_OPEN * s.scale).round() as i32)) } else { None };
        match (near, drawer) {
            (Some(a), Some(b)) => Some(a.union(b)),
            (a, b) => a.or(b),
        }
    }

    /// One tick. `ours` is asked once per press: whether it was on Blurt's own window.
    pub fn tick(&mut self, s: &Sense, ours: impl FnOnce() -> bool) -> Vec<Do> {
        if !s.down {
            self.press = None;
            if self.shown.is_some() || self.open || self.over.is_some() {
                let up = *self.up_at.get_or_insert(s.now);
                if s.now - up >= GRACE {
                    return self.end();
                }
            }
            return vec![];
        }
        self.up_at = None;
        let press = self.press.get_or_insert_with(|| Press { at: s.pt, ours: ours(), moved: false, dud: false });
        if press.ours {
            return if self.shown.is_some() { self.end() } else { vec![] };
        }
        if (s.pt.0 - press.at.0).abs() > s.slop || (s.pt.1 - press.at.1).abs() > s.slop {
            press.moved = true;
        }
        let (moved, dud) = (press.moved, press.dud);
        let mut out = vec![];
        if self.left_at.is_some_and(|l| s.now - l >= LEAVE) {
            self.left_at = None;
            self.over = None;
            if self.open {
                self.open = false;
                out.push(Do::Close);
            }
        }
        if let Some(t) = self.over {
            if !self.open && s.now - t >= DWELL {
                self.open = true;
                out.push(Do::Open);
            }
        }
        // shown, moved over, and OLE never entered it: not a drag of the kind that can drop here
        if let Some(sz) = self.shown {
            if !self.entered && sz.contains(s.pt) && s.pt != self.shown_at {
                let since = *self.moved_over.get_or_insert(s.now);
                if s.now - since >= DUD {
                    if let Some(p) = self.press.as_mut() {
                        p.dud = true;
                    }
                    self.shown = None;
                    self.moved_over = None;
                    out.push(Do::Hide);
                    return out;
                }
            }
        }
        match self.area(s) {
            None => {
                if self.shown.take().is_some() {
                    out.push(Do::Hide);
                }
            }
            Some(a) => {
                let near = a.contains(s.pt);
                match self.shown {
                    None if moved && near && !dud => {
                        self.shown = Some(a);
                        self.shown_at = s.pt;
                        out.push(Do::Show(a));
                    }
                    None => {}
                    // away from the notch with nothing over it: out of other apps' way
                    Some(_) if !near && self.over.is_none() && !self.open => {
                        self.shown = None;
                        self.moved_over = None;
                        out.push(Do::Hide);
                    }
                    Some(z) if z != a => {
                        self.shown = Some(a);
                        out.push(Do::Show(a));
                    }
                    Some(_) => {}
                }
            }
        }
        out
    }

    /// OLE's DragEnter on the catcher: `takes` whether it carries anything the island takes (not Blurt's own).
    pub fn entered(&mut self, now: f64, takes: bool) {
        self.entered = true;
        self.left_at = None;
        if takes && self.over.is_none() {
            self.over = Some(now);
        }
    }

    /// OLE's DragLeave.
    pub fn left(&mut self, now: f64) {
        if self.over.is_some() {
            self.left_at = Some(now);
        }
    }

    /// The drop arrived (or the drag can't go on): everything goes.
    pub fn end(&mut self) -> Vec<Do> {
        let mut out = vec![];
        if self.shown.take().is_some() {
            out.push(Do::Hide);
        }
        if self.open || self.over.is_some() || self.entered || !out.is_empty() {
            out.push(Do::End);
        }
        let press = self.press.map(|p| Press { dud: true, ..p });
        *self = Watch { press, ..Default::default() };
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dropped_files_sort_into_pictures_files_and_links() {
        let paths: Vec<PathBuf> = [r"C:\a\shot.PNG", r"C:\a\spec.pdf", r"C:\code\repo", r"C:\a\pic.heic", r"C:\a\Site.url", r"C:\a\clip.mp4"].iter().map(PathBuf::from).collect();
        let d = sort_paths(&paths, |p| p.to_string_lossy().ends_with("repo"), |_| Some("[InternetShortcut]\r\nURL=https://example.com/a\r\n".into()));
        assert_eq!(d.images, [PathBuf::from(r"C:\a\shot.PNG"), PathBuf::from(r"C:\a\pic.heic")]);
        assert_eq!(d.files, [PathBuf::from(r"C:\a\spec.pdf"), PathBuf::from(r"C:\a\clip.mp4")]);
        assert_eq!(d.folders, 1);
        assert_eq!(d.text.as_deref(), Some("https://example.com/a"));
        assert_eq!(d.counts(), (2, 2));
        assert_eq!(d.summary(), json!({"pictures": 2, "files": 2, "text": true, "folders": 1}));
        assert!(copies_as_is(Path::new("a.JPG")) && !copies_as_is(Path::new("a.webp")) && is_picture(Path::new("a.webp")));
        // only folders: nothing to hang
        assert!(sort_paths(&[PathBuf::from("/x")], |_| true, |_| None).is_empty());
    }

    #[test]
    fn a_drag_known_only_by_its_formats_counts_its_pictures() {
        let d = DropIn { data_pictures: 1, virtual_names: vec!["photo.jpg".into(), "notes.txt".into()], ..Default::default() };
        assert!(!d.is_empty());
        assert_eq!(d.counts(), (2, 1));
        // once dropped, the data read counts instead of the formats offered
        let read = DropIn { image_data: vec![vec![1], vec![2]], data_pictures: 1, ..Default::default() };
        assert_eq!(read.counts(), (2, 0));
        assert!(DropIn::default().is_empty());
    }

    #[test]
    fn links_and_text() {
        assert_eq!(url_link("[InternetShortcut]\nIDList=\nURL= https://a.test/x?y=1 \n"), Some("https://a.test/x?y=1".into()));
        assert_eq!(url_link("[InternetShortcut]\n"), None);
        assert_eq!(clean_text("  line one\r\nline two\0"), Some("line one\nline two".into()));
        assert_eq!(clean_text(" \r\n\0"), None);
    }

    #[test]
    fn a_browsers_virtual_files_by_name() {
        let mut b = 2u32.to_le_bytes().to_vec();
        for name in [r"photo 1.jpg", r"..\..\evil\run.bat"] {
            let mut rec = vec![0u8; 592];
            for (i, u) in name.encode_utf16().enumerate() {
                rec[72 + i * 2..74 + i * 2].copy_from_slice(&u.to_le_bytes());
            }
            b.extend(rec);
        }
        assert_eq!(file_group_names(&b), ["photo 1.jpg", "run.bat"]);
        assert!(file_group_names(&[1, 0]).is_empty());
        assert!(file_group_names(&5u32.to_le_bytes()).is_empty()); // says 5, holds none
    }

    #[test]
    fn a_dib_becomes_rgba() {
        // 2×2, 24 bits, bottom-up: rows padded to 8 bytes; bottom row blue, red; top row green, white
        let mut dib = vec![0u8; 40];
        dib[0..4].copy_from_slice(&40u32.to_le_bytes());
        dib[4..8].copy_from_slice(&2i32.to_le_bytes());
        dib[8..12].copy_from_slice(&2i32.to_le_bytes());
        dib[12..14].copy_from_slice(&1u16.to_le_bytes());
        dib[14..16].copy_from_slice(&24u16.to_le_bytes());
        dib.extend([255, 0, 0, 0, 0, 255, 0, 0]); // bottom: blue, red (BGR)
        dib.extend([0, 255, 0, 255, 255, 255, 0, 0]); // top: green, white
        let (w, h, px) = dib_rgba(&dib).unwrap();
        assert_eq!((w, h), (2, 2));
        assert_eq!(px, [0, 255, 0, 255, 255, 255, 255, 255, 0, 0, 255, 255, 255, 0, 0, 255]);
        let encoded = png(w, h, &px).unwrap();
        assert_eq!(&encoded[1..4], b"PNG");
        // 32 bits top-down with no alpha set: opaque; with alpha: kept
        let mut d32 = dib[..40].to_vec();
        d32[8..12].copy_from_slice(&(-1i32).to_le_bytes());
        d32[14..16].copy_from_slice(&32u16.to_le_bytes());
        d32.extend([1, 2, 3, 0, 4, 5, 6, 0]);
        assert_eq!(dib_rgba(&d32).unwrap().2, [3, 2, 1, 255, 6, 5, 4, 255]);
        d32[47] = 128;
        assert_eq!(dib_rgba(&d32).unwrap().2[4..], [6, 5, 4, 128]);
        // compressed, 8-bit, short: refused
        let mut bad = dib.clone();
        bad[14..16].copy_from_slice(&8u16.to_le_bytes());
        assert!(dib_rgba(&bad).is_none());
        assert!(dib_rgba(&dib[..45]).is_none());
        assert!(png(1, 1, &[0; 3]).is_none());
        assert!(!plain_face().is_empty());
    }

    #[test]
    fn files_that_wont_stay_are_copied() {
        assert!(is_temporary(Path::new(r"C:\Users\Ana\AppData\Local\Temp\x.pdf")));
        assert!(is_temporary(Path::new(r"C:\Users\Ana\AppData\Local\Microsoft\Windows\INetCache\IE\a.png")));
        assert!(is_temporary(Path::new(r"C:\Users\Ana\Downloads\big.mp4.crdownload")));
        assert!(is_temporary(Path::new(r"C:\Users\Ana\AppData\Local\Packages\Some.App\LocalState\f.docx")));
        assert!(!is_temporary(Path::new(r"C:\Users\Ana\Documents\spec.pdf")));
        assert!(!is_temporary(Path::new(r"C:\Users\Ana\Downloads\spec.pdf")));
    }

    #[test]
    fn a_file_cards_face() {
        // a 2×1 thumbnail: opaque red, then nothing (alpha 0) — centred in its box, the band at the bottom
        let thumb = [0u8, 0, 255, 255, 0, 0, 0, 0];
        let band = vec![200u8; (FACE.0 * BAND * 4) as usize];
        let px = compose_face(Some((2, 1, &thumb)), Some(&band));
        assert_eq!(px.len(), (FACE.0 * FACE.1 * 4) as usize);
        let at = |x: u32, y: u32| px[((y * FACE.0 + x) * 4) as usize..][..4].to_vec();
        let (ox, oy) = (16 + (THUMB.0 - 2) / 2, 12 + (THUMB.1 - 1) / 2);
        assert_eq!(at(ox, oy), [255, 0, 0, 255]);
        assert_eq!(at(ox + 1, oy), [242, 241, 238, 255]); // transparent: the sheet shows
        assert_eq!(at(0, 0), [242, 241, 238, 255]);
        assert_eq!(at(10, FACE.1 - 1), [200, 200, 200, 255]);
        // no band drawn (no GDI): the dark band alone; no thumbnail: the sheet
        let plain = compose_face(None, None);
        assert_eq!(plain[((FACE.1 - 1) * FACE.0 * 4) as usize..][..4], BAND_RGB);
        assert_eq!(&png(FACE.0, FACE.1, &plain).unwrap()[1..4], b"PNG");
        // straight alpha (an icon) is weighted; premultiplied passes as it is; none at all is opaque
        assert_eq!(alpha_kind(&[255, 0, 0, 128]), (true, false));
        assert_eq!(alpha_kind(&[100, 0, 0, 128]), (true, true));
        assert_eq!(alpha_kind(&[9, 9, 9, 0]), (false, true));
        let half = compose_face(Some((1, 1, &[0, 0, 255, 128])), None);
        let (ox, oy) = (16 + (THUMB.0 - 1) / 2, 12 + (THUMB.1 - 1) / 2);
        assert_eq!(half[((oy * FACE.0 + ox) * 4) as usize..][..3], [248, 120, 118]);
    }

    fn sense(now: f64, down: bool, pt: (i32, i32)) -> Sense {
        Sense { now, down, pt, notch: Some(Zone { l: 900, t: 6, r: 1020, b: 36 }), drawer: Some(Zone { l: 720, t: 6, r: 1200, b: 300 }), slop: 4, scale: 1.0 }
    }

    #[test]
    fn another_apps_drag_brings_the_catcher_then_the_drawer() {
        let mut w = Watch::default();
        // pressed far away (a file in Explorer), dragged up to the notch
        assert!(w.tick(&sense(0.0, true, (500, 700)), || false).is_empty());
        assert!(w.tick(&sense(0.1, true, (800, 300)), || false).is_empty()); // moved, not near yet
        let near = Zone { l: 860, t: -34, r: 1060, b: 76 };
        assert_eq!(w.tick(&sense(0.2, true, (950, 60)), || false), [Do::Show(near)]);
        // OLE enters it with something the island takes; 250 ms later the drawer opens and the catcher grows over it
        w.entered(0.25, true);
        assert!(w.tick(&sense(0.4, true, (950, 30)), || false).is_empty());
        let grown = Zone { l: 696, t: -34, r: 1224, b: 324 };
        assert_eq!(w.tick(&sense(0.5, true, (950, 30)), || false), [Do::Open, Do::Show(grown)]);
        assert!(w.is_open());
        // the drop: everything goes
        assert_eq!(w.end(), [Do::Hide, Do::End]);
        assert!(w.tick(&sense(0.6, false, (950, 30)), || false).is_empty());
    }

    #[test]
    fn the_drawer_closes_off_the_notch_and_the_catcher_outlasts_mouse_up() {
        let mut w = Watch::default();
        w.tick(&sense(0.0, true, (500, 700)), || false);
        assert!(matches!(w.tick(&sense(0.1, true, (950, 20)), || false)[..], [Do::Show(_)]));
        w.entered(0.1, true);
        w.tick(&sense(0.4, true, (950, 20)), || false);
        assert!(w.is_open());
        // left (DragLeave) and away for 300 ms: closed, then the catcher shrinks back to the notch and goes when far
        w.left(0.5);
        assert!(w.tick(&sense(0.6, true, (950, 200)), || false).is_empty());
        assert_eq!(w.tick(&sense(0.85, true, (950, 600)), || false), [Do::Close, Do::Hide]);
        // back again: shown again (OLE will enter it again)
        assert!(matches!(w.tick(&sense(0.9, true, (950, 20)), || false)[..], [Do::Show(_)]));
        w.entered(0.95, true);
        // mouse-up: the drop may still come, half a second
        assert!(w.tick(&sense(1.0, false, (950, 20)), || false).is_empty());
        assert!(w.tick(&sense(1.4, false, (950, 20)), || false).is_empty());
        assert_eq!(w.tick(&sense(1.5, false, (950, 20)), || false), [Do::Hide, Do::End]);
    }

    #[test]
    fn blurts_own_drags_and_things_that_arent_drags_are_left_alone() {
        // pressed on Blurt (a card under the island, a row of the main window): never
        let mut w = Watch::default();
        w.tick(&sense(0.0, true, (950, 120)), || true);
        assert!(w.tick(&sense(0.2, true, (950, 20)), || panic!("asked once")).is_empty());
        // a press that never moved past the slop: a click near the notch, not a drag
        let mut w = Watch::default();
        w.tick(&sense(0.0, true, (950, 70)), || false);
        assert!(w.tick(&sense(0.1, true, (952, 68)), || false).is_empty());
        // a browser's tab dragged along its strip: the catcher shows, the pointer moves over it, OLE never enters — it
        // goes after 200 ms and doesn't come back this press
        let mut w = Watch::default();
        w.tick(&sense(0.0, true, (500, 20)), || false);
        assert!(matches!(w.tick(&sense(0.1, true, (930, 20)), || false)[..], [Do::Show(_)]));
        assert!(w.tick(&sense(0.15, true, (940, 20)), || false).is_empty());
        assert_eq!(w.tick(&sense(0.36, true, (950, 20)), || false), [Do::Hide]);
        assert!(w.tick(&sense(0.5, true, (960, 20)), || false).is_empty());
        // a drag that doesn't carry what the island takes (OLE enters, `takes` false): no drawer, ever
        let mut w = Watch::default();
        w.tick(&sense(0.0, true, (500, 700)), || false);
        w.tick(&sense(0.1, true, (950, 20)), || false);
        w.entered(0.1, false);
        assert!(w.tick(&sense(0.6, true, (951, 20)), || false).is_empty());
        assert!(!w.is_open());
        // no notch known (no island page yet): nothing shows
        let mut w = Watch::default();
        let mut s = sense(0.0, true, (500, 700));
        s.notch = None;
        w.tick(&s, || false);
        s.pt = (950, 20);
        assert!(w.tick(&s, || false).is_empty());
    }

    #[test]
    fn where_a_drop_lands() {
        assert_eq!(landing(None), Landing::Hang);
        assert_eq!(landing(Some("hang")), Landing::Hang);
        assert_eq!(landing(Some("inbox")), Landing::Project("inbox".into()));
        assert_eq!(landing(Some("project:p1")), Landing::Project("p1".into()));
        for r in ["organize", "more", "project:", "locate"] {
            assert_eq!(landing(Some(r)), Landing::Refuse, "{r}");
        }
    }

    #[test]
    fn cards_hang_in_the_order_they_came() {
        let dir = tempfile::tempdir().unwrap();
        let src = tempfile::tempdir().unwrap();
        let (pic, gif, pdf) = (src.path().join("a.png"), src.path().join("b.gif"), src.path().join("c.pdf"));
        for p in [&pic, &gif, &pdf] {
            std::fs::write(p, b"x").unwrap();
        }
        let tmp = src.path().join("cache");
        std::fs::create_dir_all(&tmp).unwrap();
        let cached = tmp.join("recv.docx");
        std::fs::write(&cached, b"y").unwrap();
        let session = dir.path().join("s-shots");
        let d = DropIn {
            images: vec![pic.clone(), gif.clone()],
            files: vec![pdf.clone(), cached.clone()],
            text: Some(" a note \r\n".into()),
            ..Default::default()
        };
        // nothing decodes the gif here: it becomes a file card, never lost; "cache" is the temporary place
        let faces = Faces { decode: &|_| None, face: &|_| None, temporary: &|p: &Path| p.starts_with(&tmp) };
        let made = make_cards(&d, &faces, &session);
        assert_eq!(made.iter().map(|c| c.n).collect::<Vec<_>>(), [1, 2, 3, 4, 5]);
        assert_eq!(made[0].file.as_deref(), Some("shots/001.png"));
        assert!(made[0].reference.is_none());
        assert_eq!(made[1].reference.as_deref(), Some(gif.to_string_lossy().as_ref()));
        assert_eq!(made[2].reference.as_deref(), Some(pdf.to_string_lossy().as_ref()));
        // the file in a temporary place: copied into the batch (files/NNN/), the card refers to the copy
        let copy = session.join("files").join("004").join("recv.docx");
        assert_eq!(made[3].reference.as_deref(), Some(copy.to_string_lossy().as_ref()));
        assert_eq!(std::fs::read(&copy).unwrap(), b"y");
        assert!(made[4].text_card && made[4].text.as_deref() == Some("a note"));
        // the batch reads back the same cards (a file card's "ref", the text card)
        let back = crate::capture::cards_of(&session);
        assert_eq!(back.len(), 5);
        assert_eq!(back[2].reference, made[2].reference);
        assert!(back[4].text_card && back[4].kind == "voice");
        assert!(session.join("shots/002.png").is_file() && std::fs::read(&pdf).unwrap() == b"x" && cached.is_file());
        // the lines as the Mac and captures.py read them: a shot with "ref", a voice line with no recording
        let lines: Vec<Value> = std::fs::read_to_string(session.join("shots.jsonl")).unwrap().lines().map(|l| serde_json::from_str(l).unwrap()).collect();
        assert_eq!(lines[2]["type"], "shot");
        assert_eq!(lines[2]["file"], "shots/003.png");
        assert_eq!(lines[2]["ref"], json!(pdf.to_string_lossy()));
        assert_eq!(lines[2]["source"], "drop");
        assert!(lines[0].get("ref").is_none());
        assert_eq!((lines[4]["type"].clone(), lines[4]["voice"].clone(), lines[4]["text"].clone()), (json!("voice"), Value::Null, json!("a note")));
        assert_eq!(lines[4]["file"], Value::Null);
        // deleting a file card leaves the file it refers to alone
        crate::capture::remove_card(&session, 3);
        assert!(pdf.is_file() && crate::capture::cards_of(&session).len() == 4);
        // the file it refers to moved away: the card says so (and still never touches anything)
        std::fs::rename(&gif, dir.path().join("moved.gif")).unwrap();
        let lines = crate::capture::card_lines(&session);
        let gone = lines.iter().map(|l| &l.card).find(|c| c.reference.as_deref() == Some(gif.to_string_lossy().as_ref())).unwrap();
        assert!(gone.missing);
        assert!(lines.iter().map(|l| &l.card).filter(|c| c.reference.is_some() && c.n != gone.n).all(|c| !c.missing));
        assert!(serde_json::to_value(gone).unwrap()["missing"] == true);
        assert!(lines.iter().filter(|l| l.card.reference.is_none()).all(|l| !l.card.missing));
        assert!(serde_json::to_value(&lines[0].card).unwrap().get("missing").is_none());
    }

    #[test]
    fn a_note_is_offered_for_one_thing_hung() {
        assert!(offers_note(1, false));
        assert!(!offers_note(1, true)); // filed: no card stays to note
        assert!(!offers_note(3, false));
        assert!(!offers_note(0, false));
    }

    #[test]
    fn a_drop_the_island_page_took_itself() {
        // absolute on this platform (a path with no drive isn't absolute on Windows)
        let home = if cfg!(windows) { "C:/Users/ana" } else { "/home/ana" };
        let p: PageDrop = serde_json::from_value(json!({
            "paths": [format!("{home}/Documents/spec.pdf"), format!("{home}/shot.png"), "relative/x.pdf".to_string(), format!("{home}/code")],
            "pictures": [{"name": "../../evil/cat.png", "data": "data:image/png;base64,iVBORw0KGgo="}, {"name": "", "data": "%%%"}],
            "text": "ignored when files came", "row": "project:p1"
        }))
        .unwrap();
        let d = page_drop(&p, |x| x.ends_with("code"), |_| None);
        assert_eq!(d.files, [PathBuf::from(format!("{home}/Documents/spec.pdf"))]);
        assert_eq!(d.images, [PathBuf::from(format!("{home}/shot.png"))]);
        assert_eq!(d.folders, 1);
        // a picture with no path: its own name only (never a path the page made up), the malformed one left out
        assert_eq!(d.virtual_names, ["cat.png"]);
        assert_eq!(d.virtual_data, [vec![0x89, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a]]);
        assert!(d.text.is_none());
        assert_eq!(landing(p.row.as_deref()), Landing::Project("p1".into()));
        // only text
        let t = page_drop(&PageDrop { text: Some("  https://example.com \r\n".into()), ..Default::default() }, |_| false, |_| None);
        assert_eq!(t.text.as_deref(), Some("https://example.com"));
        assert!(page_drop(&PageDrop::default(), |_| false, |_| None).is_empty());
        assert_eq!(base64_decode("aGk="), Some(b"hi".to_vec()));
        assert_eq!(base64_decode("aGk"), Some(b"hi".to_vec()));
    }

    #[test]
    fn what_a_paste_brings() {
        let mine = |p: &Path| p.to_string_lossy().contains("/.blurt/");
        let read = |paths: &[&str], png: bool, text: Option<&str>, rich: bool, ours: bool| ClipRead {
            paths: paths.iter().map(PathBuf::from).collect(),
            png: png.then(|| vec![1, 2, 3]),
            text: text.map(str::to_owned),
            rich,
            ours,
        };
        // files copied in Explorer / Files: pictures and other files; folders and Blurt's own files left out
        let c = clipboard_pick(read(&["/a/shot.png", "/a/spec.pdf", "/a/dir", "/p/.blurt/assets/u/f.png"], false, Some("/a/shot.png"), false, false), |p| p.ends_with("dir"), mine);
        assert_eq!((c.images, c.files, c.png, c.text), (vec![PathBuf::from("/a/shot.png")], vec![PathBuf::from("/a/spec.pdf")], None, None));
        // a screenshot: the picture
        let c = clipboard_pick(read(&[], true, None, false, false), |_| false, mine);
        assert_eq!(c.png, Some(vec![1, 2, 3]));
        // a browser's Copy Image (picture + its HTML, no rich text): the picture
        assert!(clipboard_pick(read(&[], true, Some(""), false, false), |_| false, mine).png.is_some());
        // Word / Excel: rich text + a picture of itself = the text
        let c = clipboard_pick(read(&[], true, Some("Q3 numbers\r\nrow 2"), true, false), |_| false, mine);
        assert_eq!((c.png, c.text.as_deref()), (None, Some("Q3 numbers\nrow 2")));
        // Blurt's own copy (a card's picture): only its text, if any
        let c = clipboard_pick(read(&["/a/shot.png"], true, Some("note"), false, true), |_| false, mine);
        assert!(c.images.is_empty() && c.png.is_none() && c.text.as_deref() == Some("note"));
        // only Blurt's own files: nothing as files, the text instead
        let c = clipboard_pick(read(&["/p/.blurt/assets/u/f.png"], false, Some("x"), false, false), |_| false, mine);
        assert!(c.images.is_empty() && c.text.as_deref() == Some("x"));
        // plain text
        assert_eq!(clipboard_pick(read(&[], false, Some(" hi "), false, false), |_| false, mine).text.as_deref(), Some("hi"));
        assert_eq!(clipboard_pick(ClipRead::default(), |_| false, mine), Clip::default());
    }

    #[test]
    fn blurts_own_last_copy() {
        // Windows: the sequence number says it (any later copy, even the same picture, moves it)
        let w = Some(Ours { seq: 41, size: (10, 10) });
        assert!(is_ours(w, 41, None));
        assert!(!is_ours(w, 42, Some((10, 10))));
        // Linux: no sequence number — the picture's size
        let l = Some(Ours { seq: 0, size: (300, 200) });
        assert!(is_ours(l, 0, Some((300, 200))));
        assert!(!is_ours(l, 0, Some((300, 201))) && !is_ours(l, 0, None));
        assert!(!is_ours(None, 0, Some((1, 1))));
    }

    #[test]
    fn blurts_own_folders() {
        assert!(is_mine(Path::new("/Users/ana/proj/.blurt/assets/u1/a.png")));
        assert!(is_mine(Path::new(r"C:\Users\Ana\proj\.blurt\sessions\s\shots\001.png")));
        assert!(is_mine(&crate::paths::blurt_home().join("handoff").join("H-1.md")));
        assert!(is_mine(&crate::paths::inbox_store().join("items").join("a.md")));
        assert!(!is_mine(Path::new("/Users/ana/Documents/spec.pdf")));
    }
}
