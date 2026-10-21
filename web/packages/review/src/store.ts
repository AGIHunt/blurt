/* All review state and actions. React components read it through useStore() and call its methods; every change
   bumps `version` and notifies subscribers. The logic mirrors the vanilla page it replaces, step for step. */
import type { BlurtHost, Item, MountOptions, SessionDoc } from "./host";
import { DICTS, KINDS, TYPES, toLang, type Key, type Lang } from "./i18n";
import { imeBusy, isEnter } from "./ime";
import { canon, clone, diffOps, finalize, mergeInto, norm, rebase, statusOf, type Status } from "./sync";

export type View = "overview" | "focus" | "list";
export type Filter = "all" | Status;
export type ProcPhase = "hidden" | "working" | "fin" | "out";
export type SaveState = "" | "saving" | "saved" | "error";

export interface Media {
  kind: "img" | "wait" | "clip" | "orig";
  src: string;
  rel?: string;
  label: string;
  cap?: string;
  start?: number;
  end?: number;
}

export const SEV = ["high", "medium", "low"] as const;
const MEDIA_POLL_PROCESSING = 1500;
const POLL_IDLE = 2000; // agent writes (set-frames, a chat answer) show up within ~2 s
const POLL_HIDDEN = 15000;
const STALL_S = 600;

export const fmt = (s: unknown) => {
  const v = Math.max(0, Number(s) || 0);
  const m = Math.floor(v / 60);
  const r = Math.floor(v % 60);
  return `${String(m).padStart(2, "0")}:${String(r).padStart(2, "0")}`;
};
export const kindOf = (i: Item) => i.kind || "issue";

const storage = {
  get(k: string): string | null {
    try {
      return localStorage.getItem(k);
    } catch {
      return null;
    }
  },
  set(k: string, v: string) {
    try {
      localStorage.setItem(k, v);
    } catch {
      /* private mode */
    }
  },
};

export class ReviewStore {
  readonly host: BlurtHost;
  readonly mode: "review" | "item";
  itemId: string | null;

  lang: Lang;
  version = 0;
  loaded = false;
  loadError: string | null = null;
  data: SessionDoc = { items: [] };
  base = new Map<string, Item>();
  etag = "";
  legacy = false;

  cur = 0;
  mediaSel: string | null = null;
  dir: "up" | "down" = "up";
  /** bumps when the stage should slide in */
  slideKey = 0;
  view: View = "focus";
  filter: Filter = "all";
  query = "";
  kindF = "";

  saveState: SaveState = "";
  confirming = false;
  confirmed = false;
  finishError = false;
  warnedProc = false;
  finishWarn = false;
  modal: null | "help" | "finish" = null;
  toast: { msg: string; undo: boolean; show: boolean; icon?: "check" | "x" } | null = null;
  lightbox: string | null = null;
  proc: ProcPhase = "hidden";

  /** media sources that arrived with a server update (they fade in) */
  fresh = new Set<string>();
  /** the last server update: item id → changed keys */
  changed = new Map<string, Set<string>>();
  readonly ar = new Map<string, number>();

  private knownSrc = new Set<string>();
  private undoStack: string[] = [];
  private listeners = new Set<() => void>();
  private net: Promise<unknown> = Promise.resolve();
  private saveTimer: ReturnType<typeof setTimeout> | undefined;
  private pollTimer: ReturnType<typeof setTimeout> | undefined;
  private procTimer: ReturnType<typeof setTimeout> | undefined;
  private toastTimer: ReturnType<typeof setTimeout> | undefined;
  private freshTimer: ReturnType<typeof setTimeout> | undefined;
  private wasProcessing = false;
  private lastStalled = false;
  private disposed = false;
  private langPicked: boolean;

  constructor(host: BlurtHost, opts: MountOptions = {}) {
    this.host = host;
    this.mode = opts.mode === "item" ? "item" : "review";
    this.itemId = opts.itemId ?? null;
    const picked = storage.get("blurt.lang");
    this.langPicked = !!picked || !!opts.lang;
    this.lang = toLang(picked || opts.lang || (typeof navigator !== "undefined" ? navigator.language : "en"));
  }

