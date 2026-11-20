//! Blurt's Windows system service: install / uninstall / run / agent (src/platform/windows/service.rs). No window of its own.
#![cfg_attr(windows, windows_subsystem = "windows")]

#[cfg(windows)]
fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    std::process::exit(blurt_remote::platform::windows::service::main(&args));
}

#[cfg(not(windows))]
fn main() {
    eprintln!("blurt-remote-service: Windows only");
    std::process::exit(2);
}
