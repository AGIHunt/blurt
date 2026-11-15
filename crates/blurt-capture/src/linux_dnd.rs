//! Linux (GTK 3 on XWayland): a hanging card dragged out of the island as the system's own drag (docs/design/drag-drop.md
//! §2, the Mac's CardDrag, Windows' card_drag_win.rs). The island page follows the card with the pointer while it is
//! inside the island; once it leaves, the page hands over (`card.dragout`) with the button still held, and this
//! starts a GTK drag from the island's window — the press it began with is still ours (X11's implicit grab), so the
//! drag's own grab is granted. mutter carries an XWayland client's XDND drag on to Wayland apps (Files, Firefox,
//! Chrome, GNOME Text Editor, the terminals) and to other XWayland apps.
//!
//! What the drag offers: `text/uri-list` (the cards' files: a file manager copies them, a chat app or a browser's
//! upload area takes them as files, a terminal types their quoted paths) and plain text (each card's `'path' note` on
//! one line: what an editor or a text field takes). Which one is used is the target's choice — GTK says nothing about
//! which app it is, so there is no per-app payload as on the Mac and Windows.
//!
//! Only GTK and GLib here (no Tauri): this file is also checked on its own for the Linux target.

use gtk::glib;
use gtk::prelude::*;
use std::cell::{Cell, RefCell};
use std::path::{Path, PathBuf};
use std::rc::Rc;

/// What a drag carries.
pub struct Payload {
    /// the files (pictures, a file card's own file), in the order they go
    pub files: Vec<PathBuf>,
    /// the text form: `'path' note` per card, one line
    pub text: String,
    /// the drag image: a picture of the first card (scaled to 160 px), held where the pointer holds it
    pub icon: Option<PathBuf>,
}

/// How a drag ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Ended {
    /// another window took it (not cancelled, not refused, not let go over nothing)
    pub taken: bool,
    /// the window that took it is `ours` (the main window): it files the cards itself
    pub ours: bool,
}

const URIS: u32 = 0;
const TEXT: u32 = 1;

/// A file's `file://` URI (None: a path GLib can't express).
pub fn file_uri(p: &Path) -> Option<String> {
    glib::filename_to_uri(p, None).ok().map(|u| u.to_string())
}

/// Starts the drag from `source` (the island's GTK window; on the main thread) with the button still down. `ours`:
/// Blurt's main window, to tell a drop there from one in another app. `done` is called once, when the drag is over.
/// False: GTK didn't start it (nothing to drag, no pointer grab) — `done` is never called then.
pub fn drag(
    source: &impl IsA<gtk::Window>,
    p: Payload,
    ours: Option<&impl IsA<gtk::Widget>>,
    done: impl FnOnce(Ended) + 'static,
) -> bool {
    let ours: Option<gtk::Widget> = ours.map(|o| o.clone().upcast());
    let uris: Vec<String> = p.files.iter().filter_map(|f| file_uri(f)).collect();
    if uris.is_empty() && p.text.trim().is_empty() {
        return false;
    }
    let targets = gtk::TargetList::new(&[]);
    if !uris.is_empty() {
        targets.add(&gtk::gdk::Atom::intern("text/uri-list"), 0, URIS);
    }
    if !p.text.trim().is_empty() {
        targets.add_text_targets(TEXT);
    }
    let w: gtk::Widget = source.as_ref().clone().upcast();
    let failed = Rc::new(Cell::new(false));
    let done = Rc::new(RefCell::new(Some(done)));
    let ids = Rc::new(RefCell::new(Vec::new()));
    let text = p.text.clone();
    ids.borrow_mut().push(w.connect_drag_data_get(move |_, _, sel, info, _| {
        if info == URIS {
            let refs: Vec<&str> = uris.iter().map(String::as_str).collect();
            sel.set_uris(&refs);
        } else {
            sel.set_text(&text);
        }
    }));
    let icon = p.icon.clone();
    ids.borrow_mut().push(w.connect_drag_begin(move |_, ctx| {
        if let Some(pb) = icon.as_ref().and_then(|f| gtk::gdk_pixbuf::Pixbuf::from_file_at_scale(f, 160, 160, true).ok()) {
            ctx.drag_set_icon_pixbuf(&pb, pb.width() / 2, pb.height() / 2);
        }
    }));
    {
        let failed = failed.clone();
        ids.borrow_mut().push(w.connect_drag_failed(move |_, _, _| {
            failed.set(true);
            // no "snap back" animation of GTK's own: the page puts the card back on its thread
            glib::Propagation::Stop
        }));
    }
    let end = {
        let (failed, done, ids) = (failed.clone(), done.clone(), ids.clone());
        w.connect_drag_end(move |w, ctx| {
            let taken = !failed.get();
            let dest = dest_toplevel(ctx);
            let mine = ours.as_ref().and_then(|o| o.window()).map(|g| g.toplevel());
            let ours = taken && dest.is_some() && dest == mine;
            // this drag's handlers go with it (the next drag connects its own)
            let mine: Vec<glib::SignalHandlerId> = ids.borrow_mut().drain(..).collect();
            for id in mine {
                w.disconnect(id);
            }
            if let Some(f) = done.borrow_mut().take() {
                f(Ended { taken, ours });
            }
        })
    };
    ids.borrow_mut().push(end);
    let started = w.drag_begin_with_coordinates(&targets, gtk::gdk::DragAction::COPY, 1, None, -1, -1).is_some();
    if !started {
        for id in ids.borrow_mut().drain(..) {
            w.disconnect(id);
        }
        done.borrow_mut().take();
    }
    started
}

/// The toplevel of the window a drag was dropped on (None: none — GDK has no destination, e.g. cancelled).
fn dest_toplevel(ctx: &gtk::gdk::DragContext) -> Option<gtk::gdk::Window> {
    use glib::translate::{from_glib_none, ToGlibPtr};
    unsafe {
        let p = gtk::gdk::ffi::gdk_drag_context_get_dest_window(ctx.to_glib_none().0);
        if p.is_null() {
            None
        } else {
            let w: gtk::gdk::Window = from_glib_none(p);
            Some(w.toplevel())
        }
    }
}
