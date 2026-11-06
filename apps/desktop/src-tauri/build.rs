fn main() {
    // `dict`: dictation, voice notes and the note's mic are built (Windows and Linux; the Mac app is Swift)
    println!("cargo::rustc-check-cfg=cfg(dict)");
    let os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    if os == "windows" || os == "linux" {
        println!("cargo:rustc-cfg=dict");
    }
    tauri_build::build()
}
