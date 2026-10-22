/* All review state and actions. React components read it through useStore() and call its methods; every change
   bumps `version` and notifies subscribers.

   Two doc shapes (host.ts): v2 (a session's items.json, ops by display id) and v3 (K1 doc: a session or a project,
   ops by uid, projects). Everything the page edits is a field diff (sync.ts); the one thing that is an action rather
   than a field — a state change (K3: keep, done, send back, discard…) — goes as an explicit `state` op, sent at once
   and shown optimistically until the server's answer arrives. */
import { resolveLang, systemLanguages } from "@blurt/i18n";
import { actionForKey, canDo, isInbox, migrate, stateOf, targetOf, type Action, type State } from "@blurt/ui";
import type { BlurtHost, Item, MountOptions, ProjectRef, ReviewDoc, UserOp } from "./host";
import { humanizeKey } from "./fields";
import { makeI18n, SEVERITIES, TYPES, type I18n } from "./i18n";
import { imeBusy, isEnter } from "./ime";
import { byId, byUid, canon, clone, diffOps, mergeInto, norm, rebase, statusOf, type KeyFn } from "./sync";

export type View = "overview" | "focus" | "list";
/** the list's one state filter: everything but discarded, what needs you, or one state */
export type StateFilter = "live" | "inbox" | State;
export type ProcPhase = "hidden" | "working" | "fin" | "out";
export type SaveState = "" | "saving" | "saved" | "error";

export interface Media {
  kind: "img" | "wait" | "clip" | "orig";
  src: string;
  /** the path as the doc has it (absolute on v3) */
  rel?: string;
  label: string;
  cap?: string;
  start?: number;
  end?: number;
}

