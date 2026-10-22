# SwiftTerm (vendored)

The terminal emulator behind Blurt's embedded agent sessions (`Sources/BlurtApp/Terminal/`).

- Upstream: https://github.com/migueldeicaza/SwiftTerm, tag `v1.20.0`, commit `5d14406844143538cd8f8851d2d8a67c1fe443e5`
  (2026-08-18). MIT licence, see `LICENSE`.
- Vendored so that `swift build` works offline and with the Command Line Tools alone (no Xcode, no network, no
  package resolution).
- `Sources/` = upstream `Sources/SwiftTerm/` **minus** `iOS/`, `Documentation.docc/`, `Mac/README.md` and
  `Apple/Metal/Shaders.metal`. The Metal renderer is opt-in upstream (`TerminalView.setUseMetal`) and Blurt never
  turns it on, so the shader (which needs Xcode's Metal compiler) is left out; its Swift code still compiles.
- `Sources/SwiftTermBuildInfo.swift` is ours: it replaces the upstream build-tool plugin that generated that file from
  git at build time.
- No other changes. To update: copy the same folders from a newer tag, update the constants in
  `SwiftTermBuildInfo.swift` and this file, then `swift build` in `skills/blurt/recorder/macos`.