  // ---------------------------------------------------------------- plumbing
  subscribe = (f: () => void) => {
    this.listeners.add(f);
    return () => void this.listeners.delete(f);
  };
  getVersion = () => this.version;
  emit() {
    this.version++;
    for (const f of [...this.listeners]) f();
  }
  t = (k: Key) => DICTS[this.lang][k] ?? k;
  kindLabel = (k: string) => KINDS[this.lang][k] || k;
  get types() {
    return TYPES[this.lang];
  }
  private enqueue<T>(f: () => Promise<T>): Promise<T> {
    const p = this.net.then(f);
    this.net = p.catch(() => {});
    return p;
  }
  dispose() {
    this.disposed = true;
    for (const t of [this.saveTimer, this.pollTimer, this.procTimer, this.toastTimer, this.freshTimer]) clearTimeout(t);
    this.listeners.clear();
  }

  get item(): Item | undefined {
    return this.data.items[this.cur];
  }
  get stalled(): boolean {
    const at = Number(this.data.agent_at);
    return !!this.data.processing && !!at && Date.now() / 1000 - at > STALL_S;
  }
  get hasOverview() {
    return !!(this.data.digest || this.data.title);
  }
  counts() {
    let k = 0, d = 0, p = 0;
    for (const i of this.data.items) {
      const s = statusOf(i);
      if (s === "keep") k++;
      else if (s === "drop") d++;
      else p++;
    }
    return { k, d, p, n: this.data.items.length };
  }
  hasVideo(i: Item) {
    return this.data._video !== false && !!this.data.source_video && !!i.time && i.time.start != null;
  }
  mediaItems(i: Item | undefined): Media[] {
    if (!i) return [];
    const m: Media[] = (i.frames || []).map((f, k) => ({
      kind: "img" as const,
      src: this.host.fileUrl(f.path),
      rel: f.path,
      label: f.t != null ? fmt(f.t) : `#${k + 1}`,
      cap: f.caption,
    }));
    if (!m.length && this.data.processing) m.push({ kind: "wait", src: "wait:" + i.id, label: "…" });
    if (i.clip) m.push({ kind: "clip", src: this.host.fileUrl(i.clip), rel: i.clip, label: this.t("clip") });
    if (this.hasVideo(i))
      m.push({
        kind: "orig", src: this.host.fileUrl(String(this.data.source_video)), rel: String(this.data.source_video),
        label: this.t("orig"), start: i.time!.start, end: i.time!.end,
      });
    return m;
  }
  mediaIndex(items: Media[]) {
    const k = items.findIndex((m) => m.src === this.mediaSel);
    return k >= 0 ? k : 0;
  }

  // ---------------------------------------------------------------- loading and syncing
  private setTop(doc: SessionDoc) {
    for (const k of Object.keys(this.data)) if (k !== "items" && !(k in doc)) delete this.data[k];
    for (const [k, v] of Object.entries(doc)) if (k !== "items") this.data[k] = v;
  }
  private findCur(): number {
    if (this.mode !== "item" || !this.itemId) return -1;
    const want = this.itemId;
    return this.data.items.findIndex((i) => i.id === want || i.uid === want);
  }
  private markKnown(fresh: boolean) {
    const now: string[] = [];
    for (const i of this.data.items)
      for (const f of i.frames || []) {
        const src = this.host.fileUrl(f.path);
        if (!this.knownSrc.has(src)) {
          this.knownSrc.add(src);
          if (fresh) now.push(src);
        }
      }
    if (now.length) {
      now.forEach((s) => this.fresh.add(s));
      clearTimeout(this.freshTimer);
      this.freshTimer = setTimeout(() => this.fresh.clear(), 1500);
    }
  }

