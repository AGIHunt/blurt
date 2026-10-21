import { fmt, kindOf, SEV, type Filter } from "../store";
import { Egg, ICheck, IX } from "./icons";
import { cx, mdLite, useStore } from "./ctx";
import type { Item } from "../host";

export function ListView() {
  const s = useStore();
  const fs: [Filter, string][] = [["all", s.t("all")], ["pending", s.t("filterPending")], ["keep", s.t("filterKept")], ["drop", s.t("filterDropped")]];
  const kinds = [...new Set(s.data.items.map(kindOf))];
  return (
    <main id="listView" className="list scroll">
      <div className="toolbar">
        <input className="search" id="search" placeholder={s.t("search")} value={s.query} onChange={(e) => s.setQuery(e.target.value)} />
        <div className="seg" id="filters">
          {fs.map(([k, l]) => (
            <button key={k} className={cx(s.filter === k && "on")} data-f={k} onClick={() => s.setFilter(k)}>
              {l}
            </button>
          ))}
        </div>
        {kinds.length >= 2 && (
          <div className="seg" id="kindFilter">
            <button className={cx(s.kindF === "" && "on")} data-kf="" onClick={() => s.setKindF("")}>
              {s.t("allKinds")}
            </button>
            {kinds.map((k) => (
              <button key={k} className={cx(s.kindF === k && "on")} data-kf={k} onClick={() => s.setKindF(k)}>
                <Egg kind={k} />
                {s.kindLabel(k)}
              </button>
            ))}
          </div>
        )}
      </div>
      <div className="cards" id="cards">
        {s.listed().map(({ i, k, s: st }) => (
          <Card key={i.id} i={i} k={k} st={st} />
        ))}
      </div>
    </main>
  );
}

function Card({ i, k, st }: { i: Item; k: number; st: string }) {
  const s = useStore();
  const img = (i.frames || [])[0];
  const sev = (SEV as readonly string[]).includes(String(i.severity)) ? String(i.severity) : "medium";
  const kd = kindOf(i);
  const ch = s.changed.get(i.id);
  const src = img ? s.host.fileUrl(img.path) : "";
  const fresh = !!img && s.fresh.has(src);
  const wait = !img && !!s.data.processing && !s.stalled;
  const meta = [
    kd === "issue" ? (
      <span key="sev" className={"sev sev-" + sev}>
        {s.t(("sev" + sev[0].toUpperCase() + sev.slice(1)) as never)}
      </span>
    ) : null,
    i.module ? <span key="m">{String(i.module)}</span> : null,
    i.owner ? <span key="o">@{String(i.owner)}</span> : null,
    i.type ? <span key="t">{s.types[String(i.type)] || String(i.type)}</span> : null,
    i.fix ? (
      <span key="fx" className={"fxm fx-" + i.fix.state}>
        {s.t(("fix_" + i.fix.state) as never)}
      </span>
    ) : null,
  ].filter(Boolean);
  return (
    <article className={cx("card", st, ch?.has("*") && "fresh")} data-k={k} onClick={() => s.openItem(k)}>
      <div className={cx("img", !img && "none", wait && "shim", fresh && "fresh")} style={img ? { backgroundImage: `url("${src}")` } : undefined}>
        {img ? null : wait ? <Egg kind={kd} /> : s.t("noMedia")}
        {st !== "pending" && <div className={"stamp " + st}>{st === "keep" ? <ICheck /> : <IX />}</div>}
      </div>
      <div className="body">
        <div className="h">
          <Egg kind={kd} />
          <span>{i.id || ""}</span>
          <span style={{ marginLeft: "auto" }}>{i.time && i.time.start != null ? fmt(i.time.start) : ""}</span>
        </div>
        <div className="tt">{i.title}</div>
        <div className="mm">{meta}</div>
      </div>
    </article>
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
        <div className="ov-kinds">
          {Object.entries(ks).map(([k, v]) => (
            <span className="chip" key={k}>
              <Egg kind={k} /> {s.kindLabel(k)} · {v.length}
            </span>
          ))}
        </div>
        {s.data.digest ? <div className="md" dangerouslySetInnerHTML={{ __html: mdLite(String(s.data.digest)) }} /> : null}
        {Object.entries(ks).map(([k, v]) => (
          <section key={k}>
            <h3>
              <Egg kind={k} /> {s.kindLabel(k)}
            </h3>
            <div className="ov-list">
              {v.map((i) => (
                <button key={i.id} data-k={s.data.items.indexOf(i)} onClick={() => s.openItem(s.data.items.indexOf(i))}>
                  <span>{i.id || ""}</span>
                  {i.title}
                </button>
              ))}
            </div>
          </section>
        ))}
      </article>
    </main>
  );
}
