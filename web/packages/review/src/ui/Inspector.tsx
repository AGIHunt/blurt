import { useLayoutEffect, useRef, useState } from "react";
import type { FixRecord, Item } from "../host";
import { fieldLabel } from "../fields";
import { isEnter } from "../ime";
import { fmt, kindOf, SEV } from "../store";
import { statusOf } from "../sync";
import { Egg } from "./icons";
import { Icon } from "./Icon";
import { cx, useStore } from "./ctx";
import { isMacLike } from "./TopBar";

type FieldType = "text" | "area" | "list" | "tags" | "src";

/** keys the inspector never shows as generic lens fields */
const RESERVED = new Set(["id", "uid", "kind", "title", "quote", "time", "frames", "clip", "source", "tags", "confidence",
  "questions", "answer", "status", "exported", "merged_from", "severity", "type", "fix", "fix_history", "schema"]);
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
  if (type === "tags") return v.split(/[,，]/).map((x) => x.trim()).filter(Boolean);
  return v;
}

function autosize(el: HTMLTextAreaElement | null, max: number) {
  if (!el) return;
  el.style.height = "auto";
  el.style.height = Math.min(el.scrollHeight + 2, max) + "px";
}

/** One editable field. While it has focus it shows what the user typed, whatever the server sends meanwhile;
    after blur it shows the item's value again (which by then includes the user's edit). */
