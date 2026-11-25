# Windows 安装程序（NSIS）和 Mac 的 DMG

Mac 装口喷鸡是一个 DMG 窗口：一张图，把它拖进「应用程序」。Windows 用 Tauri 的 NSIS 向导（安装到 `%LOCALAPPDATA%\Blurt`，
只给当前用户，不要管理员权限）。页面顺序由 Tauri 的模板定（欢迎 → 已安装时的维护页 → 文件夹 → 进度 → 完成），我们只能通过
`installer/hooks.nsh` 改字、改图和行为。

## 视觉门 r1（11-03）

| 页面 | 评审问题 | 处理 |
|------|---------|------|
| 欢迎 | MUI 原文「安装前请关闭其他所有应用程序……更新所需的系统文件」对按用户安装不成立；「点击 [下一步(N)] 继续」；没有版本号；侧图的点阵在 1× 下像噪点，和右边白页之间一条硬边 | `MUI_WELCOMEPAGE_TITLE/TEXT`：「安装 Blurt 1.0.x」+ 一句「装在这台电脑上，只给当前 Windows 账户用。不需要管理员权限，也不用关闭别的程序。」侧图（`import_peep.py --only installer`）去掉点阵，右边 48 px 渐变到页面的白，Peep 放在视觉中线 |
| 文件夹 | 原文带 [浏览(B)...] 和孤字换行 | `MUI_DIRECTORYPAGE_TEXT_TOP` 一句话。保留不同：这一页还在（Tauri 模板里它的 PRE 函数不能从 hook 换掉），只是安静了 |
| 进度 / 安装完成 | 装完还停在进度页，要再点一次下一步；「显示详情」暴露 NSIS 日志 | `NSIS_HOOK_POSTINSTALL` 里 `SetAutoClose true`，装完直接到完成页；`ShowInstDetails nevershow` |
| 安装后图标 | 桌面快捷方式可能一直是 Windows 给 exe 的通用图标，更新也不恢复 | `NSIS_HOOK_POSTINSTALL` 里 `${RefreshShellIcons}`，见文末「安装后的图标」 |
| 完成 | 标题「Blurt 安装程序结束」说的是安装程序；「点击 [完成(F)]…」；桌面快捷方式默认勾上 | 标题「Blurt 已装好」，一句「它在屏幕顶部和任务栏通知区域里运行。按右 Alt 开始听写。」；「打开 Blurt」勾着，桌面快捷方式默认不勾（`MUI_FINISHPAGE_SHOWREADME_NOTCHECKED`；开始菜单里已经有） |
| 内页页眉 | Peep 图在左边，标题被挤到中间 | `MUI_HEADERIMAGE_RIGHT`，页眉图重画（Peep 贴右边，整只在框里），标题回到正文左边距 |

hooks.nsh 存成带 BOM 的 UTF-8（里面有中文的 LangString，语言用数字 id 1033 / 2052，因为 hook 在 `MUI_LANGUAGE` 之前就被包含）。
在 Mac 上用 `makensis`（`LC_ALL=en_US.UTF-8`）按模板的页顺序编过一个测试脚本，没有错误。

## 欢迎页的版本号（11-22，#110）

r1 写了「安装 Blurt 1.0.x」，但从 1.0.12 起装出来的都是「安装 Blurt ${VERSION}」。原因：Tauri 的 `installer.nsi` 先 `!include` 这份 hooks
（2.12 里在第 36 行），之后才 `!define VERSION`（第 43 行），hooks 里写到 `${VERSION}` 的时候它还不存在。NSIS 不报错：`LangString` 的值
原样存进语言表，连警告都没有（换成别的运行时字符串才会有一行 `unknown variable` 的警告）。在 Mac 上编测试脚本「没有错误」，说的只是这个。

现在版本号在编安装包的时候就读进来：hooks 用 `!searchparse /file` 读旁边 `tauri.conf.json` 里的 `"version"`，也就是 `tauri build` 放进
安装包版本信息的那个数，照原样写（`1.1.0`，预发布的 `1.0.13-alpha.1` 也是完整的）。读不到就 `!error`，编不过，不会带着错的标题发出去。
不从安装包的版本信息里反过来读：那里只有四段数字（`1.1.0.0`），预发布的那一截就丢了。
`tests/test_windows_installer.py` 守着两处：hooks 里不再用 Tauri 后来才定义的名字；hooks 读的还是 `tauri.conf.json`，文件里第一个 `"version"`
就是应用自己的版本，平台自己的配置（`tauri.windows.conf.json`）里没有另写一个。
在 Mac 上验证的办法（Tauri 2.12 自带的和 Homebrew 的都是 NSIS 3.13）：按模板的顺序编一个测试脚本（hooks 在前，`VERSION` 在后），把生成的
exe 的头部解出来，看语言表里那一串。现在的配置、预发布版本号、Windows 换行符、带空格的路径都试过，标题是「安装 Blurt 1.1.0」这样的定稿；
去掉版本号、拿走配置文件，编到 hooks 就停了。Windows 上也真的编过一次（`desktop.yml` 手动跑在分支上，NSIS 和 MSI 都出了）：把那个安装包的
头部解出来，语言表里是「安装 Blurt 1.1.0」和「Install Blurt 1.1.0」。
还没在 Windows 上看装好的欢迎页。

