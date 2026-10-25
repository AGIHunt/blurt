import { STATES, targetOf, type Action } from "@blurt/ui";
import { KindIcon } from "@blurt/ui/react";
import { useEffect, useRef, useState } from "react";
import type { Item } from "../host";
import { kindOf, SEV, type StateFilter } from "../store";
import { Icon } from "./Icon";
import { cx, mdLite, useStore } from "./ctx";
import { StateControl, StateRing, stateText } from "./Queue";

export function ListView() {
  const s = useStore();
  const kinds = [...new Set(s.data.items.map(kindOf))];
  // All (but discarded) · Needs you · each state the doc has · Discarded
  const present = STATES.filter((st) => s.data.items.some((i) => s.stateOf(i) === st));
  const opts: [StateFilter, string][] = [["live", s.t("filter.live")], ["inbox", s.t("filter.inbox")], ...present.map((st) => [st, s.stateLabel(st)] as [StateFilter, string])];
  const rows = s.listed();
  return (
    <main id="listView" className={cx("list scroll", s.selected.size > 0 && "selecting")}>
      <div className="toolbar">
        <label className="search-wrap">
          <Icon name="search" className="sicon" />
          <input className="search" id="search" placeholder={s.t("list.search")} value={s.query} onChange={(e) => s.setQuery(e.target.value)} />
        </label>
        <label className="pick" title={s.t("filter.state")}>
          <select id="stateFilter" value={s.stateF} aria-label={s.t("filter.state")} onChange={(e) => s.setStateF(e.target.value as StateFilter)}>
            {opts.map(([k, l]) => (
              <option key={k} value={k}>
                {l}
              </option>
            ))}
          </select>
          <Icon name="chevron-down" size={13} className="pick-ch" />
        </label>
        {kinds.length >= 2 && (
          <div className="seg" id="kindFilter">
            <button className={cx(s.kindF === "" && "on")} data-kf="" onClick={() => s.setKindF("")}>
              {s.t("filter.all_kinds")}
            </button>
            {kinds.map((k) => (
              <button key={k} className={cx(s.kindF === k && "on")} data-kf={k} onClick={() => s.setKindF(k)}>
                <KindIcon kind={k} size={16} />
                {s.kindLabel(k)}
              </button>
            ))}
          </div>
        )}
      </div>
      <div className="cards" id="cards">
        {rows.map(({ i, k, s: st }) => (
          <Card key={s.keyOf(i)} i={i} k={k} st={st} />
        ))}
        {!rows.length && <p className="empty">{s.t("list.empty")}</p>}
      </div>
      <SelectionBar />
      <DropZone />
    </main>
  );
}

