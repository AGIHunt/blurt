//! The v0.7 read / write path against the real Python CLIs, without a window: a git project is opened
//! (`projects.py add`), the v2 fixture sessions are migrated into its store and indexed, then we read the index (schema
//! v2) and the project list as the app does, load the project's review document, edit an item through `items.py
//! user-ops` and find the edit in its Markdown file. Needs uv; skipped without it or without the v0.7 scripts.
//!
//!   cargo test --test flow                      (BLURT_SCRIPTS=<dir> to test other scripts than the repo's)

use std::path::{Path, PathBuf};
use std::process::Command;

use blurt_desktop_lib::index::{Index, ItemQuery, SessionQuery};
use blurt_desktop_lib::items::{self, DocCache};
use blurt_desktop_lib::scripts::Runner;
use blurt_desktop_lib::{paths, projects};
use serde_json::{json, Value};

fn root() -> PathBuf {
    paths::normalize(&Path::new(env!("CARGO_MANIFEST_DIR")).join("../../.."))
}

fn which(n: &str) -> Option<PathBuf> {
    let exe = if cfg!(windows) { format!("{n}.exe") } else { n.to_string() };
    std::env::split_paths(&std::env::var_os("PATH")?).map(|d| d.join(&exe)).find(|p| p.is_file())
}

fn copy_dir(from: &Path, to: &Path) {
    std::fs::create_dir_all(to).unwrap();
    for e in std::fs::read_dir(from).unwrap().flatten() {
        let p = e.path();
        if p.is_dir() {
            copy_dir(&p, &to.join(e.file_name()));
        } else {
            std::fs::copy(&p, to.join(e.file_name())).unwrap();
        }
    }
}

#[test]
fn open_migrate_search_edit() {
    let scripts = std::env::var_os("BLURT_SCRIPTS").map(PathBuf::from).unwrap_or_else(|| root().join("skills/blurt/scripts"));
    let Some(uv) = which("uv") else {
        eprintln!("skipped: no uv");
        return;
    };
    if !scripts.join("projects.py").is_file() || which("git").is_none() {
        eprintln!("skipped: the v0.7 scripts (projects.py) or git are missing in {}", scripts.display());
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let (home, ws) = (tmp.path().join("home"), tmp.path().join("ws"));
    std::fs::create_dir_all(&home).unwrap();
    std::fs::write(home.join("config.json"), r#"{"record": {"install_app": false}}"#).unwrap();
    std::env::set_var("BLURT_HOME", &home);
    std::env::set_var("BLURT_WORKSPACE", &ws);
    std::env::set_var("BLURT_NO_LOGIN_SHELL", "1");
    let repo = tmp.path().join("storefront");
    std::fs::create_dir_all(repo.join("web")).unwrap();
    std::fs::write(repo.join("web/cart.ts"), "export const cart = 1;\n").unwrap();
    let git = |args: &[&str]| assert!(Command::new("git").args(args).current_dir(&repo).output().unwrap().status.success(), "git {args:?}");
    git(&["init", "-q"]);
    git(&["add", "-A"]);
    git(&["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init"]);

    let runner = Runner { scripts: Some(scripts), uv: Some(uv) };
    let added = projects::add(&runner, &repo.to_string_lossy()).expect("projects.py add");
    let pid = added.pointer("/project/id").and_then(Value::as_str).unwrap().to_string();
    let fx = root().join("tests/fixtures/sessions");
    for e in std::fs::read_dir(&fx).unwrap().flatten() {
        let name = e.file_name();
        let dest = if name.to_string_lossy().ends_with("-shots") { ws.join("recordings") } else { repo.join(".blurt/sessions") };
        copy_dir(&e.path(), &dest.join(&name));
    }
    runner.run("items.py", &["migrate".into(), "--all".into()], None, std::time::Duration::from_secs(120)).expect("migrate");
    runner.run("index.py", &["scan".into()], None, std::time::Duration::from_secs(120)).expect("scan");

    // the project list, as the sidebar reads it (projects.json + index counts)
    let ix = Index::new(home.join("index.db"));
    assert!(ix.ready(), "index.db is schema v2");
    let list = projects::list(&ix);
    let row = list["projects"].as_array().unwrap().iter().find(|p| p["id"] == pid.as_str()).cloned().unwrap();
    assert_eq!((row["key"].as_str(), row["kind"].as_str()), (Some("STO"), Some("repo")));
    assert!(row["open_items"].as_i64().unwrap() > 0, "{row}");
    assert_eq!(list["inbox"]["key"], "IN");

    // the index: every item of the project, a search, the batches to review
    let all = ix.items(&ItemQuery { project: Some(pid.clone()), ..Default::default() }).unwrap();
    assert!(all.total >= 5, "{}", all.total);
    assert!(all.items.iter().all(|i| i["item_id"].as_str().unwrap().starts_with("STO-")));
    let hit = ix.items(&ItemQuery { query: Some("头像上".into()), ..Default::default() }).unwrap();
    assert_eq!(hit.total, 1, "{:?}", hit.items);
    let uid = hit.items[0]["uid"].as_str().unwrap().to_string();
    assert!(!ix.sessions(&SessionQuery::default()).unwrap().is_empty());

    // the review document of the project, an edit through user-ops, the Markdown file
    let cache = DocCache::default();
    let scope = json!({"project": pid});
    let d = items::doc(&runner, &cache, &scope).expect("items.py doc");
    let etag = d["etag"].as_str().unwrap().to_string();
    assert!(d["doc"]["items"].as_array().unwrap().iter().any(|i| i["uid"] == uid.as_str()));
    assert_eq!(items::poll(&runner, &cache, &scope, &etag).unwrap().get("doc"), None, "unchanged: answered from the cache");
    let r = items::ops(&runner, &cache, &scope, &json!([{"op": "set", "id": uid, "set": {"title": "Avatar upload fails (flow test)"}}]), false).expect("user-ops");
    assert_eq!(r["ok"], true);
    let item = ix.item(&uid).unwrap().unwrap();
    let md = std::fs::read_to_string(item["path"].as_str().unwrap()).unwrap();
    assert!(md.contains("Avatar upload fails (flow test)"), "{md}");
    assert!(items::poll(&runner, &cache, &scope, &etag).unwrap().get("doc").is_some());
    // nothing of the store shows up in git
    let st = Command::new("git").args(["status", "--porcelain"]).current_dir(&repo).output().unwrap();
    assert!(String::from_utf8_lossy(&st.stdout).trim().is_empty(), "{}", String::from_utf8_lossy(&st.stdout));
}
