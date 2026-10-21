/* Labels for the fields an agent adds beyond the lens ("author", "suspected_cause", "rootCause"…): a zh / en label for
   the common ones, and a humanised key for the rest — never a raw snake_case / camelCase key in the UI. */
import type { Lang } from "./i18n";

type L2 = { zh: string; en: string };

/** keyed by the normalised key (snake_case, lower case): see normKey */
export const FIELD_LABELS: Record<string, L2> = {
  author: { zh: "作者", en: "Author" },
  reporter: { zh: "反馈人", en: "Reporter" },
  assignee: { zh: "指派给", en: "Assignee" },
  suspected_cause: { zh: "疑似原因", en: "Suspected cause" },
  root_cause: { zh: "根本原因", en: "Root cause" },
  cause: { zh: "原因", en: "Cause" },
  repro: { zh: "复现方式", en: "Repro" },
  repro_steps: { zh: "复现步骤", en: "Repro steps" },
  environment: { zh: "环境", en: "Environment" },
  env: { zh: "环境", en: "Environment" },
  browser: { zh: "浏览器", en: "Browser" },
  os: { zh: "操作系统", en: "OS" },
  device: { zh: "设备", en: "Device" },
  platform: { zh: "平台", en: "Platform" },
  url: { zh: "链接", en: "URL" },
  page: { zh: "页面", en: "Page" },
  screen: { zh: "界面", en: "Screen" },
  version: { zh: "版本", en: "Version" },
  app_version: { zh: "应用版本", en: "App version" },
  build: { zh: "构建号", en: "Build" },
  component: { zh: "组件", en: "Component" },
  area: { zh: "范围", en: "Area" },
  category: { zh: "分类", en: "Category" },
  priority: { zh: "优先级", en: "Priority" },
  impact: { zh: "影响", en: "Impact" },
  frequency: { zh: "出现频率", en: "Frequency" },
  workaround: { zh: "临时办法", en: "Workaround" },
  suggested_fix: { zh: "修复建议", en: "Suggested fix" },
  fix_suggestion: { zh: "修复建议", en: "Suggested fix" },
  error: { zh: "报错", en: "Error" },
  error_message: { zh: "报错信息", en: "Error message" },
  logs: { zh: "日志", en: "Logs" },
  notes: { zh: "备注", en: "Notes" },
  note: { zh: "备注", en: "Note" },
  context: { zh: "背景", en: "Context" },
  rationale: { zh: "理由", en: "Rationale" },
  acceptance_criteria: { zh: "验收标准", en: "Acceptance criteria" },
  effort: { zh: "工作量", en: "Effort" },
  deadline: { zh: "截止时间", en: "Deadline" },
  links: { zh: "相关链接", en: "Links" },
  references: { zh: "参考", en: "References" },
  related: { zh: "相关条目", en: "Related" },
};

/** "suspectedCause" / "Suspected-Cause" / "suspected cause" → "suspected_cause" */
export function normKey(k: string): string {
  return words(k).join("_");
}

function words(k: string): string[] {
  return String(k)
    .replace(/([a-z0-9])([A-Z])/g, "$1 $2") // camelCase
    .replace(/([A-Z]+)([A-Z][a-z])/g, "$1 $2") // HTTPServer → HTTP Server
    .split(/[\s_\-.:/]+/)
    .filter(Boolean)
    .map((w) => w.toLowerCase());
}

const ACRONYMS: Record<string, string> = {
  url: "URL", api: "API", id: "ID", os: "OS", ui: "UI", ux: "UX", sdk: "SDK", http: "HTTP", https: "HTTPS", ios: "iOS",
  css: "CSS", html: "HTML", js: "JS", pr: "PR", qa: "QA", ci: "CI", db: "DB", sql: "SQL", ip: "IP", cpu: "CPU", gpu: "GPU",
};

/** "suspected_cause" → "Suspected cause", "apiURL" → "API URL", "app-version" → "App version" */
export function humanizeKey(k: string): string {
  const ws = words(k).map((w) => ACRONYMS[w] ?? w);
  if (!ws.length) return String(k);
  const first = ws[0];
  ws[0] = first === first.toLowerCase() ? first[0].toUpperCase() + first.slice(1) : first;
  return ws.join(" ");
}

/** The label a field shows: the known zh / en label, else the humanised key (both languages). */
export function fieldLabel(k: string, lang: Lang): string {
  return FIELD_LABELS[normKey(k)]?.[lang] ?? humanizeKey(k);
}
