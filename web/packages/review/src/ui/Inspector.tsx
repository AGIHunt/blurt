import { canDo, stateOf } from "@blurt/ui";
import { KindIcon, StatusRing } from "@blurt/ui/react";
import { useEffect, useLayoutEffect, useRef, useState } from "react";
import type { FixRecord, Item, WorkRecord } from "../host";
import { fieldLabel } from "../fields";
import { isEnter } from "../ime";
import { isTitle, kindOf, SEV, type ReviewStore } from "../store";
import { Icon, type IconName } from "./Icon";
import { cx, useStore } from "./ctx";
import { agentName, StateControl } from "./Queue";
import { isMacLike } from "./TopBar";
import { MovePicker } from "./Views";

type FieldType = "text" | "area" | "list" | "tags" | "src";

/** keys the inspector never shows as generic lens fields */
const RESERVED = new Set(["id", "uid", "kind", "title", "quote", "time", "frames", "clip", "source", "tags", "confidence",
  "questions", "answer", "state", "restore_to", "status", "exported", "merged_from", "merged_into", "severity", "type", "fix", "fix_history",
  "schema", "work", "work_history", "project", "project_by", "project_confidence", "suggested_project", "created",
  "updated", "path", "store", "aliases", "language", "assignee"]);
const SHOWN = new Set(["module", "owner", "actual", "expected", "steps", "code_refs", "summary", "why", "inspired_by",
  "next_steps", "open_questions", "details", "due"]);

function format(i: Item, k: string, type: FieldType): string {
  if (type === "src") return i.source?.url || "";
  if (type === "tags") return (i.tags || []).join(", ");
  if (type === "list") return ((i[k] as string[]) || []).map((x, n) => (k === "steps" ? `${n + 1}. ${x}` : `- ${x}`)).join("\n");
  const v = i[k];
  return v == null ? "" : String(v);
}
function parse(v: string, type: FieldType): unknown {
  if (type === "list") return v.split("\n").map((x) => x.replace(/^\s*(\d+[.)、]|[-*•])\s*/, "").trim()).filter(Boolean);
  if (type === "tags") return v.split(/[,，、]/).map((x) => x.trim()).filter(Boolean);
  return v;
}

function autosize(el: HTMLTextAreaElement | null, max: number) {
  if (!el) return;
  el.style.height = "auto";
  el.style.height = Math.min(el.scrollHeight + 2, max) + "px";
}

/** One editable field. While it has focus it shows what the user typed, whatever the server sends meanwhile;
    after blur it shows the item's value again (which by then includes the user's edit). */
function Field({ i, k, label, type = "area", cls, title, placeholder, onFocus }: { i: Item; k: string; label?: string; type?: FieldType; cls?: string; title?: boolean; placeholder?: string; onFocus?: () => void }) {
  const s = useStore();
  const [draft, setDraft] = useState<string | null>(null);
  const ref = useRef<HTMLTextAreaElement & HTMLInputElement>(null);
  const atFocus = useRef("");
  const value = draft ?? format(i, k, type);
  const multiline = type === "area" || type === "list" || title;
  useLayoutEffect(() => {
    if (multiline) autosize(ref.current, title ? 200 : 260);
  }, [value, multiline, title]);
  // the pane can change width after the first layout (the embedded detail settles, fonts load): fit the height again,
  // or a title that wraps differently shows half of its second line
  useEffect(() => {
    const el = ref.current;
    if (!multiline || !el || typeof ResizeObserver === "undefined") return;
    let w = el.clientWidth;
    const ro = new ResizeObserver(() => {
      if (el.clientWidth === w) return;
      w = el.clientWidth;
      autosize(el, title ? 200 : 260);
    });
    ro.observe(el);
    return () => ro.disconnect();
  }, [multiline, title]);
  const props = {
    ref,
    value,
    "data-k": k,
    placeholder: title ? undefined : placeholder,
    onFocus: () => {
      onFocus?.();
      atFocus.current = format(i, k, type);
      setDraft(atFocus.current);
    },
    onBlur: () => {
      // an emptied title is never saved (setField refuses it): put back the one it had when editing began
      if (title && draft !== null && !isTitle(draft) && isTitle(atFocus.current)) {
        if (i.title !== atFocus.current) s.setField(i, k, atFocus.current);
        s.showToast(s.t("toast.title_empty"), false, "x");
      }
      setDraft(null);
    },
    onChange: (e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement>) => {
      setDraft(e.target.value);
      s.setField(i, k, parse(e.target.value, type));
    },
    onKeyDown: (e: React.KeyboardEvent) => {
      // single-line fields (and the title) commit on Enter — never the Enter that picks an IME candidate
      if (e.key !== "Enter" || e.shiftKey || e.metaKey || e.ctrlKey) return;
      if (!isEnter(e)) return;
      if (!multiline || title) {
        e.preventDefault();
        e.stopPropagation(); // this Enter commits the field; it must not also reach the page's Enter = keep
        (e.currentTarget as HTMLElement).blur();
      }
    },
  };
  if (title) return <textarea className="title" rows={1} aria-label={s.t("field.title")} {...props} />;
  const box = multiline ? <textarea rows={1} aria-label={label} {...props} /> : <input aria-label={label ?? placeholder} {...props} />;
  if (k === "answer") return box;
  return (
    <div className={cx("f", cls)}>
      <label>
        {label}
        <Icon name="pencil" className="pen" />
      </label>
      {box}
    </div>
  );
}

