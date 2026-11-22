"""The Windows installer's own words (apps/desktop/src-tauri/installer/hooks.nsh). Tauri includes that file before its
NSIS template defines anything, so a `${…}` in it that only the template defines is kept as text: the welcome page said
「安装 Blurt ${VERSION}」 in every installer from 1.0.12 (#110)."""
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HOOKS = ROOT / "apps/desktop/src-tauri/installer/hooks.nsh"
# installer.nsi of tauri-cli 2.12: `!include "{{installer_hooks}}"` is its line 36, and these are defined from line 39 on
DEFINED_BY_TAURI_AFTER_THE_HOOKS = (
    "VERSION", "VERSIONWITHBUILD", "MANUFACTURER", "PRODUCTNAME", "HOMEPAGE", "INSTALLMODE", "LICENSE", "INSTALLERICON",
    "SIDEBARIMAGE", "HEADERIMAGE", "UNINSTALLERICON", "UNINSTALLERHEADERIMAGE", "MAINBINARYNAME", "MAINBINARYSRCPATH",
    "BUNDLEID", "COPYRIGHT", "OUTFILE", "ARCH", "UNINSTKEY", "ESTIMATEDSIZE", "STARTMENUFOLDER",
)


def test_the_hooks_use_nothing_tauri_defines_after_including_them():
    code = "\n".join(line for line in HOOKS.read_text(encoding="utf-8-sig").splitlines() if not line.lstrip().startswith(";"))
    used = set(re.findall(r"\$\{([A-Za-z0-9_]+)\}", code))
    too_late = sorted(used & set(DEFINED_BY_TAURI_AFTER_THE_HOOKS))
    assert not too_late, too_late
