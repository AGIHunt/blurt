//! Folders dropped from Explorer onto the main window's sidebar become projects (the Mac's sidebar takes file URLs).
//!
//! The main window keeps `dragDropEnabled: false`: Tauri's own drop target would take every drag over the webview and
//! break the HTML5 ones (rows dragged onto a project, project reordering). WebView2's drop handling stays, but a page
//! never learns a dropped folder's path. So the page hands the dropped `File` objects over with
//! `chrome.webview.postMessageWithAdditionalObjects("blurt-drop-folders", files)`, and here WebView2 gives each one's
//! path (ICoreWebView2File). The folders go back to the page as `mainwin://folders-dropped` {paths}; the page opens
//! them as projects (projects_add), goes to the last and says so.

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
            if args.TryGetWebMessageAsString(&mut msg).is_err() || take_pwstr(msg) != "blurt-drop-folders" {
                return Ok(()); // the app's own IPC: wry's handler has it
            }
            let Ok(args2) = args.cast::<ICoreWebView2WebMessageReceivedEventArgs2>() else { return Ok(()) };
            let Ok(objs) = args2.AdditionalObjects() else { return Ok(()) };
            let mut n = 0u32;
            let _ = objs.Count(&mut n);
            let mut paths = Vec::new();
            for i in 0..n {
                let Ok(o) = objs.GetValueAtIndex(i) else { continue };
                let Ok(f) = o.cast::<ICoreWebView2File>() else { continue };
                let mut p = PWSTR::null();
                if f.Path(&mut p).is_ok() {
                    let p = take_pwstr(p);
                    if std::path::Path::new(&p).is_dir() {
                        paths.push(p);
                    }
                }
            }
            let _ = app.emit_to("main", "mainwin://folders-dropped", serde_json::json!({"paths": paths}));
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