const shortSha = (c?: string | null) => (c ? String(c).slice(0, 7) : "");
const pct = (s: ReviewStore, x: number | null | undefined) => (x == null ? "" : s.i18n.formatNumber(x, { style: "percent", maximumFractionDigits: 0 }));

/** v2 fix records shown as work records (K3 mapping), so one history renders both */
function fixAsWork(f: FixRecord): WorkRecord {
  return { state: stateOf({ status: "confirmed", fix: f }), agent: f.agent, commit: f.commit, pr: f.pr, note: f.note, at: f.at,
    claim: f.state === "fixed" ? "fixed" : f.state === "wontfix" && f.agent !== "human" ? "wontfix" : null,
    by: f.agent === "human" ? "user" : "agent" };
}

/** What happened with the work (K3 `work`): who and when, commit, PR, what the agent claims, its note — and, when an
    agent says it's finished, the two answers right there (the state pill's menu has every action). */
function WorkPanel({ i }: { i: Item }) {
  const s = useStore();
  const st = s.stateOf(i);
  const rec = i.work ?? (i.fix ? fixAsWork(i.fix) : undefined);
  if (!rec || st === "new" || st === "discarded") return null;
  const who = rec.by === "user" ? s.t("work.by_you") : rec.agent && rec.agent !== "human" ? s.t("work.by", { who: agentName(rec.agent) }) : "";
  const when = rec.at ? s.i18n.formatRelative(rec.at) : "";
  // one Open Session per item: while it is with the agent a host banner may have it (the Mac app), else it is here
  const banner = s.host.sessionBanner && (st === "handed_off" || st === "in_progress");
  const session = rec.to === "session" && rec.job && s.host.openSession && st !== "done" && st !== "wontfix" && !banner ? rec.job : null;
  const verify = st === "to_verify";
  const meta = who || when || rec.commit || rec.pr;
  if (!meta && !verify && !rec.note && !session) return null;
  // the host's banner already says who has it and when: a card with only that line would repeat it
  if (banner && !verify && !rec.note && !rec.commit && !rec.pr) return null;
  return (
    <div className={cx("work", "s-" + st)} id="workRow">
      {meta && (
        <div className="work-h">
          {(who || when) && <span className="work-m">{[who, when].filter(Boolean).join(" · ")}</span>}
          {rec.commit ? <code title={rec.commit}>{shortSha(rec.commit)}</code> : null}
          {rec.pr ? (
            <a className="linkbtn" href={rec.pr} target="_blank" rel="noreferrer">
              <Icon name="git-pull-request" size={13} /> {s.t("work.pr")}
            </a>
          ) : null}
        </div>
      )}
      {verify && rec.claim && <p className="work-claim">{s.t(rec.claim === "wontfix" ? "work.claim.wontfix" : "work.claim.fixed")}</p>}
      {rec.note ? <p className="work-note">{rec.note}</p> : null}
      {(verify || session) && (
        <div className="work-a">
          {verify && (
            <>
              <button className="btn sm keep" id="workDone" onClick={() => s.act([i], "done")}>
                <StatusRing state="done" size={14} /> {s.t("action.done")}
              </button>
              <button className="btn sm" id="workBack" onClick={() => s.act([i], "send_back")}>
                <StatusRing state="todo" size={14} /> {s.t("action.send_back")}
              </button>
            </>
          )}
          {session && (
            <button className="btn sm" id="workSession" onClick={() => s.openSession(session)}>
              <Icon name="terminal" size={14} /> {s.t("work.open_session")}
            </button>
          )}
        </div>
      )}
    </div>
  );
}