  async load() {
    try {
      const { doc, etag } = await this.host.load();
      this.etag = etag;
      this.legacy = (doc.items || []).some((i) => !i.id); // hand-written file without ids: save it whole, as before
      this.setTop(doc);
      const S = norm(doc.items);
      this.data.items = S.map(clone);
      this.base = new Map(S.map((i) => [i.id, clone(i)]));
      if (!this.langPicked && this.data.language) this.lang = toLang(String(this.data.language));
      if (this.mode === "item") this.cur = Math.max(0, this.findCur());
      else this.cur = Math.max(0, this.data.items.findIndex((i) => !i._touched));
      const v = storage.get("blurt.view") as View | null;
      this.view = v === "focus" || v === "list" || v === "overview" ? v : this.data.digest ? "overview" : this.data.items.length > 1 ? "focus" : "list";
      if (this.view === "overview" && !this.hasOverview) this.view = "focus";
      this.markKnown(false);
      this.wasProcessing = !!this.data.processing;
      this.proc = this.data.processing ? "working" : "hidden";
      this.lastStalled = this.stalled;
      this.loaded = true;
      this.slideKey++;
      this.emit();
      this.schedulePoll();
    } catch (e) {
      this.loadError = String((e as Error)?.message || e);
      this.emit();
    }
  }

  private applyServer(doc: SessionDoc) {
    const cid = this.item?.id;
    const prevProc = !!this.data.processing;
    const S = norm(doc.items);
    const res = rebase(this.data.items, this.base, S, false);
    this.data.items = res.items;
    this.base = new Map(S.map((i) => [i.id, clone(i)]));
    this.setTop(doc);
    if (this.mode === "item") {
      const k = this.findCur();
      this.cur = k >= 0 ? k : this.cur;
    } else {
      const k = this.data.items.findIndex((i) => i.id === cid);
      this.cur = k >= 0 ? k : Math.min(this.cur, Math.max(0, this.data.items.length - 1));
    }
    this.changed = res.changed;
    this.markKnown(true);
    if (prevProc !== !!this.data.processing) this.procChanged();
    this.lastStalled = this.stalled;
    this.emit();
  }

  private procChanged() {
    clearTimeout(this.procTimer);
    if (this.data.processing) {
      this.wasProcessing = true;
      this.proc = "working";
    } else if (this.wasProcessing) {
      this.wasProcessing = false;
      this.proc = "fin";
      this.procTimer = setTimeout(() => {
        this.proc = "out";
        this.emit();
        this.procTimer = setTimeout(() => {
          this.proc = "hidden";
          this.emit();
        }, 450);
      }, 2600);
    } else this.proc = "hidden";
  }

  private async accept(r: { etag: string; doc?: SessionDoc }, before: string) {
    if (r.doc) {
      this.etag = r.etag || this.etag;
      this.applyServer(r.doc);
      return;
    }
    // the host only acknowledged: fetch the merged file, so base includes what we just wrote
    const p = await this.host.poll(before);
    this.etag = p.etag || r.etag || this.etag;
    if (p.doc) this.applyServer(p.doc);
  }

  private async sync() {
    if (this.legacy) {
      await this.host.saveDoc?.(this.data, false);
      return;
    }
    const ops = diffOps(this.data.items, this.base);
    if (!ops.length) return;
    const before = this.etag;
    await this.accept(await this.host.sendOps(ops), before);
  }

  private async poll() {
    if (this.confirming || this.confirmed) return;
    const r = await this.host.poll(this.etag);
    if (this.confirming) return;
    if (r.doc) {
      this.etag = r.etag || this.etag;
      this.applyServer(r.doc);
    } else if (this.stalled !== this.lastStalled) {
      this.lastStalled = this.stalled;
      this.emit(); // nothing new, but the agent may have gone quiet
    }
  }

  private schedulePoll() {
    if (this.legacy || this.confirmed || this.disposed) return;
    const hidden = typeof document !== "undefined" && document.hidden;
    const wait = this.data.processing ? MEDIA_POLL_PROCESSING : hidden ? POLL_HIDDEN : POLL_IDLE;
    clearTimeout(this.pollTimer);
    this.pollTimer = setTimeout(async () => {
      await this.enqueue(() => this.poll()).catch(() => {});
      this.schedulePoll();
    }, wait);
  }

  pollNow() {
    if (this.loaded && !this.legacy) this.enqueue(() => this.poll()).catch(() => {});
  }

