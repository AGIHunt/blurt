//! Files and folders dropped from Explorer (or any app) on the main window: their paths, which a page never learns.
//!
//! The main window keeps `dragDropEnabled: false`: Tauri's own drop target would take every drag over the webview and
//! break the HTML5 ones (rows dragged onto a project, project reordering). WebView2's drop handling stays, but a page
//! never learns a dropped file's path. So the page hands the dropped `File` objects over with
//! `chrome.webview.postMessageWithAdditionalObjects(message, files)`, and here WebView2 gives each one's path
//! (ICoreWebView2File):
//!  • "blurt-drop-folders": folders dropped on the sidebar (the Mac's sidebar takes file URLs) go back as
//!    `mainwin://folders-dropped` {paths}; the page opens them as projects (projects_add), goes to the last and says so.
//!  • "blurt-drop-files:<token>": anything dropped on the list, an item or a project row (drag-drop.md §4) goes back
//!    as `mainwin://files-dropped` {token, files: [{path, dir}]}, in the drop's order (a file WebView2 has no path for
//!    — a picture dragged out of a browser — is {path: ""}: the page reads its bytes instead). Each file may then
//!    show as a thumbnail in New Item: the asset protocol may read it (that file only).

#[cfg(windows)]
pub fn install(app: &tauri::AppHandle) {
    use tauri::{Emitter, Manager};
    use webview2_com::Microsoft::Web::WebView2::Win32::{ICoreWebView2File, ICoreWebView2WebMessageReceivedEventArgs2};
    use webview2_com::{take_pwstr, WebMessageReceivedEventHandler};
    use windows::core::{Interface, PWSTR};

    let Some(w) = app.get_webview_window("main") else { return };
    let app = app.clone();
    let _ = w.with_webview(move |wv| unsafe {
        let Ok(core) = wv.controller().CoreWebView2() else { return };
        let handler = WebMessageReceivedEventHandler::create(Box::new(move |_, args| {
            let Some(args) = args else { return Ok(()) };
            let mut msg = PWSTR::null();
            if args.TryGetWebMessageAsString(&mut msg).is_err() {
                return Ok(());
            }
            let msg = take_pwstr(msg);
            let token = msg.strip_prefix("blurt-drop-files:").map(str::to_owned);
            if msg != "blurt-drop-folders" && token.is_none() {
                return Ok(()); // the app's own IPC: wry's handler has it
            }
            let Ok(args2) = args.cast::<ICoreWebView2WebMessageReceivedEventArgs2>() else { return Ok(()) };
            let Ok(objs) = args2.AdditionalObjects() else { return Ok(()) };
            let mut n = 0u32;
            let _ = objs.Count(&mut n);
            let mut paths = Vec::new();
            for i in 0..n {
                let path = objs
                    .GetValueAtIndex(i)
                    .ok()
                    .and_then(|o| o.cast::<ICoreWebView2File>().ok())
                    .and_then(|f| {
                        let mut p = PWSTR::null();
                        f.Path(&mut p).ok().map(|_| take_pwstr(p))
                    })
                    .unwrap_or_default();
                paths.push(path);
            }
            match token {
                None => {
                    let dirs: Vec<&String> = paths.iter().filter(|p| std::path::Path::new(p).is_dir()).collect();
                    let _ = app.emit_to("main", "mainwin://folders-dropped", serde_json::json!({"paths": dirs}));
                }
                Some(token) => {
                    let files: Vec<serde_json::Value> = paths
                        .iter()
                        .map(|p| {
                            let dir = !p.is_empty() && std::path::Path::new(p).is_dir();
                            if !p.is_empty() && !dir {
                                let _ = app.asset_protocol_scope().allow_file(p);
                            }
                            serde_json::json!({"path": p, "dir": dir})
                        })
                        .collect();
                    let _ = app.emit_to("main", "mainwin://files-dropped", serde_json::json!({"token": token, "files": files}));
                }
            }
            Ok(())
        }));
        let mut token = Default::default();
        if let Err(e) = core.add_WebMessageReceived(&handler, &mut token) {
            eprintln!("blurt: folder drops unavailable: {e}");
        }
    });
}

#[cfg(not(windows))]
pub fn install(_app: &tauri::AppHandle) {}