还没改的（要换 Tauri 模板或 `customLanguageFiles` 整份语言文件）：维护页的「添加/重新安装组件」和它没有新版本号的说明；
升级时跳过维护页；侧图 / 页眉的 2× 版本（MUI 按 1× 拉伸）。安装完后应用开在旧窗口位置、语言和主题跟着旧配置，是应用首启的事，不是安装程序的。
还没在 Windows 上重拍（VM 已释放）。

## 安装后的图标（11-25）

用户装完，桌面的快捷方式是 Windows 给「没有图标的 exe」的那张通用图标（不是白页）。安装包没少东西：`blurt.exe` 里有 16 / 24 / 32 / 48 /
64 / 256 六档（都是 PNG），在 Windows Server 2022 上正常显示。

在 Windows Server 2022 虚拟机上重现（向导逐页点完，勾桌面快捷方式；「旧」是 1.1.3 的 hooks，「新」加了 `${RefreshShellIcons}`，
文件都是 1.1.3 的；每次先卸载、删掉快捷方式、重启资源管理器。图标缓存文件没删干净，资源管理器马上又建了）：

| 情形 | 旧 | 新 |
|------|----|----|
| 系统已记住通用图标，应用内更新（`/P /UPDATE`，快捷方式不重写） | 仍是通用图标 | 恢复 |
| 系统已记住通用图标，重装并勾桌面快捷方式 | 恢复 | 没测 |
| 装的时候 `blurt.exe` 被别的程序独占（像杀毒软件在扫），装完才放开 | 通用图标，放开 20 秒后还是 | 同旧；之后用新安装包更新一次就恢复 |
| 系统已记住通用图标，装的时候被独占，完成页出现时放开，勾桌面快捷方式 | 正常 | 正常 |

所以安装程序这一句管得住的是「更新后图标还是坏的」，管不住「首次安装时 exe 正被占着」：那时候刷新，读到的还是通用图标。
用户那台是不是这种情形还没确认（截图里装了火绒，没有证据说是它）。

首次安装由应用自己补一次（`src/shell_icons.rs`，`housekeeping::start` 的线程里）。装的时候 exe 被独占、装完放开、图标已坏之后，
每种做法都从干净安装重来一遍：

| 放开之后 | 桌面图标 |
|----------|------|
| 什么都不做 | 通用图标（等了 20 秒） |
| 只启动 1.1.3 的应用 | 仍是通用图标 |
| 只对 exe 发 `SHCNE_UPDATEITEM` | 仍是通用图标 |
| `SHCNE_ASSOCCHANGED` | 恢复 |
| 打开 1.1.3 加上 `shell_icons.rs` 编出来的应用 | 恢复（没装过、卸载后重装同版本各测了） |
| 同一个应用，记录说这次安装已经发过（对照） | 仍是通用图标 |

对 exe 和快捷方式都发 `SHCNE_UPDATEITEM` 也能恢复，但快捷方式可能被移走、改名，或者钉在任务栏上，应用不知道它们在哪，所以用
`SHCNE_ASSOCCHANGED`。它让资源管理器重读所有图标，所以每次安装只发一次：`$BLURT_HOME/run/shell-icons` 记着版本号和旁边
`uninstall.exe` 的修改时间，更新、卸载重装都会再发一次，平常启动不发（第二次启动记录没变）。先写记录再发，写不进去就不发。调试版不发。
不用 exe 自己的时间：NSIS 解出来的文件带的是打包时的创建和修改时间，重装同一个版本认不出来（第一版这样写，卸载重装后没有刷新）。
MSI 没有 `uninstall.exe`，只看版本号；MSI 装的没测。完成页上勾「打开 Blurt」、应用启动时 exe 还被别的程序占着的情形也没测。

- 试过在 `.onGUIEnd`（安装器关窗口）再刷新一次，管完成页上才建的桌面快捷方式：没有一种情形因此不同，写快捷方式这件事本身就会让系统重读图标，
  所以没留。
- `${RefreshShellIcons}`（`FileFunc.nsh`，Tauri 已经包含）就是 `SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST, NULL, NULL)`；
  [微软文档](https://learn.microsoft.com/en-us/windows/win32/api/shlobj_core/nf-shlobj_core-shchangenotify)说它让系统丢掉图标和缩略图缓存。
- 不要在 hooks 里自己 `!define SHCNE_ASSOCCHANGED`：Tauri 2.12 先包含的 `FileAssociation.nsh` 已经定义了它，NSIS 报 `already defined` 就停了，
  而 `desktop.yml` 在 PR 上不跑，要到发版才会发现。`tests/test_windows_installer.py` 要求 hooks 只定义 `MUI_`、`BLURT` 开头的名字。
- 编译用的是 Tauri 2.12.3 的整份模板（handlebars 变量自己填，NSIS 3.13，在 Mac 上）；`desktop.yml` 里的真编译还没跑。Windows 10 / 11 没试。