  save() {
    if (this.confirming) return;
    this.saveState = "saving";
    clearTimeout(this.saveTimer);
    // every save joins the queue, so confirmation waits for all of them
    this.saveTimer = setTimeout(() => {
      this.enqueue(() => this.sync()).then(
        () => {
          this.saveState = "saved";
          this.emit();
        },
        () => {
          this.saveState = "error";
          this.emit();
        },
      );
    }, 450);
    this.emit();
  }

  // ---------------------------------------------------------------- user actions
  private snapshot() {
    this.undoStack.push(JSON.stringify({ items: this.data.items, base: [...this.base.values()], cur: this.cur, cid: this.item?.id }));
    if (this.undoStack.length > 80) this.undoStack.shift();
  }
  undo = () => {
    const s = this.undoStack.pop();
    if (!s) return;
    const o = JSON.parse(s) as { items: Item[]; base: Item[]; cur: number; cid?: string };
    // undo the user's own steps only: whatever the agent wrote since stays
    this.data.items = this.legacy
      ? o.items
      : rebase(o.items, new Map(o.base.map((i) => [i.id, i])), [...this.base.values()].map(clone), true).items;
    const k = this.data.items.findIndex((i) => i.id === o.cid);
    this.cur = this.legacy || k < 0 ? Math.min(o.cur, this.data.items.length - 1) : k;
    this.mediaSel = null;
    this.dir = "down";
    this.slideKey++;
    this.save();
    this.showToast(this.t("undone"));
  };

  go = (k: number, d?: "up" | "down") => {
    if (k < 0 || k >= this.data.items.length) return;
    this.dir = d || (k > this.cur ? "up" : "down");
    this.cur = k;
    this.mediaSel = null;
    this.slideKey++;
    this.emit();
  };
  nextPending = () => {
    const n = this.data.items.findIndex((i, k) => k > this.cur && statusOf(i) === "pending");
    this.go(n >= 0 ? n : Math.min(this.cur + 1, this.data.items.length - 1), "up");
  };
  decide = (kind: "keep" | "drop") => {
    const i = this.item;
    if (!i) return;
    this.snapshot();
    i._touched = true;
    if (kind === "keep") {
      i.status = "confirmed";
      delete i._dropped;
    } else {
      i.status = "deleted";
      i._dropped = true;
    }
    this.save();
    this.showToast(`${this.t(kind === "keep" ? "kept1" : "dropped1")} · ${i.id || ""}`, true, kind === "keep" ? "check" : "x");
    if (this.counts().p === 0 && this.cur === this.data.items.length - 1) {
      setTimeout(() => this.openFinish(), 250);
      return;
    }
    setTimeout(() => this.nextPending(), 90);
  };
  setSev = (v: string) => {
    const i = this.item;
    if (!i || kindOf(i) !== "issue") return;
    i.severity = v;
    this.save();
  };
  cycleSev = () => {
    const i = this.item;
    if (!i) return;
    const sev = (SEV as readonly string[]).includes(String(i.severity)) ? String(i.severity) : "medium";
    this.setSev(SEV[(SEV.indexOf(sev as never) + 1) % 3]);
  };
  cycleType = () => {
    const i = this.item;
    if (!i) return;
    const ks = Object.keys(this.types);
    i.type = ks[(ks.indexOf(String(i.type)) + 1) % ks.length];
    this.save();
  };
  mergePrev = () => {
    if (this.mode === "item") return;
    let j = this.cur - 1;
    while (j >= 0 && statusOf(this.data.items[j]) === "drop") j--;
    if (j < 0) return;
    this.snapshot();
    const p = this.data.items[j];
    const i = this.data.items[this.cur];
    mergeInto(p, i);
    this.data.items.splice(this.cur, 1);
    this.cur = j;
    this.dir = "down";
    this.slideKey++;
    this.save();
    this.showToast(`${this.t("merged")} ${p.id || ""}`, true);
  };
  /** a field edit from the inspector (value already parsed) */
  setField = (i: Item, k: string, v: unknown) => {
    if (k === "source") i.source = { ...(i.source || {}), url: String(v).trim() };
    else i[k] = v;
    this.save();
  };
  selectMedia = (src: string | null) => {
    this.mediaSel = src;
    this.emit();
  };
  stepMedia = (d: number) => {
    const items = this.mediaItems(this.item);
    const k = this.mediaIndex(items) + d;
    if (k < 0 || k >= items.length) return;
    this.mediaSel = items[k].src;
    this.emit();
  };
  setItem = (id: string) => {
    this.itemId = id;
    const k = this.findCur();
    if (k >= 0) {
      this.cur = k;
      this.mediaSel = null;
      this.slideKey++;
    }
    this.emit();
  };

