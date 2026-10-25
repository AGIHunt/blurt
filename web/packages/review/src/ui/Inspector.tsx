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

/** A property (kind, severity, type): a quiet button — its icon and value — that opens a menu of its values with the
    current one checked. A native <select> under it, so the host draws its own menu (arrow keys, Return picks, Esc
    closes). A pick is one undoable step. The chevron shows on hover only. */
function ChipSelect({ id, cls, label, value, options, onPick, children }: {
  id: string; cls?: string; label: string; value: string; options: [string, string][]; onPick: (v: string) => void; children: React.ReactNode;
}) {
  return (
    <label className={cx("prop chip-pick", cls)} title={label}>
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

/** Severity as a glyph: one, two or three bars, the shape saying how bad (grayscale-safe); only High is coloured. */
export function SevBars({ sev }: { sev: string }) {
  const n = sev === "high" ? 3 : sev === "low" ? 1 : 2;
  return (
    <span className={cx("sevbars", "b-" + n)} aria-hidden="true">
      <i />
      <i />
      <i />
    </span>
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

/** A borderless ⋯ with the panel's other actions: a native select under it, so the host draws its own menu. */
function MoreMenu({ id, label, options, onPick }: { id: string; label: string; options: [string, string][]; onPick: (v: string) => void }) {
  if (!options.length) return null;
  return (
    <label className="more-btn" title={label}>
      <Icon name="more" size={15} />
      <select id={id} value="" aria-label={label} onChange={(e) => e.target.value && onPick(e.target.value)}>
        <option value="" disabled>
          {label}
        </option>
        {options.map(([v, t]) => (
          <option key={v} value={v}>
            {t}
          </option>
        ))}
      </select>
    </label>
  );
}

/** What happened with the work (K3 `work`): who and when, commit, PR, the agent's note — and, when an agent says it's
    finished, a card that asks: one sentence ("Codex says it's fixed"), the evidence on one quiet line, the answer as
    the view's one primary, Send Back… with an optional note for the agent, the rest under ⋯ (the state pill's menu
    has every action). */
function WorkPanel({ i }: { i: Item }) {
  const s = useStore();
  const st = s.stateOf(i);
  const rec = i.work ?? (i.fix ? fixAsWork(i.fix) : undefined);
  const [back, setBack] = useState<string | null>(null);
  const noteRef = useRef<HTMLTextAreaElement>(null);
  useLayoutEffect(() => {
    if (back !== null) autosize(noteRef.current, 160);
  }, [back]);
  if (!rec || st === "new" || st === "discarded") return null;
  const agent = rec.agent && rec.agent !== "human" ? agentName(s, rec.agent) : null;
  const who = rec.by === "user" ? s.t("work.by_you") : agent ? s.t("work.by", { who: agent }) : "";
  const when = rec.at ? s.ago(rec.at) : "";
  // one Open Session per item: while it is with the agent a host banner may have it (the Mac app), else it is here
  const banner = s.host.sessionBanner && (st === "handed_off" || st === "in_progress");
  const session = rec.to === "session" && rec.job && s.host.openSession && st !== "done" && st !== "wontfix" && !banner ? rec.job : null;
  const verify = st === "to_verify";
  const meta = who || when || rec.commit || rec.pr;
  if (!meta && !verify && !rec.note && !session) return null;
  // the host's banner already says who has it and when: a card with only that line would repeat it
  if (banner && !verify && !rec.note && !rec.commit && !rec.pr) return null;
  const evidence = (
    <>
      {rec.commit ? (
        <code className="sha" title={rec.commit}>
          {shortSha(rec.commit)}
        </code>
      ) : null}
      {rec.pr ? (
        <a className="linkbtn" href={rec.pr} target="_blank" rel="noreferrer">
          {s.t("work.pr")}
        </a>
      ) : null}
      {session ? (
        <button className="linkbtn" id="workSession" onClick={() => s.openSession(session)}>
          {s.t("work.open_session")}
        </button>
      ) : null}
    </>
  );
  if (!verify)
    return (
      <div className={cx("work", "s-" + st)} id="workRow">
        <div className="work-h">
          {(who || when) && <span className="work-m">{[who, when].filter(Boolean).join(" · ")}</span>}
          {evidence}
        </div>
        {rec.note ? <p className="work-note">{rec.note}</p> : null}
      </div>
    );
  // the agent's claim decides the primary: "fixed" → Mark as Done; "won't fix" → Won't Do (the other one waits in ⋯)
  const wont = rec.claim === "wontfix";
  const primary: "done" | "wontfix" = wont ? "wontfix" : "done";
  // the agent by its name when the doc knows it ("Codex says it’s fixed"); else the plain sentence, never "Agent says"
  const named = (rec.agent && rec.agent !== "human" && s.data.agents?.[rec.agent]?.name) || null;
  const headline = named
    ? s.t(wont ? "work.verify.wontfix" : "work.verify.fixed", { agent: named })
    : s.t(wont ? "work.verify.wontfix.generic" : "work.verify.fixed.generic");
  const more: [string, string][] = [
    ...(session && s.host.reviewChanges ? [["review", s.t("work.review_changes")] as [string, string]] : []),
    [wont ? "done" : "wontfix", s.label(wont ? "action.done" : "action.wontfix")],
  ];
  const sendBack = () => {
    const note = (back ?? "").trim();
    setBack(null);
    s.act([i], "send_back", note ? { note } : {});
  };
  // the headline names the agent: the line under it is when, then the evidence
  const timeLine = named && rec.by !== "user" ? when : [who, when].filter(Boolean).join(" · ");
  return (
    <div className="work verify s-to_verify" id="workRow" role="group" aria-label={headline}>
      <StatusRing state="to_verify" size={16} className="work-ic" />
      <div className="work-b">
        <p className="work-claim">{headline}</p>
        {(timeLine || rec.commit || rec.pr || session) && (
          <div className="work-m">
            {timeLine && <span>{timeLine}</span>}
            {evidence}
          </div>
        )}
        {rec.note ? <p className="work-note">{rec.note}</p> : null}
      </div>
      {back === null ? (
        <div className="work-a">
          <button className="btn sm" id="workBack" aria-haspopup="dialog" title={s.t("work.back.hint")} onClick={() => setBack("")}>
            {s.t("work.back")}
          </button>
          <button className="btn sm primary" id="workDone" data-action={primary} title={s.label(wont ? "action.wontfix" : "action.done") + " · " + (wont ? "W" : "D")}
            aria-keyshortcuts={wont ? "w" : "d"} onClick={() => s.act([i], primary)}>
            {s.label(wont ? "action.wontfix" : "action.done")}
          </button>
          <MoreMenu id="workMore" label={s.t("work.more")} options={more}
            onPick={(v) => (v === "review" ? session && s.host.reviewChanges?.(session) : s.act([i], v as "done" | "wontfix"))} />
        </div>
      ) : (
        <div className="work-back">
          <textarea ref={noteRef} id="workBackNote" rows={2} autoFocus value={back} placeholder={s.t("work.back.prompt")}
            aria-label={s.t("work.back.prompt")}
            onChange={(e) => {
              setBack(e.target.value);
              autosize(e.currentTarget, 160);
            }}
            onKeyDown={(e) => {
              if (e.nativeEvent.isComposing) return;
              if (e.key === "Escape") {
                e.preventDefault();
                e.stopPropagation();
                setBack(null);
              } else if (e.key === "Enter" && (e.metaKey || e.ctrlKey) && isEnter(e)) {
                e.preventDefault();
                e.stopPropagation();
                sendBack();
              }
            }} />
          <div className="work-a">
            <span className="work-hint">{s.t("work.back.note_hint")}</span>
            <button className="btn sm" id="workBackCancel" onClick={() => setBack(null)}>
              {s.t("action.cancel")}
            </button>
            <button className="btn sm primary" id="workBackSend" onClick={sendBack}>
              {s.label("action.send_back")}
              <kbd>{isMacLike() ? "⌘⏎" : "Ctrl ⏎"}</kbd>
            </button>
          </div>
        </div>
      )}
    </div>
  );
}

/** K6: hand the item to an agent — inside Blurt (dispatch, the one primary), or copy it for your own agent: one Copy
    button (the instruction) with a menu beside it for the other forms (the full hand-off note). The key is in the
    tooltip, never a keycap inside the button. */
function HandoffPanel({ i }: { i: Item }) {
  const s = useStore();
  const h = s.host;
  if (!h.dispatch && !s.canHandoff) return null;
  if (!canDo("hand_off", s.stateOf(i))) return null;
  const key = isMacLike() ? "⌘⏎" : "Ctrl+⏎";
  const unfiled = s.mode === "item" && s.canMove && (i.project || "inbox") === "inbox";
  return (
    <div className="handoff" id="handoffRow" role="group" aria-label={s.t("handoff.title")}>
      {s.canHandoff && (
        <div className="split">
          <button className="btn sm" id="copyInstruction" title={s.t("handoff.copy_instruction.hint")} onClick={() => void s.handoff([i], "instruction")}>
            <Icon name="copy" size={14} /> {s.label("media.copy")}
          </button>
          <label className="btn sm split-more" title={s.t("handoff.copy_more")}>
            <Icon name="chevron-down" size={12} />
            <select id="copyMenu" value="" aria-label={s.t("handoff.copy_more")}
              onChange={(e) => {
                const v = e.target.value;
                e.target.value = "";
                if (v === "instruction" || v === "full") void s.handoff([i], v);
              }}>
              <option value="" disabled>
                {s.label("media.copy")}
              </option>
              <option value="instruction" title={s.t("handoff.copy_instruction.hint")}>
                {s.label("handoff.copy_instruction")}
              </option>
              <option value="full" title={s.t("handoff.copy_full.hint")}>
                {s.label("handoff.copy_full")}
              </option>
            </select>
          </label>
        </div>
      )}
      {/* an item in no project is there to be filed: an agent works in a project's folder, so the one primary is
          Move to Project… until it has one (hand-off stays in the menus and ⌘⏎, which say why it can't go yet) */}
      {unfiled && <MovePicker items={[i]} id="fileBtn" primary />}
      {h.dispatch && !unfiled && (
        <button className="btn sm primary" id="dispatchBtn"
          title={s.mode === "item" ? `${s.t("handoff.dispatch.hint")} (${key})` : s.t("handoff.dispatch.hint")}
          aria-keyshortcuts={s.mode === "item" ? (isMacLike() ? "Meta+Enter" : "Control+Enter") : undefined}
          onClick={() => s.dispatch([i])}>
          <Icon name="send" size={14} /> {s.t("handoff.dispatch")}
        </button>
      )}
    </div>
  );
}

/** work_history holds each earlier step (the state it was in); the newest row is the item now */
function historyRows(s: ReviewStore, i: Item): WorkRecord[] {
  return i.work
    ? [...(i.work_history || []), { ...i.work, state: s.stateOf(i) }]
    : i.fix
      ? [...(i.fix_history || []), i.fix].map(fixAsWork)
      : [];
}

function WorkHistory({ i }: { i: Item }) {
  const s = useStore();
  const rows = historyRows(s, i);
  // one entry is the item now: the state pill (and the work card) already say it
  if (rows.length < 2) return null;
  return (
    <div className="f worklog">
      <label className="sec-h">{s.t("work.history")}</label>
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

/** Where the item came from and how it got into this project (K1 source, K2 project_by / suggestion), as a quiet footer:
    one line — how it was made, when, by whom — then, only when there is more, label / value rows that share one value
    column. "Captured in this project" isn't said: the breadcrumb already names the project. */
function Provenance({ i }: { i: Item }) {
  const s = useStore();
  const src = i.source || {};
  const type = src.type;
  const p = s.project(i.project);
  const sug = i.suggested_project && s.project(i.suggested_project.id);
  const line: React.ReactNode[] = [];
  if (type)
    line.push(
      <span key="t">
        {s.i18n.has(`source.type.${type}`) ? s.t(`source.type.${type}`) : type}
        {type === "recording" && i.time?.start != null ? ` ${s.t("source.at", { time: s.clock(i.time.start) })}` : ""}
      </span>,
    );
  if (i.created)
    line.push(
      <span key="c" title={s.i18n.formatDate(i.created, { dateStyle: "full", timeStyle: "short" })}>
        {s.i18n.formatDate(i.created)}
      </span>,
    );
  if (src.by) line.push(<span key="b">{s.t("source.by_who", { who: String(src.by) })}</span>);
  const rows: [string, React.ReactNode][] = [];
  if (src.app) rows.push([s.t("source.app"), appLabel(String(src.app))]);
  if (src.url)
    rows.push([s.t("source.page"), <a href={String(src.url)} target="_blank" rel="noreferrer" className="trunc">{String(src.url).replace(/^https?:\/\//, "")}</a>]);
  if (src.session) {
    // when it was captured, not the folder's name (the folder is one click away)
    const when = sessionWhen(s, String(src.session)) ?? s.t("source.session.unnamed");
    rows.push([s.t("source.session"), s.host.reveal ? (
      <button className="linkbtn trunc" onClick={() => s.host.reveal!(String(src.session))} title={s.t("source.session.reveal")}>
        {when}
      </button>
    ) : <span className="trunc">{when}</span>]);
  }
  if (i.aliases?.length) rows.push([s.t("source.aliases"), s.i18n.formatList(i.aliases)]);
  if (i.merged_from?.length) {
    // an item merged in that this doc no longer lists has no id to show here: say how many, never its uid
    const known = i.merged_from.map((u) => s.data.items.find((x) => x.uid === u || x.id === u)?.id).filter((x): x is string => !!x);
    const other = i.merged_from.length - known.length;
    const parts = other ? [...known, s.plural("source.merged_earlier", other)] : known;
    rows.push([s.t("source.merged_from"), s.i18n.formatList(parts)]);
  }
  // how it got into this project — only when it wasn't simply captured there (the breadcrumb already says where it is)
  const by = i.project_by && i.project_by !== "capture" && p ? i.project_by : null;
  if (by) rows.push([s.t("source.project"), s.t(`project.by.${by}`, { pct: pct(s, i.project_confidence) })]);
  const offer = sug && (i.project || "inbox") === "inbox" && s.canMove;
  if (!line.length && !rows.length && !offer) return null;
  return (
    <footer className="prov" id="provenance" aria-label={s.t("source.title")}>
      {/* an Unassigned item's suggestion from its organizing run: only a suggestion, one click moves it (K2) */}
      {offer && (
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
      {line.length > 0 && (
        <p className="prov-line">
          {type && <Icon name={SOURCE_ICON[type] ?? "info"} size={13} />}
          {line.flatMap((x, n) => (n ? [<span key={"s" + n} className="prov-dot" aria-hidden="true">·</span>, x] : [x]))}
        </p>
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
    </footer>
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

/** The empty fields, as a quiet menu at the end: picking one shows it, focused. An issue without a type lists the
    types here too (one pick sets it; the type chip appears then). */
function AddField({ specs, types, onAdd, onType }: { specs: Spec[]; types: [string, string][]; onAdd: (k: string) => void; onType: (t: string) => void }) {
  const s = useStore();
  if (!specs.length && !types.length) return null;
  return (
    <label className="pick btn sm ghost addf">
      <Icon name="plus" size={14} />
      <span className="pick-l">{s.t("field.add")}</span>
      <select id="addField" value="" aria-label={s.t("field.add")}
        onChange={(e) => {
          const v = e.target.value;
          if (v.startsWith("type:")) onType(v.slice(5));
          else if (v) onAdd(v);
        }}>
        <option value="" disabled>
          {s.t("field.add")}
        </option>
        {specs.map((f) => (
          <option key={f.k} value={f.k}>
            {f.label}
          </option>
        ))}
        {types.length > 0 && (
          <optgroup label={s.t("chip.type")}>
            {types.map(([v, t]) => (
              <option key={"type:" + v} value={"type:" + v}>
                {t}
              </option>
            ))}
          </optgroup>
        )}
      </select>
    </label>
  );
}

/** The item as a document: breadcrumb (and, in the app's detail pane, its actions), title, one row of properties, what
    was said, the kind's fields, `media` (the app's detail pane puts the screenshots here, inline), history, where it came
    from. */
export function Inspector({ media }: { media?: React.ReactNode } = {}) {
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
  // a voice note: its recording and its words are the body (Voice Memos), not a quote under a heading
  const voice = i.source?.type === "voice";
  const said = voice && !!(i.quote || "").trim();
  const audio = voiceAudio(i);
  const F = (f: Spec, placeholder?: string) => (
    <Field key={ik + f.k} i={i} k={f.k} label={f.label} type={f.type} cls={f.cls} placeholder={placeholder} onFocus={() => open(f.k)} />
  );
  // only what has something in it (or the user opened); the rest wait in the add menu
  const { body: main, prompt, rest } = specsOf(i, kind, s);
  const kept = opened.ik === ik ? opened.keys : [];
  const shown = rest.filter((f) => kept.includes(f.k) || format(i, f.k, f.type ?? "area").trim() !== "");
  // the kind's body field is always there to fill in — except on a voice note, whose words already are its body: an
  // empty Summary there only waits in Add Field
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
  const typeChoices: [string, string][] = kind === "issue" && !i.type ? s.types.map((t) => [t, s.typeLabel(t)]) : [];
  body.push(<AddField key="add" specs={[...(mainShown ? [] : [main]), ...rest.filter((f) => !shown.includes(f))]} types={typeChoices} onAdd={(k) => open(k, true)} onType={s.setType} />);

  const item = s.mode === "item";
  const props = (
    <div className="props" role="group" aria-label={s.t("chip.properties")}>
      <StateControl i={i} id="statePill" shortcuts controlled />
      <ChipSelect id="kindChip" cls="kind-chip" label={s.t("chip.kind")} value={kind} onPick={s.setKind}
        options={[...KINDS, ...(KINDS.includes(kind as never) ? [] : [kind])].map((k) => [k, s.kindLabel(k)])}>
        {/* a spoken note wears the recording's mark, in the note's colour */}
        {voice && kind === "note" ? (
          <span className="kind-ic k-note"><Icon name="waveform" size={16} /></span>
        ) : (
          <KindIcon kind={kind} size={16} />
        )}
        <span className="prop-l">{voice && kind === "note" ? s.t("source.type.voice") : s.kindLabel(kind)}</span>
      </ChipSelect>
      {kind === "issue" && (
        <>
          <ChipSelect id="sevChip" cls={"sev-" + sev} label={s.t("chip.severity")} value={sev} onPick={s.setSev}
            options={SEV.map((v) => [v, s.t("severity." + v)])}>
            <SevBars sev={sev} />
            <span className="prop-l">{s.t("severity." + sev)}</span>
          </ChipSelect>
          {/* the issue's type (Bug, UI, Copy…) is optional: unset, it waits in Add Field under the fields */}
          {i.type ? (
            <ChipSelect id="typeChip" cls="type-chip" label={s.t("chip.type")} value={String(i.type)} onPick={s.setType}
              options={[...[...new Set([...s.types, String(i.type)])].map((t): [string, string] => [t, s.typeLabel(t)]), ["", s.t("chip.type_none")]]}>
              <Icon name="tag" size={15} />
              <span className="prop-l">{s.typeLabel(String(i.type))}</span>
            </ChipSelect>
          ) : null}
        </>
      )}
      {i.confidence === "low" && (
        <span className="prop static low" title={s.t("chip.low_confidence.hint")}>
          <Icon name="help-circle" size={15} />
          <span className="prop-l">{s.t("chip.low_confidence")}</span>
        </span>
      )}
    </div>
  );
  return (
    <aside className="side insp scroll" id="side" ref={side}
      // scrolled under the window's toolbar: a hairline at the top edge, as a Mac scroll view shows one
      onScroll={item ? (e) => e.currentTarget.classList.toggle("scrolled", e.currentTarget.scrollTop > 2) : undefined}>
      <div className="idrow">
        <span className="iid">{i.id || ""}</span>
        {s.canMove && (
          <>
            <span className="crumb-dot" aria-hidden="true">·</span>
            <MovePicker items={[i]} id="projectPick" current={i.project || "inbox"} />
          </>
        )}
        {item && <HandoffPanel i={i} />}
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
      {props}
      <WorkPanel i={i} />
      {!item && <HandoffPanel i={i} />}
      {voice && audio && <VoiceCard key={audio} rel={audio} />}
      {said && <p className="transcript" id="transcript">{i.quote}</p>}
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
        <section className="quote">
          <h4 className="sec-h">{s.t("field.quote")}</h4>
          <blockquote>{i.quote}</blockquote>
          {((i.time && i.time.start != null) || s.hasVideo(i)) && (
            <div className="meta">
              {i.time && i.time.start != null ? <span className="tnum">{`${s.clock(i.time.start)} – ${s.clock(i.time.end)}`}</span> : null}
              {s.hasVideo(i) && (
                <button className="linkbtn" id="origBtn" onClick={s.playOrig} title={s.t("media.play_original") + " · O"}>
                  <Icon name="play" size={12} /> {s.t("media.play_original")}
                </button>
              )}
            </div>
          )}
        </section>
      )}
      <div className="fields">{body}</div>
      {media}
      <WorkHistory i={i} />
      <Provenance i={i} />
    </aside>
  );
}
