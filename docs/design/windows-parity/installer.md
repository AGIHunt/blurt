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
| 完成 | 标题「Blurt 安装程序结束」说的是安装程序；「点击 [完成(F)]…」；桌面快捷方式默认勾上 | 标题「Blurt 已装好」，一句「它在屏幕顶部和任务栏通知区域里运行。按右 Alt 开始听写。」；「打开 Blurt」勾着，桌面快捷方式默认不勾（`MUI_FINISHPAGE_SHOWREADME_NOTCHECKED`；开始菜单里已经有） |
| 内页页眉 | Peep 图在左边，标题被挤到中间 | `MUI_HEADERIMAGE_RIGHT`，页眉图重画（Peep 贴右边，整只在框里），标题回到正文左边距 |

hooks.nsh 存成带 BOM 的 UTF-8（里面有中文的 LangString，语言用数字 id 1033 / 2052，因为 hook 在 `MUI_LANGUAGE` 之前就被包含）。
在 Mac 上用 `makensis`（`LC_ALL=en_US.UTF-8`）按模板的页顺序编过一个测试脚本，没有错误。

还没改的（要换 Tauri 模板或 `customLanguageFiles` 整份语言文件）：维护页的「添加/重新安装组件」和它没有新版本号的说明；
升级时跳过维护页；侧图 / 页眉的 2× 版本（MUI 按 1× 拉伸）。安装完后应用开在旧窗口位置、语言和主题跟着旧配置，是应用首启的事，不是安装程序的。
还没在 Windows 上重拍（VM 已释放）。
