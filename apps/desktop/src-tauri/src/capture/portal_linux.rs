//! The screen on Wayland (docs/design/linux-port.md §Recording, §Snaps): `x11grab` sees only XWayland windows there,
//! so the ScreenCast portal hands a PipeWire stream to record.py (its `PipeWireFeed`), and the Screenshot portal
//! takes the stills.
//!
//! The first ScreenCast shows GNOME's "Share Screen" dialog (parented to the island, so it comes up in front); its
//! restore token, in `~/.blurt/portal/screencast.token`, skips it after that. The session lives as long as the take
//! (`Cast` closes it when dropped); GNOME shows its screen-share chip meanwhile.

use std::os::fd::{AsRawFd, OwnedFd};
use std::path::PathBuf;
use std::time::Duration;

use ashpd::desktop::screencast::{CursorMode, Screencast, SelectSourcesOptions, SourceType, StartCastOptions};
use ashpd::desktop::{CreateSessionOptions, PersistMode, Session};

use crate::dictation::insert_linux::block;

/// One take's stream: the PipeWire remote record.py inherits, the node to read, the monitor's size and place.
pub struct Cast {
    fd: OwnedFd,
    pub node: u32,
    pub size: (i32, i32),
    pub pos: (i32, i32),
    session: Option<Session<Screencast>>,
}

impl Cast {
    /// What record.py reads (BLURT_PW_*), the fd made inheritable for it.
    pub fn env(&self) -> Vec<(String, String)> {
        // SAFETY: fcntl on an fd we own; clearing FD_CLOEXEC lets the recorder (a child) inherit it
        unsafe {
            let fd = self.fd.as_raw_fd();
            let flags = libc::fcntl(fd, libc::F_GETFD);
            if flags >= 0 {
                libc::fcntl(fd, libc::F_SETFD, flags & !libc::FD_CLOEXEC);
            }
        }
        vec![
            ("BLURT_PW_FD".into(), self.fd.as_raw_fd().to_string()),
            ("BLURT_PW_NODE".into(), self.node.to_string()),
            ("BLURT_PW_SIZE".into(), format!("{}x{}", self.size.0, self.size.1)),
            ("BLURT_PW_POS".into(), format!("{},{}", self.pos.0, self.pos.1)),
        ]
    }
}

impl Drop for Cast {
    fn drop(&mut self) {
        if let Some(s) = self.session.take() {
            let _ = block(Duration::from_secs(3), async move {
                let _ = s.close().await;
            });
        }
    }
}

fn token_path() -> PathBuf {
    crate::paths::blurt_home().join("portal").join("screencast.token")
}

/// Starts a ScreenCast of one monitor, the pointer drawn in. `parent`: an X11 window the dialog opens over. Blocks
/// until the user answers the dialog the first time (up to 2 minutes).
pub fn screencast(parent: Option<u64>) -> Result<Cast, String> {
    block(Duration::from_secs(120), async move {
        crate::hotkeys::portal::register_host_app().await;
        let sc = Screencast::new().await.map_err(|e| e.to_string())?;
        let session = sc.create_session(CreateSessionOptions::default()).await.map_err(|e| e.to_string())?;
        let token = std::fs::read_to_string(token_path()).ok().map(|t| t.trim().to_string()).filter(|t| !t.is_empty());
        let opts = SelectSourcesOptions::default()
            .set_cursor_mode(CursorMode::Embedded)
            .set_sources(ashpd::enumflags2::BitFlags::from(SourceType::Monitor))
            .set_multiple(false)
            .set_persist_mode(PersistMode::ExplicitlyRevoked)
            .set_restore_token(token.as_deref());
        sc.select_sources(&session, opts).await.map_err(|e| e.to_string())?;
        let parent = parent.map(|x| ashpd::WindowIdentifier::from_xid(x as std::os::raw::c_ulong));
        let streams = sc
            .start(&session, parent.as_ref(), StartCastOptions::default())
            .await
            .map_err(|e| e.to_string())?
            .response()
            .map_err(|e| match e {
                ashpd::Error::Response(_) => "denied".to_string(),
                e => e.to_string(),
            })?;
        if let Some(t) = streams.restore_token() {
            let p = token_path();
            if let Some(d) = p.parent() {
                let _ = std::fs::create_dir_all(d);
            }
            let _ = std::fs::write(&p, t);
        }
        let s = streams.streams().first().ok_or("no stream")?;
        let (node, size, pos) = (s.pipe_wire_node_id(), s.size().unwrap_or((1920, 1080)), s.position().unwrap_or((0, 0)));
        let fd = sc.open_pipe_wire_remote(&session, Default::default()).await.map_err(|e| e.to_string())?;
        Ok(Cast { fd, node, size, pos, session: Some(session) })
    })
    .unwrap_or_else(|| Err("timeout".into()))
}
