import { canDo, KINDS, stateOf } from "@blurt/ui";
import { KindIcon, StatusRing } from "@blurt/ui/react";
import { useEffect, useLayoutEffect, useRef, useState } from "react";
import type { FixRecord, Item, WorkRecord } from "../host";
import { fieldLabel } from "../fields";
import { isEnter } from "../ime";
import { listKey, type ListKey } from "../listedit";
import { isTitle, kindOf, SEV, type ReviewStore } from "../store";
import { Icon, type IconName } from "./Icon";
import { cx, useStore } from "./ctx";
import { agentName, StateControl } from "./Queue";
import { ItemMedia } from "./Stage";
import { isMacLike } from "./TopBar";
import { MovePicker } from "./Views";

type FieldType = "text" | "area" | "list" | "tags" | "src";

/** keys the inspector never shows as generic lens fields */
const RESERVED = new Set(["id", "uid", "kind", "title", "quote", "time", "frames", "clip", "source", "tags", "confidence",
  "questions", "answer", "state", "restore_to", "status", "exported", "merged_from", "merged_into", "severity", "type", "fix", "fix_history",
  "schema", "work", "work_history", "project", "project_by", "project_confidence", "suggested_project", "created",
  "updated", "path", "store", "aliases", "language", "assignee", "enrich"]);
/** shown by the kind's own layout (issue: its code refs): never repeated as a generic field */
const CUSTOM = new Set(["code_refs"]);

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
  const caretAfter = useRef<number | null>(null);
  useLayoutEffect(() => {
    if (multiline) autosize(ref.current, title ? 200 : 260);
    if (caretAfter.current != null && ref.current && document.activeElement === ref.current) {
      ref.current.setSelectionRange(caretAfter.current, caretAfter.current);
    }
    caretAfter.current = null;
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
      s.beginEdit(i, k); // focus to blur is one undo step
    },
    onBlur: () => {
      // an emptied title is never saved (setField refuses it): put back the one it had when editing began
      if (title && draft !== null && !isTitle(draft) && isTitle(atFocus.current) && i.title !== atFocus.current) {
        s.setField(i, k, atFocus.current);
      }
      setDraft(null);
      s.endEdit(i);
    },
    onChange: (e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement>) => {
      setDraft(e.target.value);
      s.setField(i, k, parse(e.target.value, type));
    },
    onKeyDown: (e: React.KeyboardEvent) => {
      const el = e.currentTarget as HTMLElement;
      // a list field edits as a list: Return continues it, ⌫ drops a marker, ⌃⌘↑↓ move an item (listedit.ts)
      if (type === "list" && !e.nativeEvent.isComposing) {
        const plain = !e.shiftKey && !e.metaKey && !e.ctrlKey && !e.altKey;
        const lk: ListKey | null = e.key === "Enter" && plain && isEnter(e) ? "enter" : e.key === "Backspace" && plain ? "backspace"
          : e.metaKey && e.ctrlKey && e.key === "ArrowUp" ? "up" : e.metaKey && e.ctrlKey && e.key === "ArrowDown" ? "down" : null;
        const ta = el as HTMLTextAreaElement;
        const r = lk && (ta.selectionStart === ta.selectionEnd || lk === "up" || lk === "down")
          ? listKey(ta.value, ta.selectionStart, lk, k === "steps") : null;
        if (r) {
          e.preventDefault();
          e.stopPropagation();
          setDraft(r.value);
          s.setField(i, k, parse(r.value, type));
          caretAfter.current = r.caret;
          if (r.done) el.blur();
          return;
        }
      }
      const done = () => {
        e.preventDefault();
        e.stopPropagation(); // the field's own key: never also the page's (Enter = keep, ⌘Enter = hand off, Esc)
        el.blur();
      };
      // Esc cancels the edit: the value it had when editing began comes back (re-saved if typing already saved)
      if (e.key === "Escape" && !e.nativeEvent.isComposing) {
        if (format(i, k, type) !== atFocus.current) s.setField(i, k, parse(atFocus.current, type));
        setDraft(atFocus.current);
        return done();
      }
      if (e.key !== "Enter" || e.shiftKey || !isEnter(e)) return;
      // Enter commits a single-line field and the title, ⌘Enter a multi-line one — never with an empty title
      const commits = e.metaKey || e.ctrlKey || !multiline || title;
      if (!commits) return;
      if (title && !isTitle(draft)) {
        e.preventDefault();
        e.stopPropagation();
        return;
      }
      done();
    },
  };
  if (title) {
    const empty = draft !== null && !isTitle(draft);
    return (
      <>
        <textarea className={cx("title", empty && "invalid")} rows={1} aria-label={s.t("field.title")} aria-invalid={empty || undefined}
          aria-describedby={empty ? "titleErr" : undefined} {...props} placeholder={s.t("field.title")} />
        {empty && (
          <p className="field-err" id="titleErr" role="status">
            {s.t("field.title_required")}
          </p>
        )}
      </>
    );
  }
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