/** K6: hand the item to an agent — inside Blurt (dispatch), or a copied instruction / full text for your own agent */
function HandoffPanel({ i }: { i: Item }) {
  const s = useStore();
  const h = s.host;
  if (!h.dispatch && !s.canHandoff) return null;
  if (!canDo("hand_off", s.stateOf(i))) return null;
  return (
    <div className="handoff" id="handoffRow" aria-label={s.t("handoff.title")}>
      {h.dispatch && (
        <button className="btn sm primary" id="dispatchBtn" title={s.t("handoff.dispatch.hint")} onClick={() => s.dispatch([i])}>
          <Icon name="terminal" size={14} /> {s.t("handoff.dispatch")}
          {s.mode === "item" && <kbd>{isMacLike() ? "⌘⏎" : "Ctrl ⏎"}</kbd>}
        </button>
      )}
      {s.canHandoff && (
        <>
          <button className="btn sm" id="copyInstruction" title={s.t("handoff.copy_instruction.hint")} onClick={() => void s.handoff([i], "instruction")}>
            <Icon name="copy" size={14} /> {s.t("handoff.copy_instruction")}
          </button>
          <button className="btn sm ghost" id="copyFull" title={s.t("handoff.copy_full.hint")} onClick={() => void s.handoff([i], "full")}>
            {s.t("handoff.copy_full")}
          </button>
        </>
      )}
    </div>
  );
}

function WorkHistory({ i }: { i: Item }) {
  const s = useStore();
  // work_history holds each earlier step (the state it was in); the newest row is the item now
  const rows: WorkRecord[] = i.work
    ? [...(i.work_history || []), { ...i.work, state: s.stateOf(i) }]
    : i.fix
      ? [...(i.fix_history || []), i.fix].map(fixAsWork)
      : [];
  if (rows.length < 2 && !(rows[0]?.state && rows[0].state !== "todo" && rows[0].state !== "new")) return null;
  return (
    <div className="f worklog">
      <label>{s.t("work.history")}</label>
      <ol>
        {[...rows].reverse().map((f, n) => (
          <li key={n} className={"s-" + (f.state ?? "todo")}>
            <span className="wls">{s.stateLabel(f.state ?? "todo")}</span>
            {f.agent && f.agent !== "human" ? <span className="wla">{s.t("work.by", { who: agentName(f.agent) })}</span> : null}
            {f.commit ? <code>{shortSha(f.commit)}</code> : null}
            {f.pr ? (
              <a href={f.pr} target="_blank" rel="noreferrer">
                PR <Icon name="external-link" size={11} />
              </a>
            ) : null}
            <span className="wlt">{f.at ? s.i18n.formatDate(f.at) : ""}</span>
            {f.note ? <div className="wln">{f.note}</div> : null}
          </li>
        ))}
      </ol>
    </div>
  );
}

const SOURCE_ICON: Record<string, IconName> = { recording: "video", snap: "snap", voice: "waveform", url: "external-link", import: "download", service: "agent" };