function Card({ i, k, st }: { i: Item; k: number; st: string }) {
  const s = useStore();
  const img = (i.frames || [])[0];
  const sev = (SEV as readonly string[]).includes(String(i.severity)) ? String(i.severity) : "medium";
  const kd = kindOf(i);
  const ch = s.changed.get(s.keyOf(i));
  const src = img ? s.host.fileUrl(img.path) : "";
  const fresh = !!img && s.fresh.has(src);
  const wait = !img && !!s.data.processing && !s.stalled;
  const sel = s.isSelected(i);
  const w = s.stateOf(i);
  const cursor = s.listCur === s.keyOf(i);
  const ref = useRef<HTMLElement>(null);
  useEffect(() => {
    if (cursor) ref.current?.scrollIntoView?.({ block: "nearest" });
  }, [cursor]);
  const meta = [
    kd === "issue" ? (
      <span key="sev" className={"sev sev-" + sev}>
        {s.t("severity." + sev)}
      </span>
    ) : null,
    i.module ? <span key="m">{String(i.module)}</span> : null,
    i.owner ? <span key="o">@{String(i.owner)}</span> : null,
    i.type ? <span key="t">{s.typeLabel(String(i.type))}</span> : null,
    w !== "todo" && w !== "new" ? (
      <span key="w" className={"wk s-" + w}>
        {stateText(s, i)}
      </span>
    ) : null,
  ].filter(Boolean);
  return (
    <article
      ref={ref}
      className={cx("card", st, sel && "sel", cursor && "cursor", ch?.has("*") && "fresh", "s-" + w)}
      aria-current={cursor ? "true" : undefined}
      data-k={k}
      draggable={s.canMove}
      onDragStart={(e) => {
        if (!sel) {
          s.clearSelection();
          s.toggleSelect(i);
        }
        e.dataTransfer.effectAllowed = "move";
        e.dataTransfer.setData("text/plain", s.selectedItems().map((x) => x.id).join(", "));
        s.setDragging(true);
      }}
      onDragEnd={() => s.setDragging(false)}
      onClick={(e) => {
        if (e.metaKey || e.ctrlKey || e.shiftKey || s.selected.size) s.toggleSelect(i, e.shiftKey);
        else s.openItem(k);
      }}
    >
      <div className={cx("img", !img && "none", wait && "shim", fresh && "fresh")} style={img ? { backgroundImage: `url("${src}")` } : undefined}>
        {img ? null : wait ? <Icon name="hatch" className="hatching" /> : s.t("media.none")}
        <button
          className={cx("pickbox", sel && "on")}
          role="checkbox"
          aria-checked={sel}
          aria-label={s.t("select.toggle") + " " + i.id}
          onClick={(e) => {
            e.stopPropagation();
            s.toggleSelect(i, e.shiftKey);
          }}
        >
          {sel && <Icon name="check" size={12} />}
        </button>
      </div>
      <div className="body">
        <div className="h">
          <KindIcon kind={kd} size={16} title={s.kindLabel(kd)} />
          <span>{i.id || ""}</span>
          <span className="sp" />
          {i.time && i.time.start != null ? <span className="tm">{s.clock(i.time.start)}</span> : null}
          <StateControl i={i} variant="ring" />
        </div>
        <div className="tt">{i.title}</div>
        <div className="mm">{meta}</div>
      </div>
    </article>
  );
}

/** what you can do with a selection: keep / drop, move to a project, hand off */
function SelectionBar() {
  const s = useStore();
  const items = s.selectedItems();
  if (!items.length) return null;
  const live = items.filter((i) => s.stateOf(i) !== "discarded");
  const can = (a: Action) => items.some((i) => targetOf(a, i));
  return (
    <div className="selbar" role="toolbar" aria-label={s.plural("select.count", items.length)}>
      <span className="selcount">{s.plural("select.count", items.length)}</span>
      {can("keep") && (
        <button className="btn sm" id="selKeep" onClick={() => s.act(items, "keep")}>
          <Icon name="check" size={14} /> {s.t("action.keep")}
        </button>
      )}
      {can("discard") && (
        <button className="btn sm" id="selDrop" onClick={() => s.act(items, "discard")}>
          <Icon name="x" size={14} /> {s.t("action.discard")}
        </button>
      )}
      {can("restore") && (
        <button className="btn sm" id="selRestore" onClick={() => s.act(items, "restore")}>
          <Icon name="restart" size={14} /> {s.t("action.restore")}
        </button>
      )}
      {s.canMove && <MovePicker items={items} id="selMove" />}
      {s.canHandoff && live.length > 0 && (
        <button className="btn sm" id="selCopy" title={s.t("handoff.copy_instruction.hint")} onClick={() => void s.handoff(live, "instruction")}>
          <Icon name="copy" size={14} /> {s.label("handoff.copy_instruction")}
        </button>
      )}
      {s.host.dispatch && live.length > 0 && (
        <button className="btn sm primary" id="selDispatch" title={s.t("handoff.dispatch.hint")} onClick={() => s.dispatch(live)}>
          <Icon name="send" size={14} /> {s.t("handoff.dispatch")}
        </button>
      )}
      <span className="sp" />
      <button className="btn sm ghost" onClick={s.selectAll}>
        {s.t("select.all")}
      </button>
      <button className="icon-btn" id="selClear" title={s.t("select.clear") + " · Esc"} aria-label={s.t("select.clear")} onClick={s.clearSelection}>
        <Icon name="x" size={15} />
      </button>
    </div>
  );
}