function Field({ i, k, label, type = "area", cls, title, placeholder }: { i: Item; k: string; label?: string; type?: FieldType; cls?: string; title?: boolean; placeholder?: string }) {
  const s = useStore();
  const [draft, setDraft] = useState<string | null>(null);
  const ref = useRef<HTMLTextAreaElement & HTMLInputElement>(null);
  const value = draft ?? format(i, k, type);
  const multiline = type === "area" || type === "list" || title;
  useLayoutEffect(() => {
    if (multiline) autosize(ref.current, title ? 200 : 260);
  }, [value, multiline, title]);
  const props = {
    ref,
    value,
    "data-k": k,
    placeholder: title ? undefined : (placeholder ?? "—"),
    onFocus: () => setDraft(format(i, k, type)),
    onBlur: () => setDraft(null),
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
  if (title) return <textarea className="title" rows={1} aria-label="Title" {...props} />;
  const box = multiline ? <textarea rows={1} {...props} /> : <input {...props} />;
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
const when = (at: number | undefined, lang: string) => {
  if (!at) return "";
  const d = new Date(at * 1000);
  return d.toLocaleString(lang === "zh" ? "zh-CN" : "en", { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" });
};

export function FixChip({ fix }: { fix: FixRecord }) {
  const s = useStore();
  return (
    <span className={cx("chip fix", "fx-" + fix.state)} title={fix.note || undefined} id="fixChip">
      <span className="fxd" />
      {s.t(("fix_" + fix.state) as never)}
      {fix.commit ? <code>{shortSha(fix.commit)}</code> : null}
    </span>
  );
}

function FixHistory({ i }: { i: Item }) {
  const s = useStore();
  if (!i.fix) return null;
  const rows = [...(i.fix_history || []), i.fix].reverse();
  return (
    <div className="f fixlog">
      <label>{s.t("fixHistory")}</label>
      <ol>
        {rows.map((f, n) => (
          <li key={n} className={"fx-" + f.state}>
            <span className="fxd" />
            <span className="fxs">{s.t(("fix_" + f.state) as never)}</span>
            {f.agent && f.agent !== "human" ? <span className="fxa">{s.t("byAgent").replace("{a}", f.agent)}</span> : null}
            {f.commit ? <code>{shortSha(f.commit)}</code> : null}
            {f.pr ? (
              <a href={f.pr} target="_blank" rel="noreferrer">
                PR <Icon name="external-link" size={11} />
              </a>
            ) : null}
            <span className="fxt">{when(f.at, s.lang)}</span>
            {f.note ? <div className="fxn">{f.note}</div> : null}
          </li>
        ))}
      </ol>
    </div>
  );
}

export function Inspector() {
  const s = useStore();
  const side = useRef<HTMLElement>(null);
  const i = s.item;
  useLayoutEffect(() => {
    if (side.current) side.current.scrollTop = 0;
  }, [i?.id]);
  if (!i) return <aside className="side insp scroll" id="side" ref={side} />;
  const st = statusOf(i);
  const sev = (SEV as readonly string[]).includes(String(i.severity)) ? String(i.severity) : "medium";
  const kind = kindOf(i);
  const types = s.types;
  const F = (k: string, label: string, type: FieldType = "area", cls?: string) => <Field key={i.id + k} i={i} k={k} label={label} type={type} cls={cls} />;
  let body: React.ReactNode[] = [];
  if (kind === "issue") {
    body = [
      <div className="grid2" key="g">
        {F("module", s.t("module"), "text")}
        {F("owner", s.t("owner"), "text")}
      </div>,
      F("actual", s.t("actual"), "area", "act-f"),
      F("expected", s.t("expected"), "area", "exp"),
      F("steps", s.t("steps"), "list"),
    ];
    if ((i.code_refs || []).length)
      body.push(
        <div className="f" key="code">
          <label>{s.t("code")}</label>
          <div className="code">
            {i.code_refs!.map((c) => (
              <button key={c} data-copy={c} title={s.host.openCode ? s.t("openCode") : undefined}
                onClick={() => (s.host.openCode ? s.host.openCode(c) : s.copy(c))}>
                <span>{c}</span>
                <em>{s.host.openCode ? <Icon name="code" size={13} /> : <Icon name="copy" size={13} />}</em>
              </button>
            ))}
          </div>
        </div>,
      );
  } else if (kind === "idea") {
    body = [F("summary", s.t("summary"), "area", "big"), F("why", s.t("why")), F("inspired_by", s.t("inspired_by")), F("next_steps", s.t("next_steps"), "list")];
    if (i.open_questions) body.push(F("open_questions", s.t("open_questions"), "list"));
  } else if (kind === "task") {
    body = [
      F("details", s.t("details")),
      <div className="grid2" key="g">
        {F("owner", s.t("owner"), "text")}
        {F("due", s.t("due"), "text")}
      </div>,
    ];
  } else {
    body = [F("summary", s.t("summaryNote"), "area", "big")];
    if (i.details !== undefined || kind === "note") body.push(F("details", s.t("details")));
  }
  // anything else the lens added: shown generically so custom lenses just work
  for (const [k, v] of Object.entries(i)) {
    if (RESERVED.has(k) || SHOWN.has(k) || k.startsWith("_")) continue;
    if (typeof v === "string") body.push(F(k, fieldLabel(k, s.lang)));
    else if (Array.isArray(v) && v.every((x) => typeof x === "string")) body.push(F(k, fieldLabel(k, s.lang), "list"));
  }
  body.push(
    <div className="grid2" key="ts">
      {F("tags", s.t("tags"), "tags")}
      {F("source", s.t("source"), "src")}
    </div>,
  );
  body.push(<FixHistory key="fixlog" i={i} />);

  return (
    <aside className="side insp scroll" id="side" ref={side}>
      <div className="idrow">
        <span>{i.id || ""}</span>
        {i.merged_from?.length ? <span>+ {i.merged_from.join(", ")}</span> : null}
        {s.mode === "review" && (
          <>
            <span className="pos">
              {s.cur + 1} / {s.data.items.length}
            </span>
            <span className="nav">
              <button data-nav="-1" title="↑ / K" aria-label={s.t("prev")} onClick={() => s.go(s.cur - 1, "down")}>
                <Icon name="chevron-up" />
              </button>
              <button data-nav="1" title="↓ / J" aria-label={s.t("next")} onClick={() => s.go(s.cur + 1, "up")}>
                <Icon name="chevron-down" />
              </button>
            </span>
          </>
        )}
      </div>
      <Field key={i.id + ":title"} i={i} k="title" title />
      <div className="chips">
        {st === "keep" ? (
          <span className="chip st-keep">
            <Icon name="check" />
            {s.t("kept1")}
          </span>
        ) : st === "drop" ? (
          <span className="chip st-drop">
            <Icon name="x" />
            {s.t("dropped1")}
          </span>
        ) : null}
        <span className="chip kind-chip">
          <Egg kind={kind} /> {s.kindLabel(kind)}
        </span>
        {kind === "issue" && (
          <>
            <button className={"chip sev-" + sev} id="sevChip" title="1 / 2 / 3" onClick={s.cycleSev}>
              <span className="sw" style={{ background: "currentColor" }} />
              {s.t(("sev" + sev[0].toUpperCase() + sev.slice(1)) as never)}
            </button>
            <button className="chip" id="typeChip" onClick={s.cycleType}>
              {types[String(i.type)] || (i.type as string) || "—"}
            </button>
          </>
        )}
        {i.confidence === "low" && (
          <span className="chip" style={{ color: "var(--amber)" }}>
            ?
          </span>
        )}
        {i.fix && <FixChip fix={i.fix} />}
      </div>
      {s.host.fixWithAgent && (
        <button className="btn fixbtn" id="fixBtn" onClick={s.fixWithAgent}>
          <Icon name="wand" size={15} /> {s.t("fixWithAgent")}
          {s.mode === "item" && <kbd>{isMacLike() ? "⌘⏎" : "Ctrl ⏎"}</kbd>}
        </button>
      )}
      {(i.questions || []).length > 0 && (
        <div className="ask">
          <div className="h">
            <Icon name="help-circle" size={14} /> {s.t("ask")}
          </div>
          {i.questions!.map((q, n) => (
            <div className="qq" key={n}>
              {q}
            </div>
          ))}
          <AnswerField i={i} />
        </div>
      )}
      {i.quote && (
        <div className="quote">
          <Icon name="quote" className="qmark" />
          {i.quote}
          <div className="meta">
            {i.time && i.time.start != null ? `${fmt(i.time.start)} – ${fmt(i.time.end)}` : ""}
            {s.hasVideo(i) && (
              <button className="linkbtn" id="origBtn" onClick={s.playOrig}>
                <Icon name="play" size={12} /> {s.t("playOrig")} <kbd>O</kbd>
              </button>
            )}
          </div>
        </div>
      )}
      <div className="fields">{body}</div>
    </aside>
  );
}

function AnswerField({ i }: { i: Item }) {
  const s = useStore();
  return <Field key={i.id + ":answer"} i={i} k="answer" type="text" placeholder={s.t("answer")} />;
}