/** A chip that opens a menu of its values (kind, severity, type) with the current one checked — a native <select>
    under the chip, so the host draws its own menu (arrow keys, Return picks, Esc closes). A pick is one undoable step. */
function ChipSelect({ id, cls, label, value, options, onPick, children }: {
  id: string; cls?: string; label: string; value: string; options: [string, string][]; onPick: (v: string) => void; children: React.ReactNode;
}) {
  return (
    <label className={cx("chip chip-pick", cls)} title={label}>
      {children}
      <Icon name="chevron-down" size={11} className="pick-ch" />
      <select id={id} value={value} aria-label={label} onChange={(e) => onPick(e.target.value)}>
        {options.map(([v, t]) => (
          <option key={v} value={v}>
            {t}
          </option>
        ))}
      </select>
    </label>
  );
}

/** Severity as its own glyph: three rising bars, as many filled as it is severe (low 1, medium 2, high 3) — the
    level reads in grayscale; only high takes the issue colour. No coloured chip fill: severity is the quietest property. */
function SevBars({ sev }: { sev: string }) {
  const n = sev === "high" || sev === "critical" ? 3 : sev === "low" ? 1 : 2;
  return (
    <svg className={cx("sevbars", "sev-" + sev)} width="14" height="14" viewBox="0 0 14 14" aria-hidden="true">
      {[0, 1, 2].map((k) => (
        <rect key={k} x={1.5 + k * 4.25} y={9 - k * 3.25} width="2.75" height={3.5 + k * 3.25} rx="1" className={k < n ? "on" : "off"} />
      ))}
    </svg>
  );
}

/** A voice note's recording: a session's shots/NNN.wav (source.session + source.shot), as the app writes it. */
export function voiceAudio(i: Item): string | null {
  const src = i.source;
  if (!src || src.type !== "voice" || !src.session || src.shot == null) return null;
  return `${String(src.session).replace(/[\\/]+$/, "")}/shots/${String(src.shot).padStart(3, "0")}.wav`;
}

/** Voice Memos' row for the recording itself: play, the waveform as a scrubber (brand ink: blurt's own capture), the
    length in tabular digits, and a ⋯ menu (Show in Finder, Download). The waveform is read from the wav; until then
    (or where it can't be read) a flat line holds its place — never a made-up shape. */
