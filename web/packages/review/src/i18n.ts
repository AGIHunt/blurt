export type Lang = "en" | "zh";

const en = {
  focus: "Focus", list: "List", keep: "Keep", drop: "Drop", merge: "Merge ↑", undo: "Undo", finish: "Finish review",
  pending: "to review", kept: "kept", dropped: "dropped",
  module: "Module", owner: "Owner", actual: "Actual", expected: "Expected", steps: "Steps to reproduce",
  code: "Suspected code", quote: "They said",
  playOrig: "Play from recording", answer: "Your answer…", ask: "Needs your input", sevHigh: "High", sevMedium: "Medium",
  sevLow: "Low", frame: "Frame", clip: "Clip", orig: "Recording", noMedia: "No screenshot", saved: "Saved",
  saving: "Saving…", kept1: "Kept", dropped1: "Dropped", merged: "Merged into", undone: "Undone", copy: "copied",
  all: "All", filterPending: "To review", filterKept: "Kept", filterDropped: "Dropped",
  search: "Search title, module, tags…", keysTitle: "Keyboard shortcuts", confirmTitle: "Hand this back to your agent?",
  confirmBody: "{k} kept · {d} dropped · {p} not reviewed yet.", pendingAs: "Treat unreviewed as kept",
  reviewRest: "Review the rest", confirm: "Confirm & continue", cancel: "Cancel",
  doneTitle: "All set — back to your agent", doneBody: "You can close this tab. Your agent picks it up from here.",
  doneBodyApp: "Your agent picks it up from here.", download: "Download", reviewTitle: "blurt review",
  k_next: "Next / previous", k_keep: "Keep and go next", k_drop: "Drop and go next", k_undo: "Undo",
  k_merge: "Merge into previous", k_sev: "Severity high / medium / low", k_media: "Previous / next frame",
  k_play: "Play clip or recording", k_edit: "Edit title", k_ov: "Overview", k_view: "Focus ⇄ list",
  k_finish: "Finish review", k_help: "This panel", k_fix: "Fix with agent",
  overview: "Overview", allKinds: "All kinds", summary: "The idea", summaryNote: "Summary", why: "Why",
  inspired_by: "Inspired by", next_steps: "Next steps", open_questions: "Still open", details: "Details", due: "Due",
  tags: "Tags", source: "Source (URL)", items: "items",
  working: "Working… {n} items so far, adding screenshots", stalled: "{n} items · your agent seems to have stopped",
  finished: "Screenshots are in", waitShot: "Adding screenshot…",
  stillProc: "Screenshots are still coming in. You can hand it back now — your agent finishes them in the background.",
  saveError: "Could not save. Please retry.", theme: "Theme", shortcuts: "Shortcuts ?", langName: "English",
  // v2: fix records and native affordances
  fix_fixing: "Fixing…", fix_fixed: "Fixed", fix_wontfix: "Won't fix", fix_reopened: "Reopened", fixHistory: "Fix history",
  fixWithAgent: "Fix with agent", reveal: "Show in Finder", revealWin: "Show in folder", quickLook: "Quick Look",
  openCode: "Open in editor", noItem: "This item is no longer in the session.", byAgent: "by {a}",
  prev: "Previous", next: "Next", close: "Close", ok: "OK",
};
type Dict = typeof en;

const zh: Dict = {
  focus: "专注", list: "列表", keep: "保留", drop: "丢弃", merge: "并入上一条", undo: "撤销", finish: "完成审核",
  pending: "待审", kept: "保留", dropped: "丢弃",
  module: "所属模块", owner: "负责人", actual: "实际效果", expected: "预期效果", steps: "复现步骤", code: "疑似代码位置",
  quote: "你当时说", playOrig: "回到录屏这一刻", answer: "在这里回答…", ask: "需要你确认", sevHigh: "严重",
  sevMedium: "一般", sevLow: "轻微", frame: "截图", clip: "片段", orig: "原录屏", noMedia: "没有截图", saved: "已保存",
  saving: "保存中…", kept1: "已保留", dropped1: "已丢弃", merged: "已并入", undone: "已撤销", copy: "已复制",
  all: "全部", filterPending: "待审", filterKept: "保留", filterDropped: "丢弃", search: "搜索标题、模块、标签…",
  keysTitle: "快捷键", confirmTitle: "把整理结果交回 agent？", confirmBody: "保留 {k} 条 · 丢弃 {d} 条 · 还有 {p} 条没看。",
  pendingAs: "没看的也保留", reviewRest: "继续审", confirm: "确认并继续", cancel: "取消",
  doneTitle: "搞定，交回给 agent 了", doneBody: "可以关掉这个页面了，agent 会接着处理。", doneBodyApp: "agent 会接着处理。",
  download: "下载", reviewTitle: "口喷鸡审核",
  k_next: "下一条 / 上一条", k_keep: "保留并下一条", k_drop: "丢弃并下一条", k_undo: "撤销", k_merge: "并入上一条",
  k_sev: "严重程度 高 / 中 / 低", k_media: "上一张 / 下一张图", k_play: "播放片段或原录屏", k_edit: "编辑标题",
  k_ov: "总览", k_view: "专注 ⇄ 列表", k_finish: "完成审核", k_help: "显示本面板", k_fix: "交给 agent 修",
  overview: "总览", allKinds: "全部类型", summary: "想法", summaryNote: "概述", why: "为什么", inspired_by: "灵感来源",
  next_steps: "下一步", open_questions: "待想清楚", details: "详情", due: "截止", tags: "标签", source: "来源链接",
  items: "条", working: "整理中… 已出 {n} 条，截图补充中", stalled: "已出 {n} 条 · 整理好像停了",
  finished: "截图都补齐了", waitShot: "截图补充中…", stillProc: "截图还在补充中。现在交回也可以，agent 会在后台补齐。",
  saveError: "保存失败，请重试。", theme: "主题", shortcuts: "快捷键 ?", langName: "中文",
  fix_fixing: "修复中…", fix_fixed: "已修", fix_wontfix: "不修", fix_reopened: "重新打开", fixHistory: "修复记录",
  fixWithAgent: "交给 agent 修", reveal: "在访达中显示", revealWin: "在文件夹中显示", quickLook: "快速查看",
  openCode: "在编辑器中打开", noItem: "这条已经不在本次会话里了。", byAgent: "由 {a}",
  prev: "上一条", next: "下一条", close: "关闭", ok: "好",
};

export const KINDS: Record<Lang, Record<string, string>> = {
  en: { issue: "Issue", idea: "Idea", note: "Note", task: "Task" },
  zh: { issue: "问题", idea: "想法", note: "笔记", task: "待办" },
};
export const TYPES: Record<Lang, Record<string, string>> = {
  en: { bug: "Bug", ui: "UI", ux: "UX", copy: "Copy", perf: "Perf" },
  zh: { bug: "Bug", ui: "界面", ux: "体验", copy: "文案", perf: "性能" },
};

export type Key = keyof Dict;
export const DICTS: Record<Lang, Dict> = { en, zh };

export const toLang = (s: string | null | undefined): Lang => (String(s || "").startsWith("zh") ? "zh" : "en");
