# Windows 图标对齐 Mac（SF Symbols → @blurt/icons）

规则：Windows / Linux 每一处图标和 Mac 用同一个比喻。Mac 用 SF Symbols；Windows 用 @blurt/icons 线性图标族
（`assets/icons/*.svg`，24 网格、1.75 描边、圆头圆角、currentColor，`python3 assets/icons/tools/build.py` 生成 web / Swift / Tk）。
没有对应字形时在族里新画一个——读起来是 SF Symbol 的那个比喻，不是照抄苹果的画法。每个字形对应的 SF Symbol 写在
`assets/icons/sf-symbols.json` 的 `generic` 里（Mac 上同名图标会优先用这个 SF Symbol），所以这张表和那份 JSON 是同一个映射。

`tests/test_icons.py` 守着两处：设置侧栏 9 个面板、主窗口侧栏的地方，Windows 的字形必须对应 Mac 那一格的 SF Symbol；
`glyphs.tsx` 不再有手画的路径（全部是族里的字形）。

「之前」= 本轮之前 Windows 显示的；「现在」= 本轮改成的。✓ = 之前就对。

## 新画的字形（24 个）

| 字形 | 对应 SF Symbol | 用在 |
|------|---------------|------|
| `text-viewfinder` | text.viewfinder | 设置「截图取字」、模型页「看图识字」 |
| `cpu` | cpu | 设置「模型」、存储里「没有模型」 |
| `hand` | hand.raised | 设置「隐私」 |
| `drive` | internaldrive | 设置「存储」 |
| `character-cursor` | character.cursor.ibeam | 侧栏「听写」、设置「听写」、听写页标题、存储「听写记录」、模型页「听写」、命令面板 |
| `settings`（重画成齿轮） | gearshape | 设置「通用」、侧栏底栏齿轮、⋯ 菜单「设置」。原来的滑杆另起名 `sliders` |
| `sliders` | slider.horizontal.3 | 项目右键「项目设置…」 |
| `progress` | circle.righthalf.filled | 侧栏「进行中」、命令面板 |
| `unassigned` | 虚线圆（Mac 的 IslandGlyph.noProject；SF circle.dashed） | 侧栏「未归类」、移到项目浮层 |
| `tray-2` | tray.2 | 「移到项目」菜单和命令面板里的「未归类」、「不再作为当前项目」 |
| `list-box` | list.bullet.rectangle | 侧栏「全部事项」、存储「任务记录」、命令面板 |
| `sidebar` / `sidebar-right` | sidebar.left / sidebar.right | 工具栏侧栏按钮、⋯ 菜单两个开关、详情栏「没有选中」、会话窗格的列表开关 |
| `filter` / `filter-fill` | line.3.horizontal.decrease.circle(.fill) | 列表标题的筛选按钮、筛选行、命令面板「清除筛选」 |
| `scope` | scope | 侧栏当前项目标记、「设为当前项目」 |
| `pin` / `pin-off` | pin / pin.slash | 项目右键「置顶 / 取消置顶」 |
| `folder-missing` | questionmark.folder | 找不到文件夹的项目、横幅、「找到它…」 |
| `move` | arrow.turn.up.right | 「移到项目」（之前误用了「交给」的纸飞机） |
| `text-plus` | text.badge.plus | 「用 AI 补全细节」（之前用了「整理」的 sparkles） |
| `archive` | archivebox | 「导出交接包…」（之前是下载箭头） |
| `minus-circle` | minus.circle | 「从 Blurt 移除」（之前是 ×） |
| `refresh` | arrow.clockwise | 「全部重新扫描」（之前是逆时针的「重来」） |
| `history` | clock.arrow.circlepath | 存储「自动删除」 |
| `sync` | arrow.triangle.2.circlepath | 存储「缓存（可重建）」 |
| `captions` | captions.bubble | 备用：实时字幕（Windows 还没有这一行） |
| `character-bubble` | character.bubble | 模型页「翻译」 |
| `lines` | line.3.horizontal | Agent 设置的拖动把手 |
| `align-left` | text.alignleft | 听写页「没有记录」空状态、命令面板「拷贝全文」 |
| `window` | macwindow | 会话「在桌面端进行」卡片 |

`text-cursor`（纯 I 形光标）没动：Mac 的引导页用它画「听写」的图块（GlyphTile.brand(.textCursor)），Windows 欢迎页照旧。

## 设置侧栏（SettingsCatalog.panes，Agent 由 SettingsWindow 改成 terminal）

