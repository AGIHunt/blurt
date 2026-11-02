; Blurt's additions to Tauri's NSIS installer (tauri.conf.json bundle.windows.nsis.installerHooks; the pictures come
; from assets/brand/import_peep.py --only installer). As the Mac's DMG window — one calm picture, one plain line — as far
; as Tauri's page list lets a hook go (docs/design/windows-parity/installer.md):
; - no footer text under the pages: NSIS prints the copyright there (Tauri sets BrandingText after this file is
;   included, so the text is blanked when the window opens instead: control 1028 and MUI's 1256 copy of it; MUI shows
;   and hides them per page, so they are emptied, not hidden);
; - the system's UI font, not a bitmap one: Simplified Chinese defaults to SimSun, whose bold 12 pt title on the welcome
;   and finish pages renders as a bitmap font;
; - our own words on the welcome, folder and finish pages (MUI's stock text asked to close every other app "to update
;   system files" — untrue for a per-user install — and named the buttons in brackets); the version on the welcome;
; - no "Show details" log, and the progress page goes straight on to Finish when the copy is done (Tauri keeps it up
;   for debugging; nothing on it is for a user);
; - on Finish: "Open Blurt" checked, the desktop shortcut not (the Start menu has it; the Mac puts nothing on the
;   desktop); the header picture at the right, so the inner pages' titles start on the body's left margin.
; These defines are read by the one page macro each belongs to (MUI_WELCOMEPAGE_* by the welcome, …), so setting them
; here, before Tauri's page list, reaches those pages only. Language strings by id: 1033 English, 2052 Simplified Chinese.
SetFont /LANG=1033 "Segoe UI" 9
SetFont /LANG=2052 "Microsoft YaHei UI" 9

!define MUI_CUSTOMFUNCTION_GUIINIT BlurtGuiInit
!define MUI_CUSTOMFUNCTION_UNGUIINIT un.BlurtGuiInit

ShowInstDetails nevershow
ShowUninstDetails nevershow

!define MUI_HEADERIMAGE_RIGHT

LangString BlurtWelcomeTitle 1033 "Install Blurt ${VERSION}"
LangString BlurtWelcomeTitle 2052 "安装 Blurt ${VERSION}"
LangString BlurtWelcomeText 1033 "Blurt goes on this PC for your Windows account. No administrator rights needed, and nothing else needs to close."
LangString BlurtWelcomeText 2052 "Blurt 会装在这台电脑上，只给当前 Windows 账户用。不需要管理员权限，也不用关闭别的程序。"
LangString BlurtFolderText 1033 "Blurt goes in this folder, for your account only."
LangString BlurtFolderText 2052 "Blurt 会装在这个文件夹里，只给当前账户用。"
LangString BlurtFinishTitle 1033 "Blurt is installed"
LangString BlurtFinishTitle 2052 "Blurt 已装好"
LangString BlurtFinishText 1033 "It runs from the top of the screen and the notification area. Right Alt starts dictation."
LangString BlurtFinishText 2052 "它在屏幕顶部和任务栏通知区域里运行。按右 Alt 开始听写。"
LangString BlurtRunText 1033 "Open Blurt"
LangString BlurtRunText 2052 "打开 Blurt"

!define MUI_WELCOMEPAGE_TITLE "$(BlurtWelcomeTitle)"
!define MUI_WELCOMEPAGE_TEXT "$(BlurtWelcomeText)"
!define MUI_DIRECTORYPAGE_TEXT_TOP "$(BlurtFolderText)"
!define MUI_FINISHPAGE_TITLE "$(BlurtFinishTitle)"
!define MUI_FINISHPAGE_TEXT "$(BlurtFinishText)"
!define MUI_FINISHPAGE_RUN_TEXT "$(BlurtRunText)"
!define MUI_FINISHPAGE_SHOWREADME_NOTCHECKED

!macro BLURT_HIDE_BRANDING
  GetDlgItem $0 $HWNDPARENT 1028
  SendMessage $0 12 0 "STR:"
  GetDlgItem $0 $HWNDPARENT 1256
  SendMessage $0 12 0 "STR:"
!macroend

Function BlurtGuiInit
  !insertmacro BLURT_HIDE_BRANDING
FunctionEnd

Function un.BlurtGuiInit
  !insertmacro BLURT_HIDE_BRANDING
FunctionEnd

; the copy is done: on to Finish by itself (the progress page is never a stop of its own)
!macro NSIS_HOOK_POSTINSTALL
  SetAutoClose true
!macroend