export const SEV = SEVERITIES;
/** a title worth saving: not empty, not only whitespace (the stores refuse anything else) */
export const isTitle = (v: unknown): v is string => typeof v === "string" && v.trim() !== "";
const MEDIA_POLL_PROCESSING = 1500;
const POLL_IDLE = 2000; // agent writes (set-frames, a chat answer, a work state) show up within ~2 s
const POLL_HIDDEN = 15000;
const STALL_S = 600;

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
  readonly embedded: boolean;
  itemId: string | null;

  i18n: I18n;
  version = 0;
  loaded = false;
  loadError: string | null = null;
  data: ReviewDoc = { items: [] };
  base = new Map<string, Item>();
  etag = "";
  legacy = false;
  /** ops address items by uid (v3) or display id (v2) */
  key: KeyFn = byId;

  cur = 0;
  mediaSel: string | null = null;
  dir: "up" | "down" = "up";
  /** bumps when the stage should slide in */
  slideKey = 0;
  view: View = "focus";
  stateF: StateFilter = "live";
  query = "";
  kindF = "";
  /** the current item's state menu is open (S opens it) */
  menuOpen = false;
  /** list view: selected item keys */
  selected = new Set<string>();
  private anchor: string | null = null;
  dragging = false;

  saveState: SaveState = "";
  confirming = false;
  confirmed = false;
  finishError = false;
  warnedProc = false;
  finishWarn = false;
  modal: null | "help" | "finish" = null;
  toast: { msg: string; undo: boolean; show: boolean; icon?: "check" | "x" | "copy" | "folder" } | null = null;
  lightbox: string | null = null;
  proc: ProcPhase = "hidden";

  /** media sources that arrived with a server update (they fade in) */
  fresh = new Set<string>();
  /** the last server update: item key → changed keys */
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
  /** state ops not yet answered by the server; their state is shown optimistically */
  private actionOps: UserOp[] = [];
  private pendingState = new Map<string, Pick<Item, "state" | "restore_to">>();
  /** items discarded here: they stay in the page (struck through, undoable) when the doc no longer lists them */
  private discardedHere = new Set<string>();

  constructor(host: BlurtHost, opts: MountOptions = {}) {
    this.host = host;
    this.mode = opts.mode === "item" ? "item" : "review";
    this.embedded = !!opts.embedded;
    this.itemId = opts.itemId ?? null;
    const picked = this.embedded ? null : storage.get("blurt.lang");
    this.langPicked = !!picked || !!opts.lang;
    this.i18n = makeI18n(resolveLang(picked || opts.lang, systemLanguages()));
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
  get lang() {
    return this.i18n.lang;
  }
  t = (k: string, p?: Record<string, string | number | null | undefined>) => this.i18n.t(k, p);
  plural = (k: string, n: number, p?: Record<string, string | number | null | undefined>) => this.i18n.plural(k, n, p);
  kindLabel = (k: string) => (this.i18n.has(`kind.${k}`) ? this.t(`kind.${k}`) : humanizeKey(k));
  typeLabel = (k: string) => (this.i18n.has(`type.${k}`) ? this.t(`type.${k}`) : humanizeKey(k));
  stateLabel = (s: State) => this.t(`state.${s}`);
  /** "0:14" / "1:02:05" */
  clock = (s: unknown) => this.i18n.formatDuration(Number(s) || 0);
  get types(): readonly string[] {
    return TYPES;
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

  get v3() {
    return this.key === byUid;
  }
  get item(): Item | undefined {
    return this.data.items[this.cur];
  }
  keyOf = (i: Item) => this.key(i);
  /** the review's view of the state: pending (new) · drop (discarded) · keep (anything else) */
  st = (i: Item) => statusOf(i);
  get stalled(): boolean {
    const raw = this.data.agent_at;
    const at = typeof raw === "string" ? Date.parse(raw) / 1000 : Number(raw);
    return !!this.data.processing && !!at && Date.now() / 1000 - at > STALL_S;
  }
  get hasOverview() {
    return !!(this.data.digest || this.data.title);
  }
  /** a session's batch (review / finish) rather than a project's list */
  get isSession() {
    return !this.data.scope || "session" in this.data.scope;
  }
  counts() {
    let k = 0, d = 0, p = 0;
    for (const i of this.data.items) {
      const s = this.st(i);
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
      label: f.t != null ? this.clock(f.t) : this.t("media.frame", { n: k + 1 }),
      cap: f.caption,
    }));
    if (!m.length && this.data.processing) m.push({ kind: "wait", src: "wait:" + this.key(i), label: "…" });
    if (i.clip) m.push({ kind: "clip", src: this.host.fileUrl(i.clip), rel: i.clip, label: this.t("media.clip") });
    if (this.hasVideo(i))
      m.push({
        kind: "orig", src: this.host.fileUrl(String(this.data.source_video)), rel: String(this.data.source_video),
        label: this.t("media.recording"), start: i.time!.start, end: i.time!.end,
      });
    return m;
  }
  mediaIndex(items: Media[]) {
    const k = items.findIndex((m) => m.src === this.mediaSel);
    return k >= 0 ? k : 0;
  }

  // ---------------------------------------------------------------- projects and work (v3)
  get projects(): ProjectRef[] {
    return this.v3 && Array.isArray(this.data.projects) ? this.data.projects : [];
  }
  project(id: string | null | undefined): ProjectRef | undefined {
    if (!id) return undefined;
    return this.projects.find((p) => p.id === id) ?? (id === "inbox" ? { id: "inbox", key: "IN", name: this.t("project.inbox") } : undefined);
  }
  projectName = (p: ProjectRef | undefined) => (!p ? "" : p.id === "inbox" ? this.t("project.inbox") : p.name);
  get canMove() {
    return this.projects.length > 0;
  }
  stateOf = (i: Item): State => stateOf(i);
  restoreTo = (i: Item): State | undefined => migrate(i).restore_to;
  /** the menu offers "Hand off…" (dispatch in an app window, a copied instruction where review.py can write one) */
  get canHandOff() {
    return !!this.host.dispatch || this.canHandoff;
  }

  /** `restore`: where a discarded item goes back to (default: the state it leaves) */
  private setLocal(i: Item, to: State, restore: State) {
    i.state = to;
    if (to === "discarded") i.restore_to = restore;
    else delete i.restore_to;
    const k = this.key(i);
    this.pendingState.set(k, { state: i.state, restore_to: i.restore_to });
    if (to === "discarded") this.discardedHere.add(k);
    else this.discardedHere.delete(k);
  }

  /** The user's state change (K3): optimistic here, one `state` op per item, undoable. Hand off opens the host's
      panel (or copies an instruction) instead — the host writes that state. Items the action doesn't apply to are
      left alone. Returns how many items changed. */
  act = (items: Item[], action: Action, opts: { toast?: boolean } = {}): number => {
    if (action === "hand_off") {
      const ok = items.filter((i) => canDo("hand_off", this.stateOf(i)));
      if (this.host.dispatch) this.dispatch(ok);
      else void this.handoff(ok, "instruction");
      return 0;
    }
    const moves = items.map((i) => ({ i, from: this.stateOf(i), to: targetOf(action, i) })).filter((m): m is { i: Item; from: State; to: State } => !!m.to);
    if (!moves.length) return 0;
    this.snapshot();
    for (const { i, from, to } of moves) {
      this.setLocal(i, to, from);
      if (!this.legacy) this.actionOps.push({ op: "state", id: this.key(i), action });
    }
    this.flush();
    if (opts.toast !== false) {
      const to = moves[0].to;
      const ids = this.i18n.formatList(moves.map((m) => m.i.id || ""));
      this.showToast(this.t("toast.state", { state: this.stateLabel(to), id: ids }), true, to === "discarded" ? "x" : to === "todo" || to === "done" ? "check" : undefined);
    }
    return moves.length;
  };
  /** the current item, by shortcut (A D R W X, or the menu) */
  actOnCurrent = (action: Action) => {
    const i = this.item;
    if (i) this.act([i], action);
  };
  setMenuOpen = (open: boolean) => {
    if (this.menuOpen === open) return;
    this.menuOpen = open;
    this.emit();
  };

  /** move items to a project (K2: the user's choice, never overridden by AI) */
  moveTo = (items: Item[], projectId: string) => {
    const moving = items.filter((i) => i.project !== projectId);
    if (!this.canMove || !moving.length) return;
    this.snapshot();
    for (const i of moving) i.project = projectId;
    this.flush();
    const name = this.projectName(this.project(projectId));
    this.showToast(this.plural("project.moved", moving.length, { project: name }), false, "folder");
  };

  /** the host can write a handoff (the browser page only when review.py says it can: doc `_caps`) */
  get canHandoff() {
    const caps = Array.isArray(this.data._caps) ? (this.data._caps as string[]) : [];
    return !!this.host.handoff && (this.host.host !== "browser" || caps.includes("handoff"));
  }
  handoff = async (items: Item[], what: "instruction" | "full") => {
    const h = this.canHandoff ? this.host.handoff : undefined;
    const live = items.filter((i) => this.stateOf(i) !== "discarded");
    if (!h || !live.length) return;
    try {
      const r = await h(live.map((i) => i.uid || i.id), what);
      this.showToast(this.t(what === "full" ? "handoff.copied.full" : "handoff.copied.instruction", { id: r.id }), false, "copy");
      this.pollNow();
    } catch {
      this.showToast(this.t("handoff.failed"), false, "x");
    }
  };
  dispatch = (items: Item[]) => {
    const live = items.filter((i) => this.stateOf(i) !== "discarded");
    if (this.host.dispatch && live.length) this.host.dispatch(live.map((i) => i.uid || i.id));
  };
  openSession = (job: string) => this.host.openSession?.(job);

  // ---------------------------------------------------------------- selection (list view)
  isSelected = (i: Item) => this.selected.has(this.key(i));
  selectedItems = () => this.data.items.filter((i) => this.selected.has(this.key(i)));
  /** click: toggle; shift: the range from the last toggled card over the visible cards */
  toggleSelect = (i: Item, range = false) => {
    const k = this.key(i);
    const vis = this.listed().map(({ i }) => this.key(i));
    if (range && this.anchor && vis.includes(this.anchor)) {
      const [a, b] = [vis.indexOf(this.anchor), vis.indexOf(k)].sort((x, y) => x - y);
      for (const x of vis.slice(a, b + 1)) this.selected.add(x);
    } else if (this.selected.has(k)) this.selected.delete(k);
    else this.selected.add(k);
    this.anchor = k;
    this.emit();
  };
  selectAll = () => {
    for (const { i } of this.listed()) this.selected.add(this.key(i));
    this.emit();
  };
  clearSelection = () => {
    this.selected.clear();
    this.anchor = null;
    this.emit();
  };
  setDragging = (on: boolean) => {
    this.dragging = on;
    if (on && this.toast) this.toast = { ...this.toast, show: false }; // the drop zone takes the bottom of the window
    this.emit();
  };

  // ---------------------------------------------------------------- loading and syncing
  private setTop(doc: ReviewDoc) {
    for (const k of Object.keys(this.data)) if (k !== "items" && !(k in doc)) delete this.data[k];
    for (const [k, v] of Object.entries(doc)) if (k !== "items") this.data[k] = v;
  }
  private findCur(): number {
    if (this.mode !== "item" || !this.itemId) return -1;
    const want = this.itemId;
    return this.data.items.findIndex((i) => i.id === want || i.uid === want || (i.aliases || []).includes(want));
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
      this.key = Number(doc.schema) >= 3 ? byUid : byId;
      this.legacy = (doc.items || []).some((i) => !i.id); // hand-written file without ids: save it whole, as before
      this.setTop(doc);
      const S = norm(doc.items);
      this.data.items = S.map(clone);
      this.base = new Map(S.map((i) => [this.key(i), clone(i)]));
      if (!this.langPicked && this.data.language) this.i18n = makeI18n(resolveLang(String(this.data.language), systemLanguages()));
      if (this.mode === "item") this.cur = Math.max(0, this.findCur());
      else this.cur = Math.max(0, this.data.items.findIndex((i) => this.st(i) === "pending"));
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

  private applyServer(doc: ReviewDoc) {
    const cid = this.item ? this.key(this.item) : undefined;
    const prevProc = !!this.data.processing;
    const S = norm(doc.items);
    // what the user discarded here stays on the page (struck through, undoable) even when the doc leaves it out
    const keep = (k: string) => this.discardedHere.has(k);
    const res = rebase(this.data.items, this.base, S, false, this.key, keep);
    this.data.items = res.items;
    this.base = new Map(S.map((i) => [this.key(i), clone(i)]));
    for (const i of this.data.items) {
      const k = this.key(i);
      if (!this.base.has(k) && keep(k)) this.base.set(k, clone(i)); // not a new item to add
      // states the server hasn't answered yet stay as the user set them
      const p = this.pendingState.get(k);
      if (p) {
        i.state = p.state;
        if (p.restore_to) i.restore_to = p.restore_to;
        else delete i.restore_to;
      }
    }
    if (this.mode === "item") {
      const k = this.findCur();
      this.cur = k >= 0 ? k : this.cur;
    } else {
      const k = this.data.items.findIndex((i) => this.key(i) === cid);
      this.cur = k >= 0 ? k : Math.min(this.cur, Math.max(0, this.data.items.length - 1));
    }
    const keys = new Set(this.data.items.map(this.key));
    for (const k of [...this.selected]) if (!keys.has(k)) this.selected.delete(k);
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

  private async accept(r: { etag: string; doc?: ReviewDoc }, before: string) {
    if (r.doc) {
      this.etag = r.etag || this.etag;
      this.applyServer(r.doc);
      return;
    }
    // the host only acknowledged: fetch the merged doc, so base includes what we just wrote
    const p = await this.host.poll(before);
    this.etag = p.etag || r.etag || this.etag;
    if (p.doc) this.applyServer(p.doc);
  }

  private async sync() {
    if (this.legacy) {
      await this.host.saveDoc?.(this.data, false);
      return;
    }
    const actions = this.actionOps.splice(0);
    const ops = [...actions, ...diffOps(this.data.items, this.base, this.key)];
    if (!ops.length) return;
    const before = this.etag;
    const sent = this.data.items.map(clone);
    try {
      const r = await this.host.sendOps(ops);
      // the server has what we sent: rebase server updates on that, so an item that left the scope (moved to another
      // project) goes away instead of looking like a local edit
      this.base = new Map(sent.map((i) => [this.key(i), i]));
      for (const a of actions)
        if (a.op === "state" && !this.actionOps.some((b) => b.op === "state" && b.id === a.id)) this.pendingState.delete(a.id);
      await this.accept(r, before);
    } catch (e) {
      this.actionOps.unshift(...actions); // retried with the next save
      throw e;
    }
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

  /** autosave: field edits wait 450 ms (typing); `flush` sends now (moves, work states) */
  save(delay = 450) {
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
    }, delay);
    this.emit();
  }
  flush = () => this.save(0);

  // ---------------------------------------------------------------- user actions
  private snapshot() {
    this.undoStack.push(JSON.stringify({ items: this.data.items, base: [...this.base.values()], cur: this.cur, cid: this.item && this.key(this.item) }));
    if (this.undoStack.length > 80) this.undoStack.shift();
  }
  undo = () => {
    const s = this.undoStack.pop();
    if (!s) return;
    const o = JSON.parse(s) as { items: Item[]; base: Item[]; cur: number; cid?: string };
    const now = new Map(this.data.items.map((i) => [this.key(i), this.stateOf(i)]));
    const was = new Map(o.items.map((i) => [this.key(i), migrate(i)])); // before the rebase writes the server's into them
    // undo the user's own steps only: whatever the agent wrote since stays
    this.data.items = this.legacy
      ? o.items
      : rebase(o.items, new Map(o.base.map((i) => [this.key(i), i])), [...this.base.values()].map(clone), true, this.key).items;
    // a state the user changed goes back explicitly (the server owns `state`): {op: "state", state, undo: true}.
    // Items no longer on the page (merged away) come back through the merge's own undo (`add`).
    for (const i of this.data.items) {
      const k = this.key(i);
      const { state, restore_to } = was.get(k) ?? {};
      if (state && now.has(k) && state !== now.get(k)) {
        this.setLocal(i, state, restore_to ?? "new");
        if (!this.legacy) this.actionOps.push({ op: "state", id: k, state, undo: true });
        continue;
      }
      const p = this.pendingState.get(k); // unanswered: still as the user set it
      if (p) Object.assign(i, p);
    }
    const k = this.data.items.findIndex((i) => this.key(i) === o.cid);
    this.cur = this.legacy || k < 0 ? Math.min(o.cur, this.data.items.length - 1) : k;
    this.mediaSel = null;
    this.menuOpen = false;
    this.dir = "down";
    this.slideKey++;
    this.save();
    this.showToast(this.t("toast.undone"));
  };

  go = (k: number, d?: "up" | "down") => {
    if (k < 0 || k >= this.data.items.length) return;
    this.dir = d || (k > this.cur ? "up" : "down");
    this.cur = k;
    this.mediaSel = null;
    this.menuOpen = false;
    this.slideKey++;
    this.emit();
  };
  nextPending = () => {
    const n = this.data.items.findIndex((i, k) => k > this.cur && this.st(i) === "pending");
    this.go(n >= 0 ? n : Math.min(this.cur + 1, this.data.items.length - 1), "up");
  };
  /** review mode: keep (new → to do) or discard the current item, then go on to the next new one. Keep on an item
      that is already past new just moves on. */
  decide = (kind: "keep" | "discard") => {
    const i = this.item;
    if (!i) return;
    const s = this.stateOf(i);
    if (s === "discarded") return; // R restores it
    if (kind === "discard" || s === "new") this.act([i], kind);
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
    const ks = this.types;
    i.type = ks[(ks.indexOf(String(i.type)) + 1) % ks.length];
    this.save();
  };
  mergePrev = () => {
    if (this.mode === "item") return;
    let j = this.cur - 1;
    while (j >= 0 && this.st(this.data.items[j]) === "drop") j--;
    if (j < 0) return;
    this.snapshot();
    const p = this.data.items[j];
    const i = this.data.items[this.cur];
    mergeInto(p, i, this.key);
    this.data.items.splice(this.cur, 1);
    this.cur = j;
    this.dir = "down";
    this.slideKey++;
    this.save();
    this.showToast(this.t("toast.merged", { id: p.id || "" }), true);
  };
  /** a field edit from the inspector (value already parsed); false (nothing changed or sent) for an empty title */
  setField = (i: Item, k: string, v: unknown): boolean => {
    if (k === "title" && !isTitle(v)) return false;
    if (k === "source") i.source = { ...(i.source || {}), url: String(v).trim() };
    else i[k] = v;
    this.save();
    return true;
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
      this.menuOpen = false;
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
    this.menuOpen = false;
    this.setView("focus");
  };
  setStateF = (f: StateFilter) => {
    this.stateF = f;
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
  setLang = (lang: string) => {
    this.i18n = makeI18n(lang);
    this.langPicked = true;
    this.emit();
  };
  toggleLang = () => {
    this.setLang(this.lang === "zh-Hans" ? "en" : "zh-Hans");
    storage.set("blurt.lang", this.lang);
  };
  openLightbox = (src: string | null) => {
    this.lightbox = src;
    this.emit();
  };

  showToast(msg: string, withUndo = false, icon?: "check" | "x" | "copy" | "folder") {
    this.toast = { msg, undo: withUndo, show: true, icon };
    clearTimeout(this.toastTimer);
    this.toastTimer = setTimeout(() => {
      if (this.toast) this.toast = { ...this.toast, show: false };
      this.emit();
    }, 2400);
    this.emit();
  }
  copy = (text: string) => {
    void navigator.clipboard?.writeText(text);
    this.showToast(this.t("toast.copied", { text }), false, "copy");
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
    if (this.mode === "item" || this.confirmed || !this.isSession) return;
    this.finishWarn = !!this.data.processing && !this.warnedProc; // allowed while frames still come in; say so once
    if (this.finishWarn) this.warnedProc = true;
    this.finishError = false;
    this.modal = "finish";
    this.emit();
  };
  reviewRest = () => {
    this.modal = null;
    const n = this.data.items.findIndex((i) => this.st(i) === "pending");
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
        // after every save already queued; whatever was typed and not yet saved goes with the confirmation, and what
        // is still new is kept (finishing = "keep the rest")
        const rest = this.data.items.filter((i) => this.stateOf(i) === "new");
        if (this.legacy) {
          const items = this.data.items.map(clone);
          for (const i of items) if (this.stateOf(i) === "new") i.state = "todo";
          await this.host.saveDoc?.({ ...this.data, items }, true);
          return;
        }
        const keeps: UserOp[] = rest.map((i) => ({ op: "state", id: this.key(i), action: "keep" }));
        await this.host.sendOps([...this.actionOps.splice(0), ...keeps, ...diffOps(this.data.items, this.base, this.key)], true);
        for (const i of rest) i.state = "todo";
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
      if (this.mode === "item") this.item && this.act([this.item], "hand_off");
      else this.openFinish();
      return;
    }
    if (e.key === "Escape") {
      if (this.modal) this.closeModal();
      else if (this.lightbox) this.openLightbox(null);
      else if (this.selected.size && !typing) this.clearSelection();
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
      s: () => this.item && this.setMenuOpen(true),
      "1": () => this.setSev("high"),
      "2": () => this.setSev("medium"),
      "3": () => this.setSev("low"),
      ...(review
        ? {
            j: () => this.go(this.cur + 1, "up"),
            ArrowDown: () => this.go(this.cur + 1, "up"),
            k: () => this.go(this.cur - 1, "down"),
            ArrowUp: () => this.go(this.cur - 1, "down"),
            // the review's own keep / discard go on to the next new item
            a: () => this.decide("keep"),
            Enter: () => this.decide("keep"),
            x: () => this.decide("discard"),
            Backspace: () => this.decide("discard"),
            Delete: () => this.decide("discard"),
            z: this.undo,
            u: this.undo,
            m: this.mergePrev,
          }
        : {}),
    };
    // the rest of K3's keys (D done, R back, W won't do; A and X in item mode): whatever is valid for the state
    const action = this.item ? actionForKey(this.stateOf(this.item), k) : null;
    const f = map[k] || map[k.toLowerCase?.()] || (action && action !== "hand_off" ? () => this.actOnCurrent(action) : undefined);
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
    const f = this.stateF;
    const want = (s: State) => (f === "live" ? s !== "discarded" : f === "inbox" ? isInbox(s) : s === f);
    return this.data.items
      .map((i, k) => ({ i, k, s: this.st(i) }))
      .filter(
        ({ i }) =>
          want(this.stateOf(i)) &&
          (!this.kindF || kindOf(i) === this.kindF) &&
          (!ql ||
            [i.title, i.module, i.owner, i.id, i.summary, (i.tags || []).join(" "), ...(i.aliases || [])].join(" ").toLowerCase().includes(ql)),
      );
  }

  /** for tests and hosts: the unsaved local difference */
  pendingOps() {
    return [...this.actionOps, ...diffOps(this.data.items, this.base, this.key)];
  }
  isDirty() {
    return this.actionOps.length > 0 || this.data.items.some((i) => canon(i) !== canon(this.base.get(this.key(i))));
  }
}