/** a native select styled as a button: "Move to…" + the projects (the inbox last) */
/** `primary`: the view's one primary, "Move to Project…" (an Unassigned item's detail: filing it is the next step). */
export function MovePicker({ items, id, current, primary }: { items: Item[]; id?: string; current?: string; primary?: boolean }) {
  const s = useStore();
  // the one project order (pinned, then recent) as the host lists them; Unassigned last, and never offered as a primary
  const projects = [...s.projects.filter((p) => p.id !== "inbox"), ...(primary ? [] : [s.project("inbox")!])];
  const value = current ?? "";
  return (
    <label className={cx("pick", current !== undefined ? "proj" : "btn sm", primary && "primary")}>
      {current === undefined && <Icon name="folder" size={14} />}
      {current !== undefined && <Icon name={current === "inbox" ? "inbox" : "folder"} size={14} />}
      <span className="pick-l">{current !== undefined ? s.projectName(s.project(current)) || current : s.t(primary ? "project.move_to_project" : "project.move_to")}</span>
      <select
        id={id}
        value={value}
        aria-label={s.t("project.move_to")}
        onChange={(e) => {
          if (e.target.value) s.moveTo(items, e.target.value);
        }}
      >
        {current === undefined && <option value="">{s.t("project.move_to")}</option>}
        {projects.map((p) => (
          <option key={p.id} value={p.id}>
            {s.projectName(p)}
            {p.id !== "inbox" ? ` · ${p.key}` : ""}
          </option>
        ))}
      </select>
      <Icon name="chevron-down" size={12} className="pick-ch" />
    </label>
  );
}

/** while cards are dragged: the projects as drop targets along the bottom */
function DropZone() {
  const s = useStore();
  const [over, setOver] = useState<string | null>(null);
  if (!s.dragging || !s.canMove) return null;
  const items = s.selectedItems();
  const projects = [...s.projects.filter((p) => p.id !== "inbox"), s.project("inbox")!];
  return (
    <div className="dropzone" aria-live="polite">
      <span className="dz-hint">{s.plural("select.drop_hint", items.length)}</span>
      <div className="dz-targets">
        {projects.map((p) => (
          <div
            key={p.id}
            className={cx("dz", over === p.id && "over")}
            data-project={p.id}
            onDragOver={(e) => {
              e.preventDefault();
              e.dataTransfer.dropEffect = "move";
              if (over !== p.id) setOver(p.id);
            }}
            onDragLeave={() => setOver((o) => (o === p.id ? null : o))}
            onDrop={(e) => {
              e.preventDefault();
              setOver(null);
              s.setDragging(false);
              s.moveTo(items, p.id);
            }}
          >
            <Icon name={p.id === "inbox" ? "inbox" : "folder"} size={15} />
            <span>{s.projectName(p)}</span>
            {p.id !== "inbox" && <span className="pj">{p.key}</span>}
          </div>
        ))}
      </div>
    </div>
  );
}

export function Overview() {
  const s = useStore();
  const ks: Record<string, Item[]> = {};
  s.data.items.forEach((i) => (ks[kindOf(i)] ||= []).push(i));
  return (
    <main id="overviewView" className="list scroll">
      <article className="ov">
        {s.data.title ? <h1>{String(s.data.title)}</h1> : null}
        <div className="ov-kinds" aria-label={s.t("overview.kinds")}>
          {Object.entries(ks).map(([k, v]) => (
            <span className="chip" key={k}>
              <KindIcon kind={k} size={16} /> {s.kindLabel(k)} · {s.i18n.formatNumber(v.length)}
            </span>
          ))}
        </div>
        {s.data.digest ? <div className="md" dangerouslySetInnerHTML={{ __html: mdLite(String(s.data.digest)) }} /> : null}
        {Object.entries(ks).map(([k, v]) => (
          <section key={k}>
            <h3>
              <KindIcon kind={k} size={18} /> {s.kindLabel(k)}
            </h3>
            <div className="ov-list">
              {v.map((i) => (
                <button key={s.keyOf(i)} className={cx(s.st(i), "s-" + s.stateOf(i))} data-k={s.data.items.indexOf(i)} onClick={() => s.openItem(s.data.items.indexOf(i))}>
                  <span>{i.id || ""}</span>
                  <span className="tt">{i.title}</span>
                  <StateRing i={i} />
                </button>
              ))}
            </div>
          </section>
        ))}
      </article>
    </main>
  );
}