  setView = (v: View) => {
    this.view = v;
    storage.set("blurt.view", v);
    this.slideKey++;
    this.emit();
  };
  openItem = (k: number) => {
    this.cur = k;
    this.mediaSel = null;
    this.setView("focus");
  };
  setFilter = (f: Filter) => {
    this.filter = f;
    this.emit();
  };
  setKindF = (k: string) => {
    this.kindF = k;
    this.emit();
  };
  setQuery = (q: string) => {
    this.query = q;
    this.emit();
  };
  toggleLang = () => {
    this.lang = this.lang === "zh" ? "en" : "zh";
    this.langPicked = true;
    storage.set("blurt.lang", this.lang);
    this.emit();
  };
  openLightbox = (src: string | null) => {
    this.lightbox = src;
    this.emit();
  };

  showToast(msg: string, withUndo = false, icon?: "check" | "x") {
    this.toast = { msg, undo: withUndo, show: true, icon };
    clearTimeout(this.toastTimer);
    this.toastTimer = setTimeout(() => {
      if (this.toast) this.toast = { ...this.toast, show: false };
      this.emit();
    }, 2200);
    this.emit();
  }
  copy = (text: string) => {
    void navigator.clipboard?.writeText(text);
    this.showToast(`${text} ${this.t("copy")}`);
  };

  openHelp = () => {
    this.modal = "help";
    this.emit();
  };
  closeModal = () => {
    this.modal = null;
    this.emit();
  };
  openFinish = () => {
    if (this.mode === "item" || this.confirmed) return;
    this.finishWarn = !!this.data.processing && !this.warnedProc; // allowed while frames still come in; say so once
    if (this.finishWarn) this.warnedProc = true;
    this.finishError = false;
    this.modal = "finish";
    this.emit();
  };
  reviewRest = () => {
    this.modal = null;
    const n = this.data.items.findIndex((i) => statusOf(i) === "pending");
    this.view = "focus";
    storage.set("blurt.view", "focus");
    this.go(n);
    this.emit();
  };

  finish = async () => {
    if (this.confirming) return;
    this.confirming = true;
    clearTimeout(this.saveTimer);
    const body = typeof document !== "undefined" ? document.body : null;
    if (body) body.inert = true;
    this.emit();
    try {
      await this.enqueue(async () => {
        // after every save already queued; whatever was typed and not yet saved goes with the confirmation
        const final = finalize(this.data.items);
        if (this.legacy) {
          await this.host.saveDoc?.({ ...this.data, items: final }, true);
          return;
        }
        await this.host.sendOps(diffOps(final, this.base), true);
      });
      this.confirmed = true;
      this.modal = null;
      clearTimeout(this.pollTimer);
      this.host.confirmed?.();
    } catch {
      this.confirming = false;
      this.finishError = true;
    } finally {
      if (body) body.inert = false;
      this.emit();
    }
  };

  fixWithAgent = () => {
    const i = this.item;
    if (!i || !this.host.fixWithAgent) return;
    this.host.fixWithAgent([i.uid || i.id]);
  };

  // ---------------------------------------------------------------- keyboard
  togglePlay = () => {
    const v = document.querySelector<HTMLVideoElement>("#mediaBox video");
    if (v) {
      if (v.paused) void v.play();
      else v.pause();
      return;
    }
    const items = this.mediaItems(this.item);
    const k = items.findIndex((m) => m.kind === "clip" || m.kind === "orig");
    if (k >= 0) this.playAt(items[k].src);
  };
  playOrig = () => {
    const items = this.mediaItems(this.item);
    const m = items.find((x) => x.kind === "orig");
    if (m) this.playAt(m.src);
  };
  private playAt(src: string) {
    this.selectMedia(src);
    setTimeout(() => void document.querySelector<HTMLVideoElement>("#mediaBox video")?.play().catch(() => {}), 60);
  }
  editTitle = () => {
    const ta = document.querySelector<HTMLTextAreaElement>(".insp .title");
    ta?.focus();
    ta?.select();
  };