| 面板 | Mac | Windows 之前 | 现在 |
|------|-----|-------------|------|
| 通用 | gearshape | settings（滑杆） | settings（齿轮） |
| 听写 | character.cursor.ibeam（中文系统显示「字I」） | text-cursor（只有 I） | character-cursor（A + I 形光标） |
| 截图取字 | text.viewfinder | screen（显示器） | text-viewfinder |
| 模型 | cpu | waveform | cpu |
| 快捷键 | keyboard | keyboard ✓ | keyboard |
| 项目 | folder | folder ✓ | folder |
| Agent | terminal | terminal ✓ | terminal |
| 隐私 | hand.raised | eye | hand |
| 存储 | internaldrive | document | drive |

## 主窗口

| 位置 | Mac | Windows 之前 | 现在 |
|------|-----|-------------|------|
| 工具栏 侧栏按钮 | sidebar.left | 手画 16 网格 SidebarGlyph | sidebar |
| 工具栏 录制 | record.circle | record ✓ | record |
| 工具栏 截图 | camera.viewfinder | screenshot（= snap，取景框 + 镜头）✓ | snap |
| 侧栏 待处理 | tray | inbox ✓ | inbox |
| 侧栏 进行中 | circle.righthalf.filled | 手画 ProgressGlyph | progress |
| 侧栏 未归类 | 虚线圆（IslandGlyph.noProject） | 手画 UnassignedGlyph | unassigned |
| 侧栏 全部事项 | list.bullet.rectangle | list | list-box |
| 侧栏 听写 | character.cursor.ibeam | text-cursor | character-cursor |
| 侧栏 项目 | 族里的 folder，项目色描边 + 28% 底色（IslandGlyph.project / ProjectLook） | 手画的实心文件夹 | 族里 folder 的路径，项目色描边 + 28% 底色 |
| 侧栏 找不到的项目 | questionmark.folder | 手画 | folder-missing |
| 侧栏 当前项目标记 | scope | 手画 ScopeGlyph | scope |
| 侧栏 打开文件夹 | plus | plus ✓ | plus |
| 侧栏底栏 设置 | （Mac 在应用菜单） | settings-gear → 滑杆 | settings（齿轮） |
| 列表 筛选 | line.3.horizontal.decrease.circle / .fill | 手画 FilterGlyph | filter / filter-fill |
| 列表 ＋ 新建 | plus | plus ✓ | plus |
| 任务行 | record.circle / camera.viewfinder / waveform / sparkles / arrow.triangle.branch / apple.terminal | record / screenshot / voice / spark / git-branch / terminal ✓ | 同左 |
| 详情 没有选中 | sidebar.right | SidebarGlyph（左侧栏） | sidebar-right |
| 详情 横幅（新） | 状态环 / exclamationmark.circle / 品牌转圈 / ellipsis.circle | 没有横幅 | StatusRing / warning / mw-spinner / more |

### 事项右键菜单 · 多选 ⋯ · 命令面板（MainWindowController.itemMenu、CommandPalette）

| 命令 | Mac | Windows 之前 | 现在 |
|------|-----|-------------|------|
| 交给 Agent | 「已交给」状态环 | StatusRing ✓ | StatusRing |
| 打开会话 | apple.terminal | terminal ✓ | terminal |
| 移到项目 ▸ | arrow.turn.up.right | send（纸飞机，和「交给」撞了） | move |
| 　└ 某个项目 | folder | 彩色 ProjectGlyph | folder |
| 　└ 未归类 | tray.2 | UnassignedGlyph | tray-2 |
| 　└ 打开文件夹… | folder.badge.plus | folder-plus ✓ | folder-plus |
| 种类 ▸ | tag | tag ✓ | tag |
| 重命名 | pencil | pencil ✓ | pencil |
| 用 AI 补全细节 | text.badge.plus | spark | text-plus |
| 拷贝 ▸ | doc.on.doc | copy ✓ | copy |
| 拷贝全文（面板） | text.alignleft | document | align-left |
| 导出交接包… | archivebox | download | archive |
| Quick Look / 打开图片 | eye | eye ✓ | eye |
| 在访达中显示 / 在文件资源管理器中显示 | arrow.up.forward.app | reveal（文件夹 + 箭头） | reveal（保留：Windows 的去处是文件资源管理器，文件夹比「跳出 App」更贴切） |
| 在编辑器中打开 | chevron.left.forwardslash.chevron.right | code ✓ | code |
| 查看整次采集 | rectangle.stack | cards ✓ | cards |
| 状态动作 | 各自通往的状态环 | StatusRing ✓ | StatusRing |

