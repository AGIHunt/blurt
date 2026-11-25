"""The Windows installer's own words (apps/desktop/src-tauri/installer/hooks.nsh). Tauri includes that file before its
NSIS template defines anything, so a `${…}` in it that only the template defines is kept as text: the welcome page said
「安装 Blurt ${VERSION}」 in every installer from 1.0.12 (#110)."""
from __future__ import annotations

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC_TAURI = ROOT / "apps/desktop/src-tauri"
HOOKS = SRC_TAURI / "installer" / "hooks.nsh"
CONF = SRC_TAURI / "tauri.conf.json"
# installer.nsi of tauri-cli 2.12: `!include "{{installer_hooks}}"` is its line 36, and these are defined from line 39 on
DEFINED_BY_TAURI_AFTER_THE_HOOKS = (
    "VERSION", "VERSIONWITHBUILD", "MANUFACTURER", "PRODUCTNAME", "HOMEPAGE", "INSTALLMODE", "LICENSE", "INSTALLERICON",
    "SIDEBARIMAGE", "HEADERIMAGE", "UNINSTALLERICON", "UNINSTALLERHEADERIMAGE", "MAINBINARYNAME", "MAINBINARYSRCPATH",
    "BUNDLEID", "COPYRIGHT", "OUTFILE", "ARCH", "UNINSTKEY", "ESTIMATEDSIZE", "STARTMENUFOLDER",
)
# how the hooks read it: the config next to their own folder, its first `"version": "`
VERSION_READ = re.compile(r"^!searchparse /noerrors /file \"\$\{__FILEDIR__\}([^\"]*)\" '(\"version\": \")' BLURT_VERSION '\"'", re.M)


def test_the_hooks_use_nothing_tauri_defines_after_including_them():
    code = "\n".join(line for line in HOOKS.read_text(encoding="utf-8-sig").splitlines() if not line.lstrip().startswith(";"))
    used = set(re.findall(r"\$\{([A-Za-z0-9_]+)\}", code))
    too_late = sorted(used & set(DEFINED_BY_TAURI_AFTER_THE_HOOKS))
    assert not too_late, too_late


def test_the_welcome_page_gets_the_version_the_installer_is_built_with():
    """hooks.nsh reads the version while the installer is compiled. Nothing on the Mac shows the welcome page, so a
    config read some other way, or another `version` written above the app's own, would put the wrong number there."""
    code = HOOKS.read_text(encoding="utf-8-sig")
    read = VERSION_READ.search(code)
    assert read, "hooks.nsh doesn't read the version the way this test knows"
    assert (HOOKS.parent / read.group(1).lstrip("/")).resolve() == CONF.resolve()
    text = CONF.read_text(encoding="utf-8")
    first = re.search(r'"version": "([^"]+)"', text)
    assert first and first.group(1) == json.loads(text)["version"], "the first version in the file is not the app's"
    for other in SRC_TAURI.glob("tauri.*.conf.json"):     # a platform config lays its values over the base one
        assert "version" not in json.loads(other.read_text(encoding="utf-8")), other.name
    for title in ("Install Blurt ${BLURT_VERSION}", "安装 Blurt ${BLURT_VERSION}"):
        assert title in code, title


def code_lines() -> str:
    return "\n".join(line for line in HOOKS.read_text(encoding="utf-8-sig").splitlines() if not line.lstrip().startswith(";"))


def test_the_hooks_define_only_their_own_names():
    """Tauri includes MUI2, FileFunc, its FileAssociation.nsh, … before the hooks, and NSIS stops at a name defined twice
    (FileAssociation.nsh has SHCNE_ASSOCCHANGED). desktop.yml doesn't run on pull requests, so a build would only say so at
    a release."""
    names = re.findall(r"^\s*!define\s+(?:/\S+\s+)*([^\s]+)", code_lines(), re.M)
    assert names
    assert [n for n in names if not n.startswith(("MUI_", "BLURT"))] == []


def test_icons_are_read_again_after_the_copy():
    """An update keeps the shortcuts: one that had lost its icon kept the generic one without this (measured on Windows)."""
    body = re.search(r"^!macro NSIS_HOOK_POSTINSTALL\n(.*?)^!macroend", code_lines(), re.M | re.S)
    assert body and "${RefreshShellIcons}" in body.group(1)
