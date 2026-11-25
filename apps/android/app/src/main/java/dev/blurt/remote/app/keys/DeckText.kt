// The deck's words in the phone's language. Core keeps them in English (hints, captions, section and group names); a key the user named
// keeps its name. Simplified Chinese as on the iPhone (Resources/Localizable.xcstrings), plus the Windows and Linux keys.
package dev.blurt.remote.app.keys

import java.util.Locale

object DeckText {
    private val zh = mapOf(
        "Main" to "常用", "Letters" to "字母", "Symbols" to "符号", "More" to "更多", "Vibe Coding" to "Vibe Coding", "Switch" to "切换",
        "Edit" to "编辑", "Modifiers" to "修饰键", "Browser" to "浏览器", "Blurt" to "Blurt", "New Section" to "新分组",
        "Accept" to "接受", "Activities" to "活动", "Address" to "地址栏", "All Windows" to "所有窗口", "App Windows" to "App 窗口",
        "Apps" to "切换 App", "Arrows" to "方向键", "Back a Field" to "上一个输入框", "Previous Field" to "上一个输入框", "Back" to "后退", "Background" to "转入后台", "Cards" to "卡片",
        "Clear Screen" to "清屏", "Close Tab" to "关闭标签页", "Close Window" to "关闭窗口", "Command Palette" to "命令面板",
        "Command Shift" to "Command Shift", "Command" to "Command", "Complete" to "补全", "Autocomplete" to "补全", "Composer" to "Composer", "Control Shift" to "Control Shift",
        "Control" to "Control", "Copy in Terminal" to "在终端中复制", "Copy Text" to "截图取字", "Copy" to "复制", "Cut" to "剪切",
        "Delete Line" to "删除到行首", "Delete to Line Start" to "删除到行首", "Delete Word" to "删除单词", "Delete" to "删除", "Desktop Left" to "左侧桌面", "Desktop Right" to "右侧桌面",
        "Desktop" to "显示桌面", "Files" to "文件", "Find Pointer" to "查找指针", "Find" to "查找", "Forward Delete" to "向后删除",
        "Forward" to "前进", "History" to "历史", "Inline Edit" to "内联编辑", "Input Source" to "切换输入法", "Interrupt" to "中断",
        "Line End" to "行尾", "Line Start" to "行首", "Lock" to "锁屏", "New Line" to "换行", "New Tab" to "新标签页", "Next Tab" to "下一标签页",
        "Open File" to "打开文件", "Option 1" to "选项 1", "Option 2" to "选项 2", "Option 3" to "选项 3", "Paste" to "粘贴",
        "Previous Tab" to "上一标签页", "Record" to "录屏", "Redo" to "重做", "Reformat" to "更改风格", "Change Style" to "更改风格", "Reject" to "拒绝", "Reload" to "刷新",
        "Reopen Tab" to "恢复标签页", "Rewind" to "回退", "Save" to "保存", "Select All" to "全选", "Send" to "发送", "Sidebar" to "侧栏",
        "Snap" to "截图", "Snip" to "截取屏幕", "Space" to "空格", "Spotlight" to "Spotlight", "Start" to "开始菜单", "Stop" to "停止",
        "Task Manager" to "任务管理器", "Task View" to "任务视图", "Terminal Panel" to "终端面板", "Terminal" to "终端", "Transcript" to "详细记录",
        "Translate" to "翻译", "Undo" to "撤销", "Voice Note" to "语音备注", "Windows" to "切换窗口", "Word Left" to "上一单词",
        "Word Right" to "下一单词", "Zoom In" to "放大", "Zoom Out" to "缩小", "Option" to "Option", "Shift" to "Shift",
        "Next tab, ⌘⇧] in a terminal" to "下一标签页（终端中用 ⌘⇧]）",
        // the section templates (Deck.template)
        "Empty" to "空白", "Writing" to "写作", "Design" to "设计", "Presenting" to "演示", "Spreadsheet" to "表格",
        "Paste as Plain Text" to "纯文本粘贴", "Bold" to "加粗", "Italic" to "斜体", "Underline" to "下划线", "Duplicate" to "复制一份",
        "Group" to "编组", "Ungroup" to "取消编组", "Zoom to Fit" to "适合窗口", "Actual Size" to "实际大小", "Play" to "播放",
        "Play from Here" to "从当前页播放", "Black Screen" to "黑屏", "Project" to "投影", "Edit Cell" to "编辑单元格", "Clear" to "清除",
        "Previous Sheet" to "上一张表", "Next Sheet" to "下一张表", "Fill" to "填充",
        // what the screen costs (ScreenQuality)
        "Auto" to "自动", "Sharp" to "清晰", "Balanced" to "均衡", "Data Saver" to "省流量",
        "Uses less data on mobile networks" to "使用移动数据时节省流量",
        "Up to about 90 MB a minute, smoother on the same network" to "每分钟最多约 90 MB，同一网络下更流畅",
        "Up to about 30 MB a minute" to "每分钟最多约 30 MB",
        "Up to about 8 MB a minute" to "每分钟最多约 8 MB",
    )

    private val chinese: Boolean get() = Locale.getDefault().language == "zh" && Locale.getDefault().script != "Hant" &&
        Locale.getDefault().country !in setOf("TW", "HK", "MO")

    fun tr(english: String): String = if (chinese) zh[english] ?: english else english
}
