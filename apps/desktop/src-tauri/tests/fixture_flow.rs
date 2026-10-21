//! The C8 read / write path against the real fixtures, without a window: index.py builds index.db over
//! tests/fixtures/sessions, we search it read-only, then edit an item through review_ops (→ items.py user-ops) and
//! check items.json. Needs uv (or python3) on PATH; skipped otherwise.
//!
//!   cargo test --test fixture_flow

use std::path::{Path, PathBuf};
use std::process::Command;

use blurt_desktop_lib::index::{Index, ItemQuery};
use blurt_desktop_lib::review;
use blurt_desktop_lib::scripts::Runner;
use serde_json::{json, Value};

fn root() -> PathBuf {
    // lexical, not canonicalize(): on Windows that gives \\?\ paths
    blurt_desktop_lib::paths::normalize(&Path::new(env!("CARGO_MANIFEST_DIR")).join("../../.."))
}

fn which(n: &str) -> Option<PathBuf> {
    std::env::split_paths(&std::env::var_os("PATH")?).map(|d| d.join(n)).find(|p| p.is_file())
}

#[test]
fn search_open_edit() {
    let Some(uv) = which(if cfg!(windows) { "uv.exe" } else { "uv" }) else {
        eprintln!("skipped: no uv");
        return;
    };
    let tmp = tempfile::tempdir().unwrap();
    let py = ["python3", "python"].into_iter().find(|p| which(&if cfg!(windows) { format!("{p}.exe") } else { p.to_string() }).is_some()).expect("python");
    let out = Command::new(py)
        .arg(root().join("apps/desktop/scripts/fixture_index.py"))
        .arg(tmp.path().join("fx"))
        .output()
        .expect("python3");
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    let info: Value = serde_json::from_slice(out.stdout.split(|b| *b == b'\n').find(|l| !l.is_empty()).unwrap()).unwrap();
    let bh = PathBuf::from(info["blurt_home"].as_str().unwrap());
    // items.py (and its in-process index update) must see the fixture's BLURT_HOME
    std::env::set_var("BLURT_HOME", &bh);
    std::env::set_var("HOME", info["home"].as_str().unwrap());
    std::env::set_var("BLURT_NO_LOGIN_SHELL", "1");

    let ix = Index::new(bh.join("index.db"));
    let all = ix.items(&ItemQuery::default()).unwrap();
    assert!(all.total >= 5, "{}", all.total);
    // a trigram search (≥ 3 chars) and a LIKE one (2 chars), as in C3
    let hit = ix.items(&ItemQuery { query: Some("头像上".into()), ..Default::default() }).unwrap();
    assert_eq!(hit.total, 1, "{:?}", hit.items);
    let row = &hit.items[0];
    assert!(row["snippet"].as_str().unwrap_or("").contains('['));
    assert!(ix.items(&ItemQuery { query: Some("头像".into()), ..Default::default() }).unwrap().total >= 1);
    assert_eq!(ix.workspaces().unwrap().len(), 2);

    // open the item's session as the review component would, then edit its title
    let session = row["session_dir"].as_str().unwrap().to_string();
    let item_id = row["item_id"].as_str().unwrap().to_string();
    let loaded = review::load(&session).unwrap();
    let etag = loaded["etag"].as_str().unwrap().to_string();
    let runner = Runner { scripts: Some(root().join("skills/blurt/scripts")), uv: Some(uv) };
    let r = review::ops(&runner, &session, &json!([{"op": "set", "id": item_id, "set": {"title": "头像上传 500（e2e 改过）"}}]), false).unwrap();
    assert_eq!(r["ok"], true);
    assert_ne!(r["etag"].as_str().unwrap(), etag);
    assert!(review::poll(&session, &etag).unwrap().get("doc").is_some());
    let doc: Value = serde_json::from_slice(&std::fs::read(Path::new(&session).join("items.json")).unwrap()).unwrap();
    let it = doc["items"].as_array().unwrap().iter().find(|i| i["id"] == item_id.as_str()).unwrap();
    assert_eq!(it["title"], "头像上传 500（e2e 改过）");
    assert!(it["_user"]["title"].is_number(), "{it}");
    // items.py re-indexed in-process: the new title is searchable at once
    let again = ix.items(&ItemQuery { query: Some("e2e 改过".into()), ..Default::default() }).unwrap();
    assert_eq!(again.total, 1);
}