function VoiceCard({ rel }: { rel: string }) {
  const s = useStore();
  const h = s.host;
  const src = h.fileUrl(rel);
  const audio = useRef<HTMLAudioElement>(null);
  const [dur, setDur] = useState<number | null>(null);
  const [at, setAt] = useState(0);
  const [playing, setPlaying] = useState(false);
  const [peaks, setPeaks] = useState<number[] | null>(null);
  const [gone, setGone] = useState(false);
  useEffect(() => {
    let off = false;
    const AC = typeof window !== "undefined" ? window.AudioContext || (window as unknown as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext : undefined;
    if (!AC || typeof fetch === "undefined") return;
    (async () => {
      try {
        const r = await fetch(src);
        if (!r.ok) return;
        const ctx = new AC();
        const data = await ctx.decodeAudioData(await r.arrayBuffer());
        void ctx.close?.();
        const ch = data.getChannelData(0);
        const N = 72;
        const step = Math.max(1, Math.floor(ch.length / N));
        const out: number[] = [];
        for (let b = 0; b < N; b++) {
          let sum = 0;
          for (let x = b * step; x < Math.min(ch.length, (b + 1) * step); x++) sum += ch[x] * ch[x];
          out.push(Math.sqrt(sum / step));
        }
        const max = Math.max(...out, 1e-4);
        if (!off) {
          setPeaks(out.map((v) => Math.max(0.08, Math.min(1, v / max))));
          setDur((d) => d ?? data.duration);
        }
      } catch {
        /* the flat line stays */
      }
    })();
    return () => {
      off = true;
    };
  }, [src]);
  if (gone) return null;
  const total = dur ?? 0;
  const frac = total > 0 ? Math.min(1, at / total) : 0;
  const toggle = () => {
    const a = audio.current;
    if (!a) return;
    if (a.paused) void a.play().catch(() => setPlaying(false));
    else a.pause();
  };
  const seek = (e: React.MouseEvent<HTMLDivElement>) => {
    const a = audio.current;
    if (!a || !total) return;
    const r = e.currentTarget.getBoundingClientRect();
    a.currentTime = Math.max(0, Math.min(1, (e.clientX - r.left) / r.width)) * total;
    setAt(a.currentTime);
  };
  const bars = peaks ?? Array.from({ length: 72 }, () => 0.08);
  const reveal = h.reveal ? (h.host === "macos" ? s.label("media.reveal_mac") : s.label("media.reveal")) : null;
  const dl = h.download || h.downloadUrl ? s.label("media.download") : null;
  return (
    <div className={cx("voice", playing && "playing")} id="voiceCard" role="group" aria-label={s.t("voice.label")}>
      <button className="vplay" id="voicePlay" onClick={toggle} aria-label={s.t(playing ? "voice.pause" : "voice.play")} title={s.t(playing ? "voice.pause" : "voice.play")}>
        <Icon name={playing ? "pause-fill" : "play-fill"} size={14} />
      </button>
      <div className="vwave" onClick={seek} role="slider" aria-label={s.t("voice.position")} aria-valuemin={0}
        aria-valuemax={Math.round(total)} aria-valuenow={Math.round(at)} aria-valuetext={s.clock(at)} tabIndex={-1}>
        {bars.map((v, k) => (
          <i key={k} className={k / bars.length < frac ? "on" : undefined} style={{ height: `${Math.round(v * 100)}%` }} />
        ))}
      </div>
      <span className="vtime">{dur == null ? "" : playing || at > 0 ? `${s.clock(at)} / ${s.clock(total)}` : s.clock(total)}</span>
      {(reveal || dl) && (
        <label className="pick vmore" title={s.t("voice.more")}>
          <Icon name="more" size={16} />
          <select id="voiceMore" value="" aria-label={s.t("voice.more")} onChange={(e) => {
            const v = e.target.value;
            e.target.value = "";
            if (v === "reveal") h.reveal?.(rel);
            else if (v === "download") {
              if (h.download) h.download(rel);
              else if (h.downloadUrl) window.open(h.downloadUrl(rel), "_blank");
            }
          }}>
            <option value="" disabled>{s.t("voice.more")}</option>
            {reveal && <option value="reveal">{reveal}</option>}
            {dl && <option value="download">{dl}</option>}
          </select>
        </label>
      )}
      <audio ref={audio} src={src} preload="metadata"
        onLoadedMetadata={(e) => Number.isFinite(e.currentTarget.duration) && setDur(e.currentTarget.duration)}
        onTimeUpdate={(e) => setAt(e.currentTarget.currentTime)}
        onPlay={() => setPlaying(true)} onPause={() => setPlaying(false)}
        onEnded={(e) => { setPlaying(false); e.currentTarget.currentTime = 0; setAt(0); }}
        onError={() => setGone(true)} />
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
  const who = rec.by === "user" ? s.t("work.by_you") : rec.agent && rec.agent !== "human" ? s.t("work.by", { who: agentName(s, rec.agent) }) : "";
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
                <StatusRing state="done" size={14} /> {s.label("action.done")}
              </button>
              <button className="btn sm" id="workBack" onClick={() => s.act([i], "send_back")}>
                <StatusRing state="todo" size={14} /> {s.label("action.send_back")}
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
  // the one primary; its shortcut is in its tooltip, not a key cap inside it
  const key = s.mode === "item" ? ` (${isMacLike() ? "⌘⏎" : "Ctrl+Enter"})` : "";
  return (
    <div className="handoff" id="handoffRow" aria-label={s.t("handoff.title")}>
      {h.dispatch && (
        <button className="btn sm primary" id="dispatchBtn" title={s.t("handoff.dispatch.hint") + key} onClick={() => s.dispatch([i])}>
          <Icon name="send" size={14} /> {s.t("handoff.dispatch")}
        </button>
      )}
      {s.canHandoff && (
        // the two copies are one control: Copy Instruction, and the full text in its menu (a split button)
        <span className="split" role="group" aria-label={s.label("handoff.copy_instruction")}>
          <button className="btn sm" id="copyInstruction" title={s.t("handoff.copy_instruction.hint")} onClick={() => void s.handoff([i], "instruction")}>
            <Icon name="copy" size={14} /> {s.label("handoff.copy_instruction")}
          </button>
          <label className="btn sm pick split-ch" title={s.t("handoff.copy_more")}>
            <Icon name="chevron-down" size={12} />
            <select id="copyMenu" value="" aria-label={s.t("handoff.copy_more")} onChange={(e) => {
              const v = e.target.value as "instruction" | "full" | "";
              e.target.value = "";
              if (v) void s.handoff([i], v);
            }}>
              <option value="" disabled>{s.t("handoff.copy_more")}</option>
              <option value="instruction" title={s.t("handoff.copy_instruction.hint")}>{s.label("handoff.copy_instruction")}</option>
              <option value="full" id="copyFull" title={s.t("handoff.copy_full.hint")}>{s.label("handoff.copy_full")}</option>
            </select>
          </label>
        </span>
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
            {f.agent && f.agent !== "human" ? <span className="wla">{s.t("work.by", { who: agentName(s, f.agent) })}</span> : null}
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

const SOURCE_ICON: Record<string, IconName> = { recording: "video", snap: "snap", voice: "waveform", dictation: "mic", url: "external-link", import: "download", service: "agent" };

/** "com.apple.TextEdit" → "TextEdit": an older dictation row stored the app's bundle id; people see its last part */
export const appLabel = (app: string) => (/^[a-z0-9-]+(\.[A-Za-z0-9-]+){2,}$/.test(app) ? app.split(".").pop()! : app);

/** A capture folder ("20261025-101010-shots") as the moment it was made, in the reader's format; null if it isn't one. */
export function sessionWhen(s: ReviewStore, dir: string): string | null {
  const m = /^(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})/.exec(dir.split(/[\\/]/).pop() || "");
  if (!m) return null;
  const d = new Date(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +m[6]);
  return s.i18n.formatDate(d.toISOString(), { dateStyle: "medium", timeStyle: "short" });
}

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
  if (src.app) rows.push([s.t("source.app"), appLabel(String(src.app))]);
  if (src.url)
    rows.push([s.t("source.page"), <a href={String(src.url)} target="_blank" rel="noreferrer" className="trunc">{String(src.url).replace(/^https?:\/\//, "")}</a>]);
  if (src.session) {
    // when it was captured, not the folder's name (the folder is one click away)
    const when = sessionWhen(s, String(src.session)) ?? s.t("source.session.unnamed");
    // in the footer line: "Original capture" as a link to its folder, when it was made in the tooltip
    rows.push([s.t("source.session"), s.host.reveal ? (
      <button className="linkbtn" onClick={() => s.host.reveal!(String(src.session))} title={`${when} · ${s.t("source.session.reveal")}`}>
        <Icon name="folder" size={12} /> {s.t("source.session")}
      </button>
    ) : <span className="trunc" title={when}>{s.t("source.session")} {when}</span>]);
  }
  if (i.aliases?.length) rows.push([s.t("source.aliases"), s.i18n.formatList(i.aliases)]);
  if (i.merged_from?.length) {
    // an item merged in that this doc no longer lists has no id to show here: say how many, never its uid
    const known = i.merged_from.map((u) => s.data.items.find((x) => x.uid === u || x.id === u)?.id).filter((x): x is string => !!x);
    const other = i.merged_from.length - known.length;
    const parts = other ? [...known, s.plural("source.merged_earlier", other)] : known;
    rows.push([s.t("source.merged_from"), s.i18n.formatList(parts)]);
  }
  // "captured in this project" says nothing on an item that has no project (Unassigned)
  const by = i.project_by && p && !(i.project_by === "capture" && (i.project || "inbox") === "inbox") ? i.project_by : null;
  if (!type && !rows.length && !by && !sug) return null;
  // one quiet line, the way a mail's header says where it's from: "Voice note · Oct 26, 1:10 AM · john" — the labels
  // only where a bare value wouldn't say what it is
  const bare = new Set([s.t("source.captured"), s.t("source.by"), s.t("source.session")]);
  const parts: React.ReactNode[] = [];
  if (type)
    parts.push(
      <span className="prov-t" key="type">
        <Icon name={SOURCE_ICON[type] ?? "info"} size={13} />
        {s.i18n.has(`source.type.${type}`) ? s.t(`source.type.${type}`) : type}
        {type === "recording" && i.time?.start != null ? ` ${s.t("source.at", { time: s.clock(i.time.start) })}` : ""}
      </span>,
    );
  for (const [k, v] of rows)
    parts.push(
      <span key={k} className="prov-v">
        {bare.has(k) ? null : <span className="prov-k">{k} </span>}
        {v}
      </span>,
    );
  if (by) parts.push(<span key="by" className="prov-v">{s.t(`project.by.${by}`, { pct: pct(s, i.project_confidence) })}</span>);
  return (
    <section className="prov" id="provenance" aria-label={s.t("source.title")}>
      {/* an Unassigned item's suggestion from its organizing run: only a suggestion, one click moves it (K2) */}
      {sug && (i.project || "inbox") === "inbox" && s.canMove && (
        <div className="prov-sug" title={
            i.suggested_project!.reason
              ? s.t("project.suggested.hint", { reason: i.suggested_project!.reason })
              : s.t("project.suggested.hint_plain")
          }>
          <Icon name="spark" size={14} />
          <span>{s.t("project.suggested", { project: s.projectName(sug) })}</span>
          <button className="btn sm" id="acceptSuggestion" onClick={() => s.moveTo([i], sug.id)}>
            {s.t("project.accept")}
          </button>
        </div>
      )}
      {parts.length > 0 && (
        <p className="prov-line">
          {parts.map((x, n) => (
            <span key={n} className="prov-p">
              {n > 0 && <span className="prov-dot" aria-hidden="true"> · </span>}
              {x}
            </span>
          ))}
        </p>
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
    // what "done" means is what the agent is handed: the user sees and edits it too (dogfood-2 W34)
    rest = [{ k: "expected", label: t("field.done_when") }, { k: "steps", label: t("field.task_steps"), type: "list" },
      { k: "owner", label: t("field.owner"), type: "text", pair: "when" }, { k: "due", label: t("field.due"), type: "text", pair: "when" }];
  } else {
    body = { k: "summary", label: t("field.summary"), cls: "big" };
    prompt = t("field.prompt.note");
    rest = [{ k: "details", label: t("field.details") }];
  }
  // anything else the item holds: shown generically, so custom lenses just work and no stored field is ever hidden
  // (another kind's field — an idea's `expected` after a kind change — included)
  const own = new Set([body.k, ...rest.map((f) => f.k)]);
  for (const [k, v] of Object.entries(i)) {
    if (RESERVED.has(k) || own.has(k) || k.startsWith("_") || (kind === "issue" && CUSTOM.has(k))) continue;
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
  // a voice note's words are its body: the empty summary waits in Add field instead of a prompt under the transcript
  const voice = i.source?.type === "voice";
  const said = voice && !!(i.quote || "").trim();
  const audio = voiceAudio(i);
  const mainShown = !said || kept.includes(main.k) || format(i, main.k, main.type ?? "area").trim() !== "";
  const body: React.ReactNode[] = mainShown ? [F(main, prompt)] : [];
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
  body.push(<AddField key="add" specs={[...(mainShown ? [] : [main]), ...rest.filter((f) => !shown.includes(f))]} onAdd={(k) => open(k, true)} />);
  const media = s.mode === "item" ? s.mediaItems(i) : [];

  return (
    <aside className="side insp scroll" id="side" ref={side}>
      <div className="idrow">
        <span className="iid">{i.id || ""}</span>
        {s.canMove && <span className="idsep" aria-hidden="true">·</span>}
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
        <ChipSelect id="kindChip" cls="kind-chip" label={s.t("chip.kind")} value={kind} onPick={s.setKind}
          options={[...KINDS, ...(KINDS.includes(kind as never) ? [] : [kind])].map((k) => [k, s.kindLabel(k)])}>
          {/* a spoken note wears the recording's mark, in the note's colour */}
          {voice && kind === "note" ? (
            <span className="kind-ic k-note"><Icon name="waveform" size={16} /></span>
          ) : (
            <KindIcon kind={kind} size={16} />
          )}{" "}
          {voice && kind === "note" ? s.t("source.type.voice") : s.kindLabel(kind)}
        </ChipSelect>
        {kind === "issue" && (
          <>
            <ChipSelect id="sevChip" cls={"sev-" + sev} label={s.t("chip.severity")} value={sev} onPick={s.setSev}
              options={SEV.map((v) => [v, s.t("severity." + v)])}>
              <SevBars sev={sev} />
              {s.t("severity." + sev)}
            </ChipSelect>
            {/* an unset type is never shown by its own name: "Add type…" waits under the pointer (or the keyboard) */}
            <ChipSelect id="typeChip" cls={i.type ? undefined : "chip-add"} label={s.t("chip.type")} value={String(i.type ?? "")} onPick={s.setType}
              options={[["", i.type ? s.t("chip.type_none") : s.t("chip.add_type")], ...s.types.map((t): [string, string] => [t, s.typeLabel(t)])]}>
              {i.type ? s.typeLabel(String(i.type)) : <><Icon name="plus" size={12} /> {s.t("chip.add_type")}</>}
            </ChipSelect>
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
      {voice && audio && <VoiceCard key={audio} rel={audio} />}
      {said && <p className="transcript" id="transcript">{i.quote}</p>}
      {media.length > 0 && <ItemMedia i={i} />}
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
      {i.quote && !said && (
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