  onKeyDown = (e: KeyboardEvent) => {
    if (!this.loaded || this.confirming || this.confirmed || e.defaultPrevented) return;
    const ae = document.activeElement as HTMLElement | null;
    const typing = !!ae && (/INPUT|TEXTAREA|SELECT/.test(ae.tagName) || ae.isContentEditable);
    if ((e.metaKey || e.ctrlKey) && e.key === "Enter") {
      if (imeBusy(e)) return;
      e.preventDefault();
      if (this.mode === "item") this.fixWithAgent();
      else this.openFinish();
      return;
    }
    if (e.key === "Escape") {
      if (this.modal) this.closeModal();
      else if (this.lightbox) this.openLightbox(null);
      else ae?.blur();
      return;
    }
    if (typing || e.metaKey || e.ctrlKey || e.altKey) return;
    if (this.modal) return;
    if (this.lightbox) return;
    const k = e.key;
    if (k === "Enter" && !isEnter(e)) return; // an input method's Enter
    if (k === "?") return this.openHelp();
    if (this.mode === "review") {
      if (k === "g" || k === "G") return this.setView(this.view === "focus" ? "list" : "focus");
      if ((k === "v" || k === "V") && this.hasOverview) return this.setView("overview");
      if (this.view !== "focus") return;
    }
    const review = this.mode === "review";
    const map: Record<string, (() => void) | undefined> = {
      ArrowLeft: () => this.stepMedia(-1),
      ArrowRight: () => this.stepMedia(1),
      " ": this.togglePlay,
      o: this.playOrig,
      e: this.editTitle,
      "1": () => this.setSev("high"),
      "2": () => this.setSev("medium"),
      "3": () => this.setSev("low"),
      ...(review
        ? {
            j: () => this.go(this.cur + 1, "up"),
            ArrowDown: () => this.go(this.cur + 1, "up"),
            k: () => this.go(this.cur - 1, "down"),
            ArrowUp: () => this.go(this.cur - 1, "down"),
            a: () => this.decide("keep"),
            Enter: () => this.decide("keep"),
            x: () => this.decide("drop"),
            Backspace: () => this.decide("drop"),
            Delete: () => this.decide("drop"),
            z: this.undo,
            u: this.undo,
            m: this.mergePrev,
          }
        : {}),
    };
    const f = map[k] || map[k.toLowerCase?.()];
    if (f) {
      e.preventDefault();
      f();
    }
  };

  /** wheel / swipe on the stage moves between items */
  private wheelLock = 0;
  onWheel = (e: WheelEvent) => {
    if (this.mode !== "review") return;
    if ((e.target as HTMLElement).closest?.("video,.strip")) return;
    if (Math.abs(e.deltaY) < 18 || Date.now() < this.wheelLock) return;
    this.wheelLock = Date.now() + 520;
    if (e.deltaY > 0) this.go(this.cur + 1, "up");
    else this.go(this.cur - 1, "down");
  };

  /** list view: the visible cards */
  listed() {
    const ql = this.query.toLowerCase();
    return this.data.items
      .map((i, k) => ({ i, k, s: statusOf(i) }))
      .filter(
        ({ i, s }) =>
          (this.filter === "all" || this.filter === s) &&
          (!this.kindF || kindOf(i) === this.kindF) &&
          (!ql ||
            [i.title, i.module, i.owner, i.id, i.summary, (i.tags || []).join(" ")].join(" ").toLowerCase().includes(ql)),
      );
  }

  /** for tests and hosts: the unsaved local difference */
  pendingOps() {
    return diffOps(this.data.items, this.base);
  }
  isDirty() {
    return this.data.items.some((i) => canon(i) !== canon(this.base.get(i.id)));
  }
}