### 项目右键菜单

| 命令 | Mac | Windows 之前 | 现在 |
|------|-----|-------------|------|
| 找到它… | questionmark.folder | 手画 | folder-missing |
| 设为当前项目 | scope | 手画 | scope |
| 置顶 / 取消置顶 | pin / pin.slash | 手画 | pin / pin-off |
| 重命名 | pencil | pencil ✓ | pencil |
| 项目设置… | slider.horizontal.3 | settings（当时是滑杆，现在 settings 是齿轮） | sliders |
| 显示 / 编辑器 / 拷贝路径 | arrow.up.forward.app / chevron…/ doc.on.doc | reveal / code / copy ✓ | 同左 |
| 从 Blurt 移除 | minus.circle | x | minus-circle |

### ⋯ 菜单（Mac 菜单栏命令的去处）

| 命令 | Mac（菜单栏 / 命令面板） | Windows 之前 | 现在 |
|------|------------------------|-------------|------|
| 新建事项 / 打开文件夹 / 最近打开 | plus / folder.badge.plus / folder | ✓ | 同左 |
| 全部重新扫描 | arrow.clockwise | restart | refresh |
| 显示或隐藏侧栏 | sidebar.left | SidebarGlyph | sidebar |
| 显示或隐藏详情 | sidebar.right | document | sidebar-right |
| 命令面板 / 快捷键 / 使用指南 | magnifyingglass / keyboard / questionmark.circle | ✓ | 同左 |
| 设置 | gearshape | settings（滑杆） | settings（齿轮） |

## 设置页里的行

| 位置 | Mac | Windows 之前 | 现在 |
|------|-----|-------------|------|
| 存储 录屏和截图 | record.circle | record ✓ | record |
| 存储 视频 | film | film ✓ | film |
| 存储 自动删除 | clock.arrow.circlepath | restart | history |
| 存储 模型 / 没有模型 | waveform / wand.and.stars / cpu | waveform / waveform | waveform / cpu |
| 存储 缓存 | arrow.triangle.2.circlepath | restart | sync |
| 存储 听写记录 / 听写音频 | character.cursor.ibeam / waveform | text-cursor / waveform | character-cursor / waveform |
| 存储 Agent 运行 / 任务 / 交接 / 提示词 / 临时 | paperplane / list.bullet.rectangle / doc.text / text.quote / tray | send / list / document / quote / inbox | send / list-box / document / quote / inbox |
| 模型 识别（批量 / 语音备注） | video / mic | film / mic | video / mic |
| 模型 听写 | character.cursor.ibeam | text-cursor | character-cursor |
| 模型 润色 / 翻译 / 看图识字 | wand.and.stars / character.bubble / text.viewfinder | wand / languages / screen | wand / character-bubble / text-viewfinder |
| Agent 拖动把手 | line.3.horizontal | list（带圆点） | lines |
| 会话 列表开关 / 桌面端卡片 | sidebar.left / macwindow | list / screen | sidebar / window |

## 没动的（和 Mac 一致或有 Windows 的原因）

- 种类图标（bug / lightbulb / checkbox / document / tag）、状态环：两边是同一套自家字形（system.md §2.6），本来就一致。
- 审核组件（web/packages/review）里的图标：Mac 和 Windows 渲染的是同一个组件，同一套 `<Icon>`。
- 灵动岛、便签、截图选择器（web/apps/overlays）：已由各自那一轮对齐（island.md、snap-and-note.md），本轮没发现比喻不一致。
- 托盘菜单：Windows 原生托盘菜单不带图标（Windows 惯例），Mac 菜单栏菜单的 SF Symbols 不搬。
- 欢迎页：已经和 Mac 的引导页同一套（text-cursor、snap、copy、languages、mic、record）。

- 听写的「字 + 光标」（11-02 Windows 试用）：SF Symbols 的 `character.cursor.ibeam` 在中文里画的是「字」，英文是「A」。
  `assets/icons/character-cursor-zh.svg` 是中文那一版（同样 1.75 线宽、同一个光标），`@blurt/icons` 的 `resolveIcon`
  在页面 `<html lang>` 为 zh 时把 `character-cursor` 换成它，侧栏、设置、命令面板一起跟着变。
