use std::hash::Hasher;
use std::path::{Path, PathBuf};

fn main() {
    // `dict`: dictation, voice notes and the note's mic are built (Windows and Linux; the Mac app is Swift)
    println!("cargo::rustc-check-cfg=cfg(dict)");
    let os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    if os == "windows" || os == "linux" {
        println!("cargo:rustc-cfg=dict");
    }
    stage_skill();
    tauri_build::build()
}

/// The skill the app carries (skill.rs; the Mac's release-mac.sh does the same for Blurt.app): SKILL.md, scripts/,
/// reference/ and assets/ of skills/blurt — not models/ (bundled on their own) nor the Mac recorder's source — staged
/// into gen/skill (git-ignored) with a `.version` stamp, which tauri.conf.json bundles as `skill/`. The stamp is the
/// app's version and a hash of every staged file, so any change to the skill (a dev build too) is copied to
/// $BLURT_HOME/skill at the next launch, and an unchanged one never is.
fn stage_skill() {
    let manifest = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap());
    let src = manifest.join("../../../skills/blurt");
    let out = manifest.join("gen/skill");
    println!("cargo:rerun-if-changed=../../../skills/blurt/SKILL.md");
    let mut files: Vec<PathBuf> = vec![PathBuf::from("SKILL.md")];
    let mut dirs: Vec<PathBuf> = Vec::new();
    for d in ["scripts", "reference", "assets"] {
        walk(&src, Path::new(d), &mut files, &mut dirs);
    }
    for d in &dirs {
        // a folder changes when a file is added or removed in it; a file's own change is caught below
        println!("cargo:rerun-if-changed=../../../skills/blurt/{}", d.to_string_lossy().replace('\\', "/"));
    }
    files.sort();
    let mut h = std::collections::hash_map::DefaultHasher::new();
    for rel in &files {
        let Ok(bytes) = std::fs::read(src.join(rel)) else { continue };
        write_if_changed(&out.join(rel), &bytes);
        h.write(rel.to_string_lossy().replace('\\', "/").as_bytes());
        h.write(&bytes);
        println!("cargo:rerun-if-changed=../../../skills/blurt/{}", rel.to_string_lossy().replace('\\', "/"));
    }
    let version = std::env::var("CARGO_PKG_VERSION").unwrap_or_default();
    write_if_changed(&out.join(".version"), format!("{version} {:016x}\n", h.finish()).as_bytes());
    // a file gone from the skill goes from the stage too
    let (mut staged, mut _d) = (Vec::new(), Vec::new());
    walk(&out, Path::new(""), &mut staged, &mut _d);
    for f in staged {
        if f != Path::new(".version") && !files.contains(&f) {
            let _ = std::fs::remove_file(out.join(f));
        }
    }
}

/// Only a changed file is written: tauri-build watches gen/skill, and a file written on every build would run this
/// script (and rebuild the app) every time.
fn write_if_changed(to: &Path, bytes: &[u8]) {
    if std::fs::read(to).ok().as_deref() == Some(bytes) {
        return;
    }
    std::fs::create_dir_all(to.parent().unwrap()).expect("gen/skill");
    std::fs::write(to, bytes).expect("gen/skill");
}

/// Every file under `src/rel` (and the folders), skipping caches and virtual environments (a dev checkout has them).
fn walk(src: &Path, rel: &Path, files: &mut Vec<PathBuf>, dirs: &mut Vec<PathBuf>) {
    let Ok(rd) = std::fs::read_dir(src.join(rel)) else { return };
    dirs.push(rel.to_path_buf());
    for e in rd.flatten() {
        let name = e.file_name().to_string_lossy().into_owned();
        if matches!(name.as_str(), "__pycache__" | ".venv" | "node_modules" | ".DS_Store" | ".pytest_cache") || name.ends_with(".pyc") {
            continue;
        }
        let r = rel.join(&name);
        match e.file_type() {
            Ok(t) if t.is_dir() => walk(src, &r, files, dirs),
            Ok(_) => files.push(r),
            Err(_) => {}
        }
    }
}