/** where the item came from and how it got into this project (K1 source, K2 project_by / suggestion) */
function Provenance({ i }: { i: Item }) {
  const s = useStore();
  const src = i.source || {};
  const rows: [string, React.ReactNode][] = [];
  const type = src.type;
  const p = s.project(i.project);
  const sug = i.suggested_project && s.project(i.suggested_project.id);
  if (i.created) rows.push([s.t("source.captured"), <span title={s.i18n.formatDate(i.created, { dateStyle: "full", timeStyle: "short" })}>{s.i18n.formatDate(i.created)}</span>]);
  if (src.by) rows.push([s.t("source.by"), String(src.by)]);
  if (src.app) rows.push([s.t("source.app"), String(src.app)]);
  if (src.url)
    rows.push([s.t("source.page"), <a href={String(src.url)} target="_blank" rel="noreferrer" className="trunc">{String(src.url).replace(/^https?:\/\//, "")}</a>]);
  if (src.session)
    rows.push([s.t("source.session"), s.host.reveal ? (
      <button className="linkbtn trunc" onClick={() => s.host.reveal!(String(src.session))} title={s.t("source.session.reveal")}>
        <Icon name="folder" size={12} /> {String(src.session).split(/[\\/]/).pop()}
      </button>
    ) : <span className="trunc">{String(src.session).split(/[\\/]/).pop()}</span>]);
  if (i.aliases?.length) rows.push([s.t("source.aliases"), s.i18n.formatList(i.aliases)]);
  if (i.merged_from?.length) {
    const ids = i.merged_from.map((u) => s.data.items.find((x) => x.uid === u)?.id || (u.length > 12 ? u.slice(0, 8) + "…" : u));
    rows.push([s.t("source.merged_from"), s.i18n.formatList(ids)]);
  }
  // "captured in this project" says nothing on an item that has no project (Unassigned)
  const by = i.project_by && p && !(i.project_by === "capture" && (i.project || "inbox") === "inbox") ? i.project_by : null;
  if (!type && !rows.length && !by) return null;
  return (
    <section className="prov" id="provenance" aria-label={s.t("source.title")}>
      <h4>{s.t("source.title")}</h4>
      {type && (
        <div className="prov-t">
          <Icon name={SOURCE_ICON[type] ?? "info"} size={14} />
          <span>{s.i18n.has(`source.type.${type}`) ? s.t(`source.type.${type}`) : type}</span>
          {type === "recording" && i.time?.start != null ? <span className="mute">· {s.t("source.at", { time: s.clock(i.time.start) })}</span> : null}
        </div>
      )}
      {by && (
        <div className="prov-t">
          <Icon name={by === "ai" ? "spark" : by === "user" ? "pencil" : by === "migrate" ? "restart" : "folder"} size={14} />
          <span>{s.t(`project.by.${by}`, { pct: pct(s, i.project_confidence) })}</span>
        </div>
      )}
      {sug && i.project !== sug.id && s.canMove && (
        <div className="prov-sug" title={s.t("project.suggested.hint", { pct: pct(s, i.suggested_project!.confidence), reason: i.suggested_project!.reason || "" })}>
          <Icon name="spark" size={14} />
          <span>{s.t("project.suggested", { project: s.projectName(sug) })}</span>
          <button className="btn sm" id="acceptSuggestion" onClick={() => s.moveTo([i], sug.id)}>
            {s.t("project.accept")}
          </button>
        </div>
      )}
      {rows.length > 0 && (
        <dl>
          {rows.map(([k, v]) => (
            <div key={k}>
              <dt>{k}</dt>
              <dd>{v}</dd>
            </div>
          ))}
        </dl>
      )}
    </section>
  );
}

/** One field of the inspector: key, label, editor type, class; `pair` sets two short ones side by side. */
type Spec = { k: string; label: string; type?: FieldType; cls?: string; pair?: string };

/** The kind's fields, in order. The first is the kind's body: shown even when empty, with a prompt for a placeholder. */
function specsOf(i: Item, kind: string, s: ReviewStore): { body: Spec; prompt: string; rest: Spec[] } {
  const t = (k: string) => s.t(k);
  let body: Spec, prompt: string, rest: Spec[];
  if (kind === "issue") {
    body = { k: "actual", label: t("field.actual"), cls: "act-f" };
    prompt = t("field.prompt.actual");
    rest = [{ k: "module", label: t("field.module"), type: "text", pair: "who" }, { k: "owner", label: t("field.owner"), type: "text", pair: "who" },
      { k: "expected", label: t("field.expected"), cls: "exp" }, { k: "steps", label: t("field.steps"), type: "list" }];
  } else if (kind === "idea") {
    body = { k: "summary", label: t("field.summary.idea"), cls: "big" };
    prompt = t("field.prompt.idea");
    rest = [{ k: "why", label: t("field.why") }, { k: "inspired_by", label: t("field.inspired_by") },
      { k: "next_steps", label: t("field.next_steps"), type: "list" }, { k: "open_questions", label: t("field.open_questions"), type: "list" }];
  } else if (kind === "task") {
    body = { k: "details", label: t("field.details") };
    prompt = t("field.prompt.task");
    rest = [{ k: "owner", label: t("field.owner"), type: "text", pair: "when" }, { k: "due", label: t("field.due"), type: "text", pair: "when" }];
  } else {
    body = { k: "summary", label: t("field.summary"), cls: "big" };
    prompt = t("field.prompt.note");
    rest = [{ k: "details", label: t("field.details") }];
  }
  // anything else the lens added: shown generically so custom lenses just work
  for (const [k, v] of Object.entries(i)) {
    if (RESERVED.has(k) || SHOWN.has(k) || k.startsWith("_")) continue;
    if (typeof v === "string") rest.push({ k, label: fieldLabel(k, s.i18n) });
    else if (Array.isArray(v) && v.every((x) => typeof x === "string")) rest.push({ k, label: fieldLabel(k, s.i18n), type: "list" });
  }
  rest.push({ k: "tags", label: t("field.tags"), type: "tags", pair: "end" }, { k: "source", label: t("field.source_url"), type: "src", pair: "end" });
  return { body, prompt, rest };
}

/** The empty fields, as a quiet menu at the end: picking one shows it, focused. */
function AddField({ specs, onAdd }: { specs: Spec[]; onAdd: (k: string) => void }) {
  const s = useStore();
  if (!specs.length) return null;
  return (
    <label className="pick btn sm ghost addf">
      <Icon name="plus" size={14} />
      <span className="pick-l">{s.t("field.add")}</span>
      <select id="addField" value="" aria-label={s.t("field.add")} onChange={(e) => e.target.value && onAdd(e.target.value)}>
        <option value="" disabled>
          {s.t("field.add")}
        </option>
        {specs.map((f) => (
          <option key={f.k} value={f.k}>
            {f.label}
          </option>
        ))}
      </select>
    </label>
  );
}

export function Inspector() {
  const s = useStore();
  const side = useRef<HTMLElement>(null);
  const i = s.item;
  const ik = i ? s.keyOf(i) : "";
  // fields the user opened (from the add menu, or by focusing one): they stay while this item is showing, even emptied;
  // leaving the item forgets them. The focus request is one-shot, so coming back never puts the caret in a field (J/K would type).
  const [opened, setOpened] = useState<{ ik: string; keys: string[] }>({ ik: "", keys: [] });
  const focusNext = useRef<string | undefined>(undefined);
  const open = (k: string, focus?: boolean) => {
    if (focus) focusNext.current = k;
    setOpened((o) => (o.ik === ik && o.keys.includes(k) ? o : { ik, keys: o.ik === ik ? [...o.keys, k] : [k] }));
  };
  useLayoutEffect(() => {
    if (side.current) side.current.scrollTop = 0;
    focusNext.current = undefined;
    setOpened((o) => (o.ik === ik ? o : { ik, keys: [] }));
  }, [ik]);
  useEffect(() => {
    const k = focusNext.current;
    if (!k) return;
    focusNext.current = undefined;
    side.current?.querySelector<HTMLElement>(`.fields [data-k="${k}"]`)?.focus();
  });
  if (!i) return <aside className="side insp scroll" id="side" ref={side} />;
  const sev = (SEV as readonly string[]).includes(String(i.severity)) ? String(i.severity) : "medium";
  const kind = kindOf(i);
  const F = (f: Spec, placeholder?: string) => (
    <Field key={ik + f.k} i={i} k={f.k} label={f.label} type={f.type} cls={f.cls} placeholder={placeholder} onFocus={() => open(f.k)} />
  );
  // only what has something in it (or the user opened); the rest wait in the add menu
  const { body: main, prompt, rest } = specsOf(i, kind, s);
  const kept = opened.ik === ik ? opened.keys : [];
  const shown = rest.filter((f) => kept.includes(f.k) || format(i, f.k, f.type ?? "area").trim() !== "");
  const body: React.ReactNode[] = [F(main, prompt)];
  if (kind === "issue" && (i.code_refs || []).length)
    body.push(
      <div className="f" key="code">
        <label>{s.t("field.code_refs")}</label>
        <div className="code">
          {i.code_refs!.map((c) => (
            <button key={c} data-copy={c} title={s.host.openCode ? s.t("media.open_code") : s.t("media.copy")}
              onClick={() => (s.host.openCode ? s.host.openCode(c) : s.copy(c))}>
              <span>{c}</span>
              <em>{s.host.openCode ? <Icon name="code" size={13} /> : <Icon name="copy" size={13} />}</em>
            </button>
          ))}
        </div>
      </div>,
    );
  for (let n = 0; n < shown.length; n++) {
    const f = shown[n];
    const next = shown[n + 1];
    if (f.pair && next?.pair === f.pair) {
      body.push(
        <div className="grid2" key={"g" + f.pair}>
          {F(f)}
          {F(next)}
        </div>,
      );
      n++;
    } else body.push(F(f));
  }
  body.push(<AddField key="add" specs={rest.filter((f) => !shown.includes(f))} onAdd={(k) => open(k, true)} />);

  return (
    <aside className="side insp scroll" id="side" ref={side}>
      <div className="idrow">
        <span className="iid">{i.id || ""}</span>
        {s.canMove && <MovePicker items={[i]} id="projectPick" current={i.project || "inbox"} />}
        {s.mode === "review" && (
          <>
            <span className="pos">
              {s.i18n.formatNumber(s.cur + 1)} / {s.i18n.formatNumber(s.data.items.length)}
            </span>
            <span className="nav">
              <button data-nav="-1" title={s.t("action.prev") + " · ↑ K"} aria-label={s.t("action.prev")} onClick={() => s.go(s.cur - 1, "down")}>
                <Icon name="chevron-up" />
              </button>
              <button data-nav="1" title={s.t("action.next") + " · ↓ J"} aria-label={s.t("action.next")} onClick={() => s.go(s.cur + 1, "up")}>
                <Icon name="chevron-down" />
              </button>
            </span>
          </>
        )}
      </div>
      <Field key={ik + ":title"} i={i} k="title" title />
      <div className="chips">
        <StateControl i={i} id="statePill" shortcuts controlled />
        <span className="chip kind-chip">
          <KindIcon kind={kind} size={14} /> {s.kindLabel(kind)}
        </span>
        {kind === "issue" && (
          <>
            <button className={"chip sev-" + sev} id="sevChip" title="1 / 2 / 3" onClick={s.cycleSev}>
              <span className="sw" />
              {s.t("severity." + sev)}
            </button>
            <button className="chip" id="typeChip" onClick={s.cycleType}>
              {i.type ? s.typeLabel(String(i.type)) : s.t("chip.type")}
            </button>
          </>
        )}
        {i.confidence === "low" && (
          <span className="chip low" title={s.t("chip.low_confidence.hint")}>
            <Icon name="help-circle" /> {s.t("chip.low_confidence")}
          </span>
        )}
      </div>
      <WorkPanel i={i} />
      <HandoffPanel i={i} />
      {(i.questions || []).length > 0 && (
        <div className="ask">
          <div className="h">
            <Icon name="help-circle" size={14} /> {s.t("ask.title")}
          </div>
          {i.questions!.map((q, n) => (
            <div className="qq" key={n}>
              {q}
            </div>
          ))}
          <Field key={ik + ":answer"} i={i} k="answer" type="text" placeholder={s.t("field.answer")} />
        </div>
      )}
      {i.quote && (
        <div className="quote">
          <Icon name="quote" className="qmark" />
          <span className="ql">{s.t("field.quote")}</span>
          {i.quote}
          <div className="meta">
            {i.time && i.time.start != null ? `${s.clock(i.time.start)} – ${s.clock(i.time.end)}` : ""}
            {s.hasVideo(i) && (
              <button className="linkbtn" id="origBtn" onClick={s.playOrig}>
                <Icon name="play" size={12} /> {s.t("media.play_original")} <kbd>O</kbd>
              </button>
            )}
          </div>
        </div>
      )}
      <div className="fields">{body}</div>
      <WorkHistory i={i} />
      <Provenance i={i} />
    </aside>
  );
}
