// The main window on Windows / Linux, laid out and behaving as the macOS app's (MainWindowController and its parts;
// docs/design/windows-parity/main-window.md has every row of the comparison): a toolbar (the sidebar button, Record,
// Snap — and, since Windows has no menu bar, the ⋯ menu with the Mac's File / View / Help commands), the sidebar
// (places, projects, + Open Folder…, the Settings gear), the list (its heading with the order, the filter, + New and
// the search field; the running jobs; the grouped rows) and the detail (the item in the review component, several
// items' summary, a job, or nothing). Every write goes through the CLIs; each undoable one is on the window's undo
// stack (Ctrl+Z, the toast's Undo). Settings takes the list and detail columns when opened; so do the pages — Home,
// Dictation, Cards, Phone —, as on the Mac. Everything follows the capability switches (docs/design/capabilities.md):
// an off capability has no place in the sidebar, the palette, the toolbar or the keys; the first open lands on Home.

import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import { Icon } from '@blurt/icons';
import { applyPlatform, applyTheme, menuCase, targetOf, type Action, type State } from '@blurt/ui';
import { KindIcon, StatusRing } from '@blurt/ui/react';
import { getCurrentWindow } from '@tauri-apps/api/window';
import { api, builds, inTauri, invoke, listen, type AppStatus, type AttachResult, type HotkeyRow, type ItemRow, type Job, type Onboarding, type ProjectList, type ProjectRow, type Summary } from './api';
import { codeUrl, hostFor, type HostCallbacks } from './host';
import type { ReviewHandle } from './review';
import { errText, i18n, plural, setLang, t } from './i18n';
import { isImeKey } from './ime';
import { debounce, inField, nextSelection } from './util';
import {
  ACTIVE,
  actionForListKey,
  actionKey,
  actionsFor,
  ascendsByDefault,
  bannerPlan,
  bySuggestion,
  group,
  grouping as groupingOf,
  handOffBlock,
  isPage,
  isProject,
  LIVE_STATES,
  NO_FILTER,
  needsYouParts,
  orderedProjects,
  reorderedProjects,
  placeQuery,
  showsState,
  SORT_KEYS,
  suggestionGroups,
  validFor,
  type HandOffBlock,
  type Place,
  type PlaceFilter,
  type SortKey,
  type UndoStep,
} from './places';
import { EmptyState } from './components/EmptyState';
import { Tooltip } from './components/Tooltip';
import { FilterGlyph, MissingFolderGlyph, PinGlyph, ProgressGlyph, ProjectGlyph, ScopeGlyph, SidebarGlyph, UnassignedGlyph } from './components/glyphs';
import { ItemBanner, bannerTitle } from './components/ItemBanner';
import { ItemList, stateText } from './components/ItemList';
import { JobDetail, RecordingDetail, type RecDetail } from './components/JobDetail';
import { recLength, RecordingsSection, useAgentReady, useRecordingInfos, type RecHandlers } from './components/Recordings';
import { emptyStateShown, placeJobList, placeRecordings, recordings, samePath, type Recording } from './recordings';
import { CapturesBanner, FilterBar, JobsSection, ListHeading, MissingFolderBanner, SearchField, SuggestionsBanner } from './components/ListHeading';
import { tidy, useMenu, type MenuEntry, type MenuItem } from './components/Menu';
import { MovePopover } from './components/MovePopover';
import { NewItemSheet, prefillFromText, type Prefill } from './components/NewItemSheet';
import { CARDS_MIME, DragState, attachedAfter, detailTakes, dragKind, droppedText, dropLabel, parseCards, pasteTarget, pathsByName, sortEntries, titleFromFiles, type CardRef, type DragKind, type DropEntry, type PasteTo, type Zone } from './drops';
import { Palette, type PaletteEntry } from './components/Palette';
import { ProjectSettingsSheet } from './components/ProjectSettingsSheet';
import { PhoneAsk } from './settings/PhonePane';
import { ReviewPane } from './components/ReviewPane';
import { SelectionView, type PlanAction } from './components/SelectionView';
import { goSettingsPane, SettingsView } from './components/SettingsView';
import { DictationView } from './components/DictationView';
import { Shortcuts } from './components/Shortcuts';
import { AgentSetupAsk } from './components/AgentSetupAsk';
import { Sidebar, webview } from './components/Sidebar';
import { Welcome } from './components/Welcome';
import { HomePage } from './components/HomePage';
import { CardsPage } from './components/CardsPage';
import { PhonePage } from './components/PhonePage';
import { ScreenTextPage } from './components/ScreenTextPage';
import { useOff } from './components/useCapabilities';
import { useRemoteStatus } from './settings/phone';
import { phoneNeedsAttention, placeShown } from './capabilities';
import './components/main-window.css';
import { revealLabel } from './reveal';

const LIMIT = 20_000;
const KINDS = ['issue', 'idea', 'note', 'task'] as const;
const GUIDE = 'https://github.com/AGIHunt/blurt/blob/main/docs/guide.md#';
const STORE = 'blurt.main-window';

interface Saved {
  place?: Place;
  sort?: SortKey;
  ascending?: boolean;
  filters?: Record<string, PlaceFilter>;
  selected?: string[];
  sidebar?: boolean;
  detail?: boolean;
  sideW?: number;
  listW?: number;
  /** Home has been shown once: the first open (an upgrade's too) lands there, later ones where the window was left */
  homeSeen?: boolean;
}
const loadSaved = (): Saved => {
  try {
    return JSON.parse(localStorage.getItem(STORE) ?? '{}') as Saved;
  } catch {
    return {};
  }
};

type Screen = { kind: 'main' } | { kind: 'settings' };
type Detail = { kind: 'session'; dir: string; project: string | null } | { kind: 'job'; id: string } | { kind: 'recording'; dir: string } | null;
interface Toast {
  msg: string;
  undo?: () => void;
  action?: { label: string; run: () => void };
  /** the leading mark: a done step (✓ in the ok colour) or a refusal (⚠ in the attention colour) */
  mark?: 'ok' | 'warn';
  /** it went (replaced, expired) — the review page's toasts wait for this (host.toast's "gone") */
  gone?: () => void;
  id: number;
}

function startPlace(sv: string | null | undefined): { place?: Place; screen?: Screen; session?: string } {
  if (!sv) return {};
  if (sv.startsWith('review:')) return { session: sv.slice(7) };
  if (sv.startsWith('project:')) return { place: sv as Place };
  if (sv === 'settings') return { screen: { kind: 'settings' } };
  if (['home', 'cards', 'screen_text', 'phone', 'inbox', 'all', 'dictation', 'progress', 'unassigned'].includes(sv)) return { place: sv as Place };
  if (sv === 'items') return { place: 'all' };
  return {};
}

/** "storefront-2026-11-02-3-items.zip" (HandoffBundle.fileName) */
function bundleName(project: string | null, n: number, zh: boolean): string {
  const slug = (project ?? '').normalize('NFKD').replace(/[^\w一-鿿-]+/g, '-').replace(/^-+|-+$/g, '').toLowerCase() || 'blurt';
  const d = new Date();
  const day = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
  return `${slug}-${day}-${zh ? `${n}条` : n === 1 ? '1-item' : `${n}-items`}.zip`;
}

export default function App() {
  const saved = useRef(loadSaved()).current;
  const [status, setStatus] = useState<AppStatus | null>(null);
  const [, setLangTick] = useState(0);
  const [projects, setProjects] = useState<ProjectList | null>(null);
  const [summary, setSummary] = useState<Summary | null>(null);
  const [jobs, setJobs] = useState<Job[]>([]);
  /** agent id → its name (agents.json): "Codex is working on it" */
  const [agentNames, setAgentNames] = useState<Record<string, string>>({});
  useEffect(() => {
    api.agentsRegistry().then((r) => setAgentNames(Object.fromEntries(r.agents.map((a) => [a.id, a.name]))), () => {});
  }, []);
  const [place, setPlace] = useState<Place>(saved.homeSeen ? saved.place ?? 'home' : 'home');
  const { off, known: offKnown } = useOff();
  const recordingOn = !off.has('recording');
  const remote = useRemoteStatus();
  const [cardsWaiting, setCardsWaiting] = useState(0);
  const [screen, setScreen] = useState<Screen>({ kind: 'main' });
  const [filters, setFilters] = useState<Record<string, PlaceFilter>>(saved.filters ?? {});
  const [text, setText] = useState('');
  const [sort, setSort] = useState<SortKey>(saved.sort ?? 'updated');
  const [ascending, setAscending] = useState(saved.ascending ?? false);
  const [raw, setRaw] = useState<ItemRow[]>([]);
  const [total, setTotal] = useState(0);
  const [placeTotal, setPlaceTotal] = useState(0);
  const [loaded, setLoaded] = useState(false);
  const [missing, setMissing] = useState(false);
  const [elsewhere, setElsewhere] = useState(0);
  const [selected, setSelected] = useState<Set<string>>(new Set(saved.selected ?? []));
  const [focus, setFocus] = useState<string | null>(saved.selected?.[0] ?? null);
  const [detail, setDetail] = useState<Detail>(null);
  const [extra, setExtra] = useState<ItemRow | null>(null);
  const [palette, setPalette] = useState(false);
  const [keysOpen, setKeysOpen] = useState(false);
  /** New Item's sheet: true, or what a paste or a drop brought (NewItemSheet.Prefill) */
  const [newItem, setNewItem] = useState<boolean | Prefill>(false);
  const [settingsFor, setSettingsFor] = useState<ProjectRow | null>(null);
  const [movePop, setMovePop] = useState<{ uids: string[]; anchor: DOMRect; here: string | null; subject: string } | null>(null);
  const [stateMenu, setStateMenu] = useState<string | null>(null);
  const [renaming, setRenaming] = useState<string | null>(null);
  const [renamingProject, setRenamingProject] = useState<string | null>(null);
  const [scanning, setScanning] = useState(false);
  const [bundling, setBundling] = useState(false);
  const [sideHidden, setSideHidden] = useState(!!saved.sidebar);
  const [detailHidden, setDetailHidden] = useState(!!saved.detail);
  const [sideW, setSideW] = useState(saved.sideW ?? 220);
  const [listW, setListW] = useState(saved.listW ?? 440);
  // the columns fit the window (MainWindowController: the list is the column that gives): below side + 330 + 380 the
  // list shrinks to 330, below 900 the sidebar folds away, as the Mac's split view collapses it; the toolbar's
  // sidebar button then shows it on top of the list until a place is picked
  const [winW, setWinW] = useState(() => window.innerWidth);
  const [sidePeek, setSidePeek] = useState(false);
  const [freshProject, setFreshProject] = useState<string | null>(null);
  useEffect(() => {
    const on = () => setWinW(window.innerWidth);
    window.addEventListener('resize', on);
    return () => window.removeEventListener('resize', on);
  }, []);
  const narrow = winW < 900;
  // Settings has its own two columns (the Mac's): the app's sidebar steps aside, Settings' Back returns
  const sideOff = (narrow ? !sidePeek : sideHidden) || screen.kind === 'settings';
  const toggleSide = () => (narrow ? setSidePeek((p) => !p) : setSideHidden((h) => !h));
  const [tick, setTick] = useState(0);
  const [editor, setEditor] = useState('vscode');
  // the user's own global keys (Settings → Shortcuts), for the toolbar's tips: none when a key is off
  const [hotkeys, setHotkeys] = useState<HotkeyRow[]>([]);
  const hotkeyOf = (action: string) => {
    const r = hotkeys.find((h) => h.action === action);
    return r && r.spec && r.result !== 'off' ? r.label : '';
  };
  const [welcome, setWelcome] = useState<{ onb: Onboarding; firstRun: boolean } | null>(null);
  const [toast, setToastState] = useState<Toast | null>(null);
  const [kindCounts, setKindCounts] = useState<Record<string, number>>({});
  const [scrollTo, setScrollTo] = useState<{ uid: string; n: number } | null>(null);
  /** rows drag out as Windows' own file drag (mainwin.rs), and the rows of the drag under way */
  const [nativeDrag, setNativeDrag] = useState(false);
  const dragging = useRef<string[] | null>(null);
  /** something from outside (files, text) or the island's cards dragged over the window: where, and what it is
      (drag-drop.md §4); the label next to the pointer moves with it without a render (`dropTip`) */
  const [drop, setDrop] = useState<{ zone: Zone; what: DragKind; where: 'list' | 'side' | 'detail' } | null>(null);
  const dropTip = useRef<HTMLDivElement>(null);
  const dropAt = useRef({ x: 0, y: 0 });
  /** the drag under way: the island cards it is (Rust's answer, asked once per drag: cards_dragging), whether it
      began in this window — all reset when it is over (DragState) */
  const dragState = useRef(new DragState());
  /** drops waiting for their files' paths (folder_drop.rs answers `mainwin://files-dropped` with the token) */
  const pathWaits = useRef(new Map<string, (files: { path: string; dir: boolean }[] | null) => void>());
  const toastTimer = useRef<ReturnType<typeof setTimeout>>(undefined);
  const undo = useRef<UndoStep[]>([]);
  const redo = useRef<UndoStep[]>([]);
  const pendingSelect = useRef<string | null>(null);
  const searchRef = useRef<HTMLInputElement>(null);
  const listRef = useRef<HTMLElement>(null);
  const menu = useMenu();
  const refresh = useMemo(() => debounce(() => setTick((n) => n + 1), 150), []);

  const showToast = useCallback((msg: string, opts: { undo?: () => void; action?: Toast['action']; gone?: () => void; mark?: Toast['mark'] } = {}) => {
    clearTimeout(toastTimer.current);
    const id = Date.now();
    setToastState({ msg, ...opts, id });
    toastTimer.current = setTimeout(() => setToastState((x) => (x?.id === id ? null : x)), opts.undo || opts.action ? 6000 : 4200);
  }, []);
  const fail = useCallback((e: unknown) => showToast(errText(e)), [showToast]);
  // a toast that leaves says so (the page's Undo is only good while its toast is up)
  const shownToast = useRef<Toast | null>(null);
  useEffect(() => {
    if (shownToast.current && shownToast.current !== toast) shownToast.current.gone?.();
    shownToast.current = toast;
  }, [toast]);
  const relang = useCallback((l: string) => {
    setLang(l);
    setLangTick((n) => n + 1);
  }, []);

  // what events and the review page call back into: the latest functions (they change every render)
  const live = useRef<{
    go: (p: Place) => void;
    reveal: (uid: string) => void;
    openJob: (job: string) => void;
    focusList: () => void;
    pageStep: (label: string) => void;
    windowUndo: (redo: boolean) => void;
    undone: (uid: string) => void;
    openFolders: (paths: string[]) => Promise<void>;
    addedFiles: (uid: string, r: AttachResult) => void;
  }>(null!);
  /** the review page on show (ReviewPane's handle): the window's undo calls its steps back, the list's writes poll it */
  const page = useRef<ReviewHandle | null>(null);
  const onPage = useCallback((h: ReviewHandle | null) => {
    if (h && h !== page.current) {
      // a new page: the steps of the one it replaced went with it (the Mac's dropPageSteps)
      undo.current = undo.current.filter((s) => s.kind !== 'page');
      redo.current = redo.current.filter((s) => s.kind !== 'page');
    }
    page.current = h;
  }, []);

  // ---------------------------------------------------------------- start, events
  useEffect(() => {
    api.status().then((s) => {
      relang(s.lang);
      setStatus(s);
      applyPlatform(s.platform);
      applyTheme('auto');
      const v = startPlace(s.start_view);
      if (v.place) setPlace(v.place);
      if (v.screen) setScreen(v.screen);
      if (v.session) setDetail({ kind: 'session', dir: v.session, project: null });
      // smoke runs that open on a view don't get the Welcome in front of it (BLURT_START_VIEW=welcome asks for it)
      if (!s.start_view || s.start_view === 'welcome')
        api.onboarding().then((o) => (o.needed || s.start_view === 'welcome') && setWelcome({ onb: o, firstRun: o.needed }), () => {});
    });
    api.settings().then((s) => {
      if (typeof s.config?.app?.editor === 'string') setEditor(s.config.app.editor);
      setHotkeys(s.hotkeys ?? []);
    }, () => {});
    api.dragOutAvailable().then(setNativeDrag, () => {});
    api.cardsWaiting().then(setCardsWaiting, () => {});
    const offs = [
      listen<{ count: number }>('cards://changed', (p) => setCardsWaiting(p.count)),
      listen<HotkeyRow[]>('hotkeys://changed', (rows) => setHotkeys(rows)),
      listen<{ paths: string[] }>('mainwin://folders-dropped', (p) => void live.current.openFolders(p.paths)),
      listen<{ token: string; files: { path: string; dir: boolean }[] }>('mainwin://files-dropped', (p) => {
        const w = pathWaits.current.get(p.token);
        pathWaits.current.delete(p.token);
        w?.(p.files);
      }),
      listen('index://changed', refresh),
      listen('projects://changed', refresh),
      listen('mainwin://dragout', () => setTimeout(() => (dragging.current = null), 300)),
      listen<Job[]>('jobs://changed', () => refresh()),
      listen<{ scanning: boolean }>('index://status', (p) => setScanning(p.scanning)),
      listen<{ ev: string; code?: string }>('capture://status', (p) => {
        if (p.ev === 'error' && p.code) showToast(t(`error.${p.code}`) === `error.${p.code}` ? t('error.unknown') : t(`error.${p.code}`));
      }),
      listen<{ view?: string; item?: string; session?: string; job?: string | null; project?: string }>('nav', (p) => {
        if (p.view !== 'welcome') setWelcome(null); // the tray, a toast or a link asked for a place: the setup assistant would hide it (#93)
        if (p.view === 'inbox' || p.view === 'dictation' || p.view === 'home' || p.view === 'cards' || p.view === 'screen_text' || p.view === 'phone') live.current.go(p.view);
        else if (p.view === 'settings') setScreen({ kind: 'settings' }); // the tray's Settings… (the pane: SettingsView)
        else if (p.view === 'welcome') api.onboarding().then((o) => setWelcome({ onb: o, firstRun: o.needed }), () => {}); // blurt://onboarding
        else if (p.job) live.current.openJob(p.job);
        else if (p.project) live.current.go(p.project === 'inbox' ? 'unassigned' : `project:${p.project}`);
        else if (p.session) {
          setScreen({ kind: 'main' });
          setDetail({ kind: 'session', dir: p.session, project: null });
        } else if (p.item) live.current.reveal(p.item);
      }),
    ];
    // Settings → Dictation's Manage… (DictationView's openWordsTab picks the tab)
    const toDictation = () => {
      setScreen({ kind: 'main' });
      live.current.go('dictation');
    };
    window.addEventListener('blurt:open-dictation', toDictation);
    return () => {
      offs.forEach((o) => o());
      window.removeEventListener('blurt:open-dictation', toDictation);
    };
  }, []);

  useEffect(() => {
    api.projects().then(setProjects, () => {});
    api.summary().then(setSummary, () => {});
    api.jobs(false).then(setJobs, () => {});
  }, [tick]);

  // the window state (the Mac's main-window.json), a moment after it changes
  useEffect(() => {
    const h = setTimeout(() => {
      try {
        const s: Saved = { place, sort, ascending, filters, selected: [...selected].slice(0, 200), sidebar: sideHidden, detail: detailHidden, sideW, listW, homeSeen: true };
        localStorage.setItem(STORE, JSON.stringify(s));
      } catch {
        /* a private window: nothing kept */
      }
    }, 600);
    return () => clearTimeout(h);
  }, [place, sort, ascending, filters, selected, sideHidden, detailHidden, sideW, listW]);

  // ---------------------------------------------------------------- projects
  const registered = useMemo(() => orderedProjects(projects?.projects ?? []), [projects]);
  const current = projects?.current && projects.current !== 'auto' && projects.current !== 'inbox' ? projects.current : null;
  const projectRow = useCallback((id: string): ProjectRow | null => (id === 'inbox' ? projects?.inbox ?? null : projects?.projects.find((p) => p.id === id) ?? null), [projects]);
  const projectName = useCallback((id: string) => (id === 'inbox' ? t('project.inbox') : projectRow(id)?.name ?? t('main.project.removed_name')), [projectRow]);
  const shownProject = isProject(place) ? projectRow(place.slice(8)) : null;

  // ---------------------------------------------------------------- the list
  const filter = filters[place] ?? NO_FILTER;
  const searching = !!text.trim();
  const query = useMemo(() => placeQuery(place, filter, text, sort, ascending, LIMIT), [place, filter, text, sort, ascending]);
  const kindsOn = filter.kinds.length > 0 || (showsState(place) && !!filter.state);
  const filtered = kindsOn || searching;
  useEffect(() => {
    if (isPage(place)) return;
    let alive = true;
    api.items(query).then(
      (r) => {
        if (!alive) return;
        setRaw(r.items);
        setTotal(r.total);
        setMissing(r.missing);
        setLoaded(true);
      },
      (e) => alive && fail(e),
    );
    // "12 of 52": the place's own count while a search or a filter narrows it
    if (filtered) api.items(placeQuery(place, NO_FILTER, '', sort, ascending, 1)).then((r) => alive && setPlaceTotal(r.total), () => {});
    if (searching && place !== 'all') api.items({ query: text.trim(), limit: 1 }).then((r) => alive && setElsewhere(r.total), () => {});
    else setElsewhere(0);
    return () => {
      alive = false;
    };
  }, [query, tick, isPage(place)]);

  const how = groupingOf(place, searching);
  const grouped = useMemo(() => {
    const rows = place === 'unassigned' && !searching ? bySuggestion(raw, registered) : raw;
    return group(rows, how, registered.map((p) => p.id));
  }, [raw, how, registered, place, searching]);
  const rows = grouped.rows;
  const order = useMemo(() => rows.map((r) => r.uid), [rows]);
  const selectedRows = useMemo(() => rows.filter((r) => selected.has(r.uid)), [rows, selected]);
  // the recordings: Home lists them all; an items' place, at the top, those with no items to be found by
  // (recordings.ts) — while searching or filtering, only items
  const recInfos = useRecordingInfos(recordingOn, tick);
  const recs = useMemo(() => recordings(recInfos, jobs), [recInfos, jobs]);
  const agentReady = useAgentReady(recordingOn);
  const placeRecs = useMemo(() => (filtered || isPage(place) ? [] : placeRecordings(recs, place)), [recs, place, filtered]);
  const placeEmpty = loaded && !missing && emptyStateShown(rows.length, placeRecs.length) && !filtered;
  const emptyWorld = !!summary && !summary.missing && summary.items === 0 && (summary.discarded ?? 0) === 0;
  const quietDetail = emptyWorld || missing || rows.length === 0;
  const fold = !isPage(place) && !detail && (placeEmpty || missing);

  // the selection follows the rows: kept by uid; one that left the list hands its place to the next row (Mail)
  const lastIndex = useRef(0);
  useEffect(() => {
    if (!loaded) return;
    if (pendingSelect.current && order.includes(pendingSelect.current)) {
      const u = pendingSelect.current;
      pendingSelect.current = null;
      setSelected(new Set([u]));
      setFocus(u);
      setScrollTo({ uid: u, n: Date.now() });
      return;
    }
    const keep = [...selected].filter((u) => order.includes(u));
    if (keep.length === selected.size) {
      if (!selected.size && order.length && !detail) {
        setSelected(new Set([order[0]]));
        setFocus(order[0]);
      }
      return;
    }
    if (keep.length) {
      setSelected(new Set(keep));
      if (!focus || !keep.includes(focus)) setFocus(keep[0]);
    } else if (order.length) {
      const u = order[Math.min(lastIndex.current, order.length - 1)];
      setSelected(new Set([u]));
      setFocus(u);
    } else {
      setSelected(new Set());
      setFocus(null);
    }
  }, [order, loaded]);
  useEffect(() => {
    const i = focus ? order.indexOf(focus) : -1;
    if (i >= 0) lastIndex.current = i;
  }, [focus, order]);

  // one selected item the list doesn't hold (a deep link while it loads)
  useEffect(() => {
    const u = selected.size === 1 ? [...selected][0] : null;
    if (u && !rows.some((r) => r.uid === u)) api.item(u).then(setExtra, () => setExtra(null));
    else setExtra(null);
  }, [selected, rows]);
  const current1 = selectedRows.length === 1 ? selectedRows[0] : selected.size === 1 && extra && selected.has(extra.uid) ? extra : null;

  // ---------------------------------------------------------------- navigation
  /** focusList false: a click on a sidebar row keeps the focus there (F2 renames that project, a double-click's field
      stays open), as a click in Explorer's navigation pane does; the keyboard's places (Ctrl+1…) go to the list. */
  const go = (p: Place, opts?: { focusList?: boolean }) => {
    setScreen({ kind: 'main' });
    setDetail(null);
    setRenaming(null);
    setStateMenu(null);
    setSidePeek(false);
    if (p !== place) {
      setSelected(new Set());
      setFocus(null);
      setLoaded(false);
      lastIndex.current = 0;
      setPlace(p);
    }
    if (!isPage(p) && opts?.focusList !== false)
      requestAnimationFrame(() => !document.activeElement?.closest('.mw-rename') && listRef.current?.focus({ preventScroll: true }));
  };

  // the place on show belongs to a capability just turned off (here, in Settings, by hand in config.json): Home
  useEffect(() => {
    if (offKnown && !placeShown(place, off)) go('home', { focusList: false });
  }, [off, offKnown, place]);

  /** An item from a link, a notification, a job or the palette: the place on show if it lists it, else its project —
      with the search and the kinds cleared, Discarded where it is discarded. */
  const reveal = async (uid: string) => {
    const it = await api.item(uid).catch(() => null);
    if (!it) return showToast(t('app.url.no_item'));
    setScreen({ kind: 'main' });
    setDetail(null);
    setText('');
    const lists = (p: Place) =>
      p === 'inbox' ? it.state === 'new' || it.state === 'to_verify'
        : p === 'progress' ? ACTIVE.includes(it.state)
          : p === 'unassigned' ? it.project_id === 'inbox'
            : p === 'all' ? true
              : isProject(p) ? it.project_id === p.slice(8) : false;
    const target: Place = it.state !== 'discarded' && lists(place) ? place : it.project_id === 'inbox' ? 'unassigned' : `project:${it.project_id}`;
    setFilters((f) => ({ ...f, [target]: { kinds: [], state: it.state === 'discarded' ? 'discarded' : null } }));
    pendingSelect.current = uid;
    if (target !== place) {
      setLoaded(false);
      setPlace(target);
    } else refresh();
    requestAnimationFrame(() => listRef.current?.focus({ preventScroll: true }));
  };

  const focusList = () => listRef.current?.focus({ preventScroll: true });
  const focusSearch = () => {
    const f = searchRef.current;
    if (!f || f.disabled) return;
    f.focus();
    f.select();
  };

  // ---------------------------------------------------------------- writes, each on the undo stack
  const pushUndo = (s: UndoStep) => {
    undo.current.push(s);
    if (undo.current.length > 100) undo.current.shift();
    redo.current = [];
  };
  /** A toast's Undo: the window's Ctrl+Z, as long as the step it names is still the one Ctrl+Z would take back. */
  const undoToast = (name: string) => () => {
    if (undo.current[undo.current.length - 1]?.name === name) doUndo();
  };

  /** A state action on the items it is valid for (the others are left alone). Hand off copies the hand-off note. */
  const apply = async (action: Action, items: ItemRow[], redoing = false): Promise<void> => {
    const ok = validFor(action, items);
    if (!ok.length) return;
    if (action === 'hand_off') {
      void handOff(ok.map((i) => i.uid));
      return;
    }
    // shown at once (the row takes its new state); the index agrees a moment later, or puts the truth back
    const name = menuCase(t(`action.${action}`));
    const step: UndoStep = { kind: 'state', name, action, before: ok.map((i) => [i.uid, i.state]) };
    setRaw((rs) => rs.map((r) => (ok.some((o) => o.uid === r.uid) ? { ...r, state: targetOf(action, r) ?? r.state } : r)));
    try {
      await api.state(ok.map((i) => i.uid), action);
      pushUndo(step);
      refresh();
      if (redoing) return;
      const to = action === 'restore' ? 'new' : targetOf(action, ok[0]) ?? 'new';
      const what = ok.length === 1 ? ok[0].item_id : plural('main.items.count', ok.length);
      showToast(t('main.state.toast', { a: t(`state.${to}`), b: what }), { undo: undoToast(name) });
    } catch (e) {
      refresh();
      fail(e);
    }
  };

  /** A list key (A D R W X Delete) on the selection: each item gets what the key means from its own state. */
  const act = (key: string) => {
    const sel = selectedRows;
    const by = new Map<Action, ItemRow[]>();
    for (const it of sel) {
      const a = actionForListKey(key, it.state);
      if (a) by.set(a, [...(by.get(a) ?? []), it]);
    }
    if (!by.size) {
      if (!sel.length) return;
      // a key that doesn't apply says why, with the way out where there is one (Restore)
      if (sel.every((i) => i.state === 'discarded')) return showToast(t('main.state.restore_first'), { mark: 'warn', action: { label: menuCase(t('action.restore')), run: () => apply('restore', sel) } });
      const states = [...new Set(sel.map((i) => i.state))];
      return showToast(t('main.state.not_here', { a: states.length === 1 ? t(`state.${states[0]}`) : t('main.state.these') }), { mark: 'warn' });
    }
    for (const [a, its] of by) apply(a, its);
  };

  const known = () => [...raw, ...(extra ? [extra] : [])];
  const itemsOf = (uids: string[]) => known().filter((r) => uids.includes(r.uid));

  const moveItems = async (uids: string[], to: string, redoing = false) => {
    const its = itemsOf(uids).filter((r) => r.project_id !== to);
    if (!its.length) return;
    const name = t('main.move.undo_name', { a: projectName(to) });
    try {
      const r = (await api.move(its.map((i) => i.uid), to)) as { moved?: unknown[] } | null;
      pushUndo({ kind: 'move', name, to, before: its.map((i) => [i.uid, i.project_id]) });
      refresh();
      if (!redoing) showToast((r?.moved?.length ?? its.length) === 1 && its[0]?.item_id ? t('main.move.done_single', { a: projectName(to), b: its[0].item_id }) : plural('main.move.done', r?.moved?.length ?? its.length, { a: projectName(to) }), { undo: undoToast(name), mark: 'ok' });
    } catch (e) {
      showToast(`${t('main.move.failed')} — ${errText(e)}`);
    }
  };

  const editItems = async (items: ItemRow[], set: Record<string, unknown>) => {
    for (const it of items) {
      const before: Record<string, unknown> = {};
      for (const k of Object.keys(set)) before[k] = (it as unknown as Record<string, unknown>)[k];
      try {
        await invoke('items_ops', { scope: { project: it.project_id }, ops: [{ op: 'set', id: it.uid, set, unset: [] }], confirm: false });
        pushUndo({ kind: 'edit', name: 'title' in set ? t('main.menu.rename') : t('main.undo.kind'), project: it.project_id, uid: it.uid, before, after: set });
      } catch (e) {
        fail(e);
      }
    }
    setRaw((rs) => rs.map((r) => (items.some((i) => i.uid === r.uid) ? { ...r, ...set } : r)));
    refresh();
  };
  const setKind = (k: string) => {
    const its = selectedRows.filter((i) => i.kind !== k);
    if (its.length) editItems(its, { kind: k });
  };

  async function doUndo() {
    const s = undo.current.pop();
    if (!s) return;
    try {
      if (s.kind === 'state') {
        const by = new Map<State, string[]>();
        for (const [u, st] of s.before) by.set(st, [...(by.get(st) ?? []), u]);
        for (const [st, uids] of by) await api.undoState(uids, st);
      } else if (s.kind === 'move') {
        const by = new Map<string, string[]>();
        for (const [u, p] of s.before) by.set(p, [...(by.get(p) ?? []), u]);
        for (const [p, uids] of by) await api.move(uids, p);
      } else if (s.kind === 'edit') {
        await invoke('items_ops', { scope: { project: s.project }, ops: [{ op: 'set', id: s.uid, set: s.before, unset: [] }], confirm: false });
      } else if (s.kind === 'remove_project') {
        await api.restoreProject(s.removed);
        go(`project:${s.id}`);
      } else if (s.kind === 'page') {
        // a step of the page on show (a page since replaced took its steps with it)
        page.current?.undo();
      } else if (s.kind === 'attach') {
        await api.attachItem(s.uid, [], [], null, s.before ?? {});
        if (s.cards?.length) await api.cardsPutBack(s.cards);
        page.current?.pollNow();
        // the cards hang again: taking them anew is a new drag, not a Redo
        if (s.cards?.length) return refresh();
      }
      redo.current.push(s);
      refresh();
    } catch (e) {
      fail(e);
    }
  }
  async function doRedo() {
    const s = redo.current.pop();
    if (!s) return;
    const keep = [...redo.current];
    try {
      if (s.kind === 'state') {
        await api.state(s.before.map(([u]) => u), s.action);
        undo.current.push(s);
      } else if (s.kind === 'move') {
        await api.move(s.before.map(([u]) => u), s.to);
        undo.current.push(s);
      } else if (s.kind === 'edit') {
        await invoke('items_ops', { scope: { project: s.project }, ops: [{ op: 'set', id: s.uid, set: s.after, unset: [] }], confirm: false });
        undo.current.push(s);
      } else if (s.kind === 'remove_project') {
        await removeProject(s.id, true);
      } else if (s.kind === 'page') {
        page.current?.redo();
        undo.current.push(s);
      } else if (s.kind === 'attach') {
        await api.attachItem(s.uid, [], [], null, s.after ?? {});
        page.current?.pollNow();
        undo.current.push(s);
      }
      redo.current = keep;
      refresh();
    } catch (e) {
      fail(e);
    }
  }

  // ---------------------------------------------------------------- hand-off
  const blockText = (b: HandOffBlock): string => {
    switch (b.why) {
      case 'discarded': return t('main.handoff.discarded');
      case 'finished': return t('main.handoff.reopen_first', { a: t(`state.${b.state}`) });
    }
  };
  /** Hand off to the user's own agent (K6): the hand-off note is written, the items are marked handed off, and the
      instruction (or, `full`, the whole text) is on the clipboard to paste into Claude Code, Codex or any agent.
      Items that can't go say why at once, with the way out. */
  async function handOff(uids: string[], full = false): Promise<void> {
    const all = itemsOf(uids);
    if (!all.length) return;
    const b = handOffBlock(all);
    if (b) {
      const way: Toast['action'] =
        b.why === 'discarded' ? { label: menuCase(t('action.restore')), run: () => apply('restore', all) }
          : { label: menuCase(t('action.reopen')), run: () => apply('reopen', all) };
      return showToast(blockText(b), { action: way, mark: 'warn' });
    }
    const its = all.filter((i) => i.state !== 'discarded');
    try {
      const r = await api.handoff(its.map((i) => i.uid), full);
      if (r?.text) await api.copyText(r.text).catch(() => {});
      showToast(t(full ? 'main.handoff.copied_full' : 'main.handoff.copied'), { mark: 'ok' });
      refresh();
    } catch (e) {
      showToast(`${t('main.handoff.failed')} — ${errText(e)}`);
    }
  }
  const copyLines = (lines: string[], what: string) => api.copyText(lines.join('\n')).then(() => showToast(what), fail);
  const pathOf = (r: ItemRow) => r.primary_frame || r.path;
  const revealItems = (its: ItemRow[]) => its[0] && api.reveal(pathOf(its[0])).catch(fail);
  const openPicture = (its: ItemRow[]) => {
    const f = its.find((i) => i.primary_frame)?.primary_frame;
    if (f) api.openPath(f).catch(fail);
    else if (its.length) showToast(t('main.space.no_picture')); // the Mac beeps; a page can't
  };
  const exportBundle = async (its: ItemRow[]) => {
    if (!its.length || bundling) return;
    const one = new Set(its.map((i) => i.project_id)).size === 1;
    const zh = i18n().lang === 'zh-Hans';
    setBundling(true);
    try {
      const r = await api.exportBundle(its.map((i) => i.uid), bundleName(one ? its[0].project_name : null, its.length, zh), zh ? 'zh' : 'en');
      if (r) {
        const path = r.path ?? '';
        showToast(t('main.bundle.saved', { a: path.split(/[\\/]/).pop() ?? path }), { action: { label: revealLabel(), run: () => api.reveal(path).catch(fail) } });
      }
    } catch (e) {
      const code = String(e).match(/\[([a-z_]+)\]\s*$/)?.[1];
      showToast(`${t('main.bundle.failed')} — ${code && i18n().has(`main.bundle.error.${code}`) ? t(`main.bundle.error.${code}`) : errText(e)}`);
    } finally {
      setBundling(false);
    }
  };

  /** Fill In Details with AI: one background run for all of them (items.rs enrich); its progress is a job above the list. */
  const enrich = async (its: ItemRow[]) => {
    const live = its.filter((i) => i.state !== 'discarded');
    if (!live.length) return;
    const projects = new Set(live.map((i) => i.project_id));
    try {
      await api.enrich(live.map((i) => i.uid), projects.size === 1 ? [...projects][0] : null);
      refresh();
    } catch (e) {
      fail(e);
    }
  };

  /** Ctrl+V (drag-drop.md §0.6): in the list, the sidebar or nowhere in particular → New Item, filled with the
      clipboard's files, pictures or text, in the place on show (Enter creates); on the detail with files or a picture
      on the clipboard → added to the item on show (undoable); text there is the page's own paste. Rust reads the
      clipboard (clipboard_things: paths, a document's copy told from a picture, Blurt's own copies never pasted back
      as files); without it (a browser, an error) the page's own clipboard data is used. `sync`: what the paste event
      carried — gone once it is over. */
  const pasteInto = async (to: PasteTo, item: Extract<Zone, { kind: 'item' }> | null, sync: { files: File[]; text: string; field: HTMLElement | null }) => {
    const got = await api.clipboardThings().catch(() => null);
    let images = got?.images ?? [];
    const files = got?.files ?? [];
    let text = got?.text ?? '';
    if (!got || (!got.ours && !images.length && !files.length && !text)) {
      const pics = sync.files.filter((f) => f.type.startsWith('image/'));
      images = (await Promise.all(pics.map((f) => api.saveTempImage(f).catch(() => null)))).filter((p): p is string => !!p);
      text = images.length ? '' : sync.text;
    }
    dragLog({ event: 'main_paste', to, images: images.length, files: files.length, has_text: !!text.trim(), rich: !!got?.rich, ours: !!got?.ours });
    if (to === 'item' && item) {
      if (images.length || files.length) return void addTo(item, images, files, null);
      // only text (a document's copy whose picture was left out): into the field the paste was for
      const f = sync.field as HTMLInputElement | HTMLTextAreaElement | null;
      if (text && f?.isConnected) {
        f.focus();
        document.execCommand('insertText', false, text);
      }
      return;
    }
    if (!images.length && !files.length && !text.trim()) return;
    const words = !images.length && !files.length ? prefillFromText(text) : null;
    setNewItem({ title: words?.title ?? (images.length ? '' : titleFromFiles(files)), details: words?.details ?? '', images, files, target: listTarget });
  };

  // ---------------------------------------------------------------- drops (docs/design/drag-drop.md §4)
  /** where New Item puts what it makes, and where the list's own drops go: the project on show; Unassigned for the
      Inbox and Unassigned; else the current project */
  const listTarget = isProject(place) ? place.slice(8) : place === 'inbox' || place === 'unassigned' ? 'inbox' : current ?? 'inbox';
  const endDrag = () => {
    setDrop(null);
    lastOver.current = '';
    dragState.current.end();
  };
  useEffect(() => {
    // the drag left the window or ended anywhere: nothing is over us any more
    const leave = (e: DragEvent) => !e.relatedTarget && endDrag();
    const started = (e: DragEvent) => dragState.current.started(e.defaultPrevented);
    const ended = () => {
      dragState.current.innerEnded();
      endDrag();
    };
    // a new press: whatever drag began here is long over (a dragend WebView2 never sent)
    const pressed = () => dragState.current.innerEnded();
    // Files, a link or a picture let go where nothing here takes it would make the window navigate to it (WebView2,
    // WebKitGTK): refused instead — "no drop" under the pointer, nothing happens. Text into a field stays the field's.
    const guard = (e: DragEvent) => {
      if (e.defaultPrevented || !e.dataTransfer) return;
      const types = [...e.dataTransfer.types];
      if (!types.includes('Files') && !types.includes('text/uri-list')) return;
      if (!types.includes('Files') && inField(e.target)) return;
      e.preventDefault();
      if (e.type === 'dragover') e.dataTransfer.dropEffect = 'none';
    };
    window.addEventListener('dragleave', leave);
    window.addEventListener('drop', endDrag);
    window.addEventListener('dragend', ended);
    window.addEventListener('dragstart', started);
    window.addEventListener('pointerdown', pressed, true);
    window.addEventListener('dragover', guard);
    window.addEventListener('drop', guard);
    return () => {
      window.removeEventListener('dragleave', leave);
      window.removeEventListener('drop', endDrag);
      window.removeEventListener('dragend', ended);
      window.removeEventListener('dragstart', started);
      window.removeEventListener('pointerdown', pressed, true);
      window.removeEventListener('dragover', guard);
      window.removeEventListener('drop', guard);
    };
  }, []);
  /** What is being dragged over us; a drag of files may be the island's cards (Windows' own drag of them carries
      files): Rust is asked once, and says so for the dragovers after. */
  const dragWhat = (e: React.DragEvent): DragKind => {
    const types = e.dataTransfer.types;
    const d = dragState.current;
    if (types.includes('Files') && !types.includes(CARDS_MIME) && !dragging.current && !d.inner) {
      const token = d.ask();
      if (token !== null) api.cardsDragging().then((c) => d.answer(token, c), () => {});
    }
    return dragKind(types, { rows: !!dragging.current, cards: !!d.cards?.length, inner: d.inner });
  };
  /** the zone last said in the drag log (one line a zone, not one a dragover) */
  const lastOver = useRef('');
  const zoneKey = (z: Zone) => (z.kind === 'item' ? `i:${z.uid}` : z.kind === 'project' ? `p:${z.project}` : z.kind === 'new' ? `n:${z.project}` : 'none');
  /** The zone under the pointer, and the label next to it. */
  const dragOverZone = (e: React.DragEvent, zone: Zone, what: DragKind, where: 'list' | 'side' | 'detail') => {
    dropAt.current = { x: e.clientX, y: e.clientY };
    if (dropTip.current) dropTip.current.style.transform = `translate(${e.clientX + 14}px, ${e.clientY + 18}px)`;
    const k = `${where}:${zoneKey(zone)}:${what}`;
    if (k !== lastOver.current) {
      lastOver.current = k;
      dragLog({ event: where === 'detail' ? 'detail_drop_over' : 'main_drop_over', zone: zone.kind, where, what, types: [...e.dataTransfer.types].slice(0, 6) });
    }
    setDrop((d) => (d && d.what === what && d.where === where && zoneKey(d.zone) === zoneKey(zone) ? d : { zone, what, where }));
  };
  const dragLog = (ev: Record<string, unknown>) => void api.dragLog(ev).catch(() => {});
  /** The detail's zone: the item on show (a drop or a paste adds to it); none while it shows a batch, a job, several
      items or nothing. */
  const detailZone = (): Extract<Zone, { kind: 'item' }> | null =>
    current1 && !detail && screen.kind === 'main' && !isPage(place)
      ? { kind: 'item', uid: current1.uid, title: current1.title || current1.item_id || t('main.item.untitled') }
      : null;
  /** The list's zones: an item's row adds to it; anything else in the list (the band, the empty area, an empty
      list) is a new item in the place on show. */
  const listZone = (el: HTMLElement): Zone => {
    const uid = el.closest<HTMLElement>('.mw-row[data-uid]')?.dataset.uid;
    const r = uid ? rows.find((x) => x.uid === uid) : null;
    if (r) return { kind: 'item', uid: r.uid, title: r.title || r.item_id || t('main.item.untitled') };
    return { kind: 'new', project: listTarget };
  };
  /** Each dropped file's path: WebView2 knows it (folder_drop.rs, Windows); null elsewhere or when it doesn't answer. */
  const hostPaths = (files: FileList): Promise<{ path: string; dir: boolean }[] | null> | null => {
    const wv = webview();
    if (!wv?.postMessageWithAdditionalObjects || !files.length) return null;
    const token = `${Date.now()}-${Math.random().toString(36).slice(2)}`;
    const got = new Promise<{ path: string; dir: boolean }[] | null>((res) => {
      pathWaits.current.set(token, res);
      setTimeout(() => pathWaits.current.delete(token) && res(null), 4000);
    });
    wv.postMessageWithAdditionalObjects(`blurt-drop-files:${token}`, files);
    return got;
  };
  /** A drop on `zone`. The DataTransfer is only readable during the event: everything is taken from it now. */
  const dropOn = (e: React.DragEvent, zone: Zone, what: DragKind) => {
    const dt = e.dataTransfer;
    // the cards: as the drag names them (card_drop.rs CARDS_MIME), else as Rust said when the drag came in
    const named = what === 'cards' ? parseCards(dt.getData(CARDS_MIME)) : [];
    const cards = named.length ? named : (dragState.current.cards ?? []);
    endDrag();
    dragLog({ event: zone.kind === 'item' && drop?.where === 'detail' ? 'detail_drop' : 'main_drop', zone: zone.kind, what, files: dt.files.length, cards: cards.length });
    if (what === 'cards') return void dropCards(cards, zone);
    const files = [...dt.files];
    void dropThings({ files, plain: dt.getData('text/plain'), uris: dt.getData('text/uri-list'), paths: hostPaths(dt.files) }, zone);
  };
  /** "Added to “title” · 2 pictures · 1 file · text" */
  const addedText = (title: string, pics: number, files: number, text: boolean) =>
    [t('main.drop.added', { a: title }), pics ? plural('main.drop.n_pictures', pics) : '', files ? plural('main.drop.n_files', files) : '', text ? t('main.drop.text') : '']
      .filter(Boolean)
      .join(' · ');
  /** Files, pictures, text from another app: added to an item (Undo restores what it had), or New Item holding them. */
  const dropThings = async (d: { files: File[]; plain: string; uris: string; paths: Promise<{ path: string; dir: boolean }[] | null> | null }, zone: Zone) => {
    let entries: DropEntry[] = d.files.map((f) => ({ name: f.name, type: f.type, path: '' }));
    const got = d.paths ? await d.paths : null;
    if (got) entries = entries.map((x, i) => ({ ...x, path: got[i]?.path ?? '', dir: !!got[i]?.dir }));
    else if (d.files.length && d.uris) {
      // Linux: a file manager's drag names its files in text/uri-list; Rust says which are folders (and lets the
      // thumbnails load)
      const known = await api.dropPaths(pathsByName(d.files.map((f) => f.name), d.uris)).catch(() => null);
      if (known) entries = entries.map((x, i) => ({ ...x, path: known[i]?.path ?? '', dir: !!known[i]?.dir }));
    }
    const s = sortEntries(entries);
    const read = await Promise.all(s.bytes.map((i) => api.saveTempImage(d.files[i]).catch(() => null)));
    const images = [...s.images, ...read.filter((p): p is string => !!p)];
    const text = d.files.length ? '' : droppedText(d.plain, d.uris);
    if (s.folders.length) {
      // folders open as projects — on the sidebar; anywhere else, where to take them
      if (zone.kind === 'project') void openFolders(s.folders);
      else showToast(t('main.drop.folders'));
    }
    if (!images.length && !s.files.length && !text) {
      if (s.skipped.length) showToast(plural('main.drop.skipped', s.skipped.length));
      return;
    }
    if (zone.kind === 'item') return void addTo(zone, images, s.files, text || null, s.skipped.length);
    const target = zone.kind === 'project' || zone.kind === 'new' ? zone.project : listTarget;
    const words = text ? prefillFromText(text) : null;
    setNewItem({ title: words?.title ?? (images.length ? '' : titleFromFiles(s.files)), details: words?.details ?? '', images, files: s.files, target });
    if (s.skipped.length) showToast(plural('main.drop.skipped', s.skipped.length));
  };
  /** Pictures, files, text added to an item (a drop on its row or the detail, a paste, Add Image or File…): the
      detail shows them at once, the toast says what with its Undo, and Ctrl+Z takes it back (attach --restore). */
  const addTo = async (zone: Extract<Zone, { kind: 'item' }>, images: string[], files: string[], text: string | null, skipped = 0) => {
    try {
      added(zone, await api.attachItem(zone.uid, images, files, text), undefined, skipped);
    } catch (e) {
      fail(e);
    }
  };
  /** An attach done (`r`: items.py's {before, added}): the step on the window's undo stack, the toast, the page polled. */
  const added = (zone: Extract<Zone, { kind: 'item' }>, r: AttachResult | null, cards?: CardRef[], skipped = 0) => {
    const a = r?.added ?? {};
    const name = t('main.drop.undo_name');
    pushUndo({ kind: 'attach', name, uid: zone.uid, before: r?.before ?? {}, after: attachedAfter(r?.before, a), ...(cards?.length ? { cards } : {}) });
    refresh();
    page.current?.pollNow();
    const pics = a.frames?.length ?? 0;
    const files = a.attachments?.length ?? 0;
    dragLog({ event: 'item_drop_add', images: pics, files, has_text: !!a.details, cards: cards?.length ?? 0 });
    const msg = [addedText(zone.title, pics, files, !!a.details), skipped ? plural('main.drop.skipped', skipped) : ''].filter(Boolean).join(' · ');
    showToast(msg, { mark: 'ok', undo: undoToast(name) });
  };
  /** The island's cards dropped here: on an item, added to it (their pictures as frames, their notes after the
      details; Undo restores the item and hangs the cards again); anywhere else, filed into that project. */
  const dropCards = async (cards: CardRef[], zone: Zone) => {
    if (!cards.length) return;
    if (zone.kind === 'item') {
      try {
        const r = await api.cardsAttach(cards, zone.uid);
        added(zone, r, cards);
      } catch (e) {
        fail(e);
      }
      return;
    }
    const project = zone.kind === 'project' || zone.kind === 'new' ? zone.project : listTarget;
    try {
      await api.cardsFile(cards, project);
      showToast(plural('main.drop.filed', cards.length, { a: projectName(project) }), { mark: 'ok' });
    } catch (e) {
      fail(e);
    }
  };
  /** A sidebar row (a project, Unassigned) under something dragged from outside or the island's cards: New Item
      there, or the cards filed there. `phase` "over": whether the row takes it (Sidebar lights it). */
  const sidebarDrop = (e: React.DragEvent, project: string, phase: 'over' | 'drop' | 'leave'): boolean => {
    if (phase === 'leave') {
      setDrop((d) => (d?.zone.kind === 'project' && d.zone.project === project ? null : d));
      return true;
    }
    const what = dragWhat(e);
    if (what === 'rows' || what === 'none') return false;
    const zone: Zone = { kind: 'project', project, name: projectName(project) };
    if (phase === 'over') {
      e.dataTransfer.dropEffect = 'copy';
      dragOverZone(e, zone, what, 'side');
    } else dropOn(e, zone, what);
    return true;
  };

  /** M: the Move popover under the selection (or the button that asked). */
  function pickProject(uids?: string[], anchorEl?: HTMLElement | null) {
    const its = uids ? itemsOf(uids) : selectedRows;
    if (!its.length) return;
    const here = new Set(its.map((i) => i.project_id));
    const el = anchorEl ?? document.querySelector<HTMLElement>(`[data-uid="${its[its.length - 1].uid}"] .mw-c-title`) ?? listRef.current;
    const r = el?.getBoundingClientRect() ?? new DOMRect(200, 200, 0, 0);
    setMovePop({
      uids: its.map((i) => i.uid),
      anchor: anchorEl ? r : new DOMRect(r.left, r.top, Math.min(24, r.width), r.height),
      here: here.size === 1 ? [...here][0] : null,
      subject: its.length === 1 && its[0].item_id ? t('main.move.placeholder.one', { a: its[0].item_id }) : plural('main.move.placeholder.many', its.length),
    });
  }

  // ---------------------------------------------------------------- projects' writes
  const useProject = (id: string | null) => api.useProject(id ?? 'none').then(refresh, (e) => showToast(`${t('main.project.use_failed')} — ${errText(e)}`));
  async function removeProject(id: string, redoing = false) {
    const p = projectRow(id);
    if (!p) return;
    try {
      const removed = await api.removeProject(id);
      const name = t('main.project.remove.undo_name');
      pushUndo({ kind: 'remove_project', name, id, removed: (removed as { removed?: unknown }).removed ?? removed });
      setFilters((f) => {
        const n = { ...f };
        delete n[`project:${id}`];
        return n;
      });
      if (place === `project:${id}`) go('inbox');
      refresh();
      if (!redoing) showToast(t('main.project.removed', { a: p.name }), { undo: undoToast(name) });
    } catch (e) {
      showToast(`${t('main.project.save_failed')} — ${errText(e)}`);
    }
  }
  const saveProject = (id: string, patch: Record<string, unknown>) => api.setProject(id, patch).then(refresh, (e) => showToast(`${t('main.project.save_failed')} — ${errText(e)}`));
  const openFolder = () => api.openFolder().catch(fail);
  /** Folders dropped on the sidebar (folder_drop.rs; the Mac's openFolders): each becomes a project, the last one
      opens, and a new one says so with the key its items get and Rename right there. */
  const openFolders = async (paths: string[]) => {
    const known = new Set(registered.map((p) => p.id));
    let last: ProjectRow | null = null;
    for (const path of paths) {
      try {
        last = (await api.addProject(path)).project;
      } catch (e) {
        showToast(`${t('main.open.failed', { a: path.split(/[\\/]/).pop() ?? path })} — ${errText(e)}`);
      }
    }
    if (!last) return;
    const p = last;
    refresh();
    go(`project:${p.id}`);
    if (!known.has(p.id)) {
      showToast(t('main.open.added', { a: p.name, b: p.key }), { mark: 'ok', action: { label: t('main.open.rename'), run: () => setRenamingProject(p.id) } });
      setFreshProject(p.id);
      setTimeout(() => setFreshProject((f) => (f === p.id ? null : f)), 1400);
    }
  };
  /** Locate… (the Mac's MissingFolder.ask): another project's folder, or one with no Blurt store, is refused, saying
      whose folder it is not — before, any pick was taken silently (a stray project, the missing one still missing). */
  const locate = (p: ProjectRow) =>
    api.locateProject(p.id, t('main.missing.locate.message', { a: p.name }), p.path).then((r) => {
      if (r.pick === 'other' || r.pick === 'empty') showToast(t('main.missing.not_this', { a: p.name }));
      else if (r.pick === 'same') refresh();
    }, fail);

  // ---------------------------------------------------------------- capture
  const record = () => api.captureStart().catch((e) => String(e) !== 'cancelled' && fail(e));
  const snap = () => api.captureControl('snap').catch(fail);

  // ---------------------------------------------------------------- menus (one builder each, as on the Mac)
  const mac = status?.platform === 'mac';
  const editorName = ({ vscode: 'VS Code', cursor: 'Cursor', zed: 'Zed' } as Record<string, string>)[editor] ?? 'VS Code';
  const stateTarget = (a: Action, items: ItemRow[]): State => (a === 'restore' ? 'new' : targetOf(a, validFor(a, items)[0] ?? items[0]) ?? 'todo');
  const stateEntry = (a: Action, items: ItemRow[]): MenuEntry => {
    const n = validFor(a, items).length;
    return {
      label: menuCase(t(`action.${a}`)) + (items.length > 1 && n < items.length ? ` (${i18n().formatNumber(n)})` : ''),
      icon: <StatusRing state={stateTarget(a, items)} size={13} />,
      keys: actionKey(a, mac),
      tip: a === 'done' && validFor(a, items).every((i) => i.state === 'to_verify') ? t('action.done.hint_verify') : t(`action.${a}.hint`),
      run: () => apply(a, items),
    };
  };
  const kindMenu = (items: ItemRow[]): MenuEntry[] =>
    KINDS.map((k, i) => ({ label: t(`kind.${k}`), icon: <KindIcon kind={k} size={14} />, keys: String(i + 1), checked: items.length > 0 && items.every((x) => x.kind === k), run: () => editItems(items.filter((x) => x.kind !== k), { kind: k }) }));
  const moveMenu = (items: ItemRow[]): MenuEntry[] => {
    const here = new Set(items.map((i) => i.project_id));
    return tidy([
      // the M popover's rows (system.md "one mark per concept"): each project its coloured folder, a missing one the
      // question-mark folder and not a target, where the items are now faded with "Here now" at the trailing edge
      // (no check column for one row), Unassigned its dashed ring, then Open Folder… in the same group
      ...registered.map((p): MenuEntry => {
        const isHere = here.size === 1 && here.has(p.id);
        return {
          label: p.name,
          icon: p.exists ? <ProjectGlyph id={p.id} size={14} /> : <MissingFolderGlyph size={14} />,
          keys: isHere ? t('main.move.current') : undefined,
          disabled: isHere || !p.exists || !items.some((i) => i.project_id !== p.id),
          tip: !p.exists ? t('main.sidebar.missing') : p.name,
          run: () => moveItems(items.map((i) => i.uid), p.id),
        };
      }),
      { kind: 'separator' },
      { label: t('project.inbox'), icon: <UnassignedGlyph size={14} />, keys: here.size === 1 && here.has('inbox') ? t('main.move.current') : undefined, disabled: !items.some((i) => i.project_id !== 'inbox'), run: () => moveItems(items.map((i) => i.uid), 'inbox') },
      { label: t('project.open_folder'), icon: <Icon name="folder-plus" size={14} />, run: openFolder },
    ]);
  };
  const copyMenu = (items: ItemRow[]): MenuEntry[] => [
    { label: t('main.cmd.copy_full'), disabled: !!handOffBlock(items), run: () => void handOff(items.map((i) => i.uid), true) },
    { label: t('main.menu.copy_link'), run: () => copyLines(items.map((i) => `blurt://item/${i.uid}`), t('mw.copied.link')) },
    { label: t('action.copy_path'), keys: 'Ctrl+Alt+C', run: () => copyLines(items.map(pathOf), t('mw.copied.path')) },
  ];
  /** Hand Off (the context menu's first group): the instruction for the user's own agent, copied. */
  const handOffEntries = (items: ItemRow[]): MenuEntry[] => {
    const b = handOffBlock(items);
    return [
      { label: items.length > 1 ? plural('main.menu.hand_off_n', items.length) : t('main.menu.hand_off'), icon: <StatusRing state="handed_off" size={13} />, keys: mac ? '⌘↩' : 'Ctrl+Enter', disabled: !!b, tip: b ? blockText(b) : t('main.palette.hint.copy_instruction'), run: () => void handOff(items.map((i) => i.uid)) },
    ];
  };
  /** The item actions between the state rows and Discard: change it, take it out of Blurt, look at its files. */
  const itemActions = (items: ItemRow[], inSelection = false): MenuEntry[] => {
    const one = items.length === 1;
    return tidy([
      !inSelection && { label: t('main.menu.move_to'), icon: <Icon name="move" size={14} />, submenu: moveMenu(items) },
      { label: t('main.menu.kind'), icon: <Icon name="tag" size={14} />, submenu: kindMenu(items) },
      one && { label: t('main.menu.rename'), icon: <Icon name="pencil" size={14} />, keys: 'E', run: () => setRenaming(items[0].uid) },
      { label: t('main.menu.enrich'), icon: <Icon name="text-plus" size={14} />, disabled: !items.some((i) => i.state !== 'discarded'), run: () => enrich(items) },
      { kind: 'separator' },
      { label: t('menu.copy'), icon: <Icon name="copy" size={14} />, submenu: copyMenu(items) },
      { label: t('main.menu.export_bundle'), icon: <Icon name="archive" size={14} />, disabled: bundling, run: () => exportBundle(items) },
      { kind: 'separator' },
      // a picture opens for one item; several selected, it would only open the first one's
      items.filter((i) => i.primary_frame).length <= 1 && { label: t('mw.open_picture'), icon: <Icon name="eye" size={14} />, keys: t('main.keys.space'), disabled: !items.some((i) => i.primary_frame), run: () => openPicture(items) },
      { label: revealLabel(), icon: <Icon name="reveal" size={14} />, keys: 'Ctrl+Shift+R', run: () => revealItems(items) },
      one && { label: t('main.menu.open_in', { a: editorName }), icon: <Icon name="code" size={14} />, run: () => api.openUrl(codeUrl('', items[0].path, editor)).catch(fail) },
      one && !!items[0].session_dir && { label: t('main.menu.review_batch'), icon: <Icon name="film" size={14} />, run: () => setDetail({ kind: 'session', dir: items[0].session_dir!, project: items[0].project_id }) },
    ]);
  };
  /** S / the row's ring (the Mac's StateMenu, system.md "State menu"): the current state first, ticked; then the verbs
      that move it on, each with the state it leads to and its key; then the set-aside ones — only Discard says more
      ("You can restore it"); every other hint is the row's tooltip */
  const stateMenuFor = (items: ItemRow[]): MenuEntry[] => {
    const states = actionsFor(items, true);
    const one = items.length === 1 ? items[0] : null;
    const aside: Action[] = ['wontfix', 'discard'];
    const entry = (a: Action): MenuItem => (a === 'hand_off' ? { ...(stateEntry(a, items) as MenuItem), label: t('main.menu.hand_off'), run: () => void handOff(items.map((i) => i.uid)) } : (stateEntry(a, items) as MenuItem));
    return tidy([
      one && { label: stateText(one), icon: <StatusRing state={one.state} size={14} />, checked: true, current: true },
      one && { kind: 'separator' },
      ...states.filter((a) => !aside.includes(a)).map(entry),
      { kind: 'separator' },
      ...states.filter((a) => aside.includes(a)).map((a): MenuItem => (a === 'discard' ? { ...entry(a), hint: t('action.discard.hint'), danger: true } : entry(a))),
    ]);
  };
  const openStateMenu = (r: ItemRow, el: HTMLElement) => {
    setStateMenu(r.uid);
    menu.open(stateMenuFor(selected.has(r.uid) ? selectedRows : [r]), { x: 0, y: 0, anchor: el }, t('state.menu'));
  };
  const contextMenu = (items: ItemRow[]): MenuEntry[] => {
    const states = actionsFor(items, false);
    return tidy([
      ...handOffEntries(items),
      { kind: 'separator' },
      ...states.filter((a) => a !== 'discard').map((a) => stateEntry(a, items)),
      { kind: 'separator' },
      ...itemActions(items),
      { kind: 'separator' },
      states.includes('discard') && stateEntry('discard', items),
    ]);
  };
  const projectMenu = (p: ProjectRow): MenuEntry[] => {
    const cur = current === p.id;
    return tidy([
      !p.exists && { label: t('main.missing.locate'), icon: <MissingFolderGlyph size={14} />, run: () => locate(p) },
      !p.exists && { kind: 'separator' },
      { label: cur ? t('main.project.use_none') : t('main.project.use'), icon: <ScopeGlyph size={13} />, tip: t('main.project.use.tip'), run: () => useProject(cur ? null : p.id) },
      { label: p.pinned ? t('main.project.unpin') : t('main.project.pin'), icon: <PinGlyph size={13} off={p.pinned} />, run: () => saveProject(p.id, { pinned: !p.pinned }) },
      { label: t('main.project.rename'), icon: <Icon name="pencil" size={14} />, keys: 'F2', run: () => setRenamingProject(p.id) },
      { label: t('main.project.settings'), icon: <Icon name="sliders" size={14} />, keys: 'Ctrl+I', run: () => setSettingsFor(p) },
      { kind: 'separator' },
      { label: revealLabel(), icon: <Icon name="reveal" size={14} />, run: () => api.reveal(p.path).catch(fail) },
      { label: t('main.menu.open_in', { a: editorName }), icon: <Icon name="code" size={14} />, run: () => api.openUrl(`${editor === 'zed' ? 'zed' : editor === 'cursor' ? 'cursor' : 'vscode'}://file/${p.path.replace(/\\/g, '/').replace(/^\/+/, '')}`).catch(fail) },
      { label: t('action.copy_path'), icon: <Icon name="copy" size={14} />, run: () => copyLines([p.path], t('mw.copied.path')) },
      { kind: 'separator' },
      { label: t('main.project.remove'), icon: <Icon name="minus-circle" size={14} />, run: () => removeProject(p.id) },
    ]);
  };
  const sortName = (k: SortKey) => (k === 'updated' ? t('main.sort.updated') : t(`main.col.${k}`));
  const sortMenu = (): MenuEntry[] => [
    { kind: 'header', label: t('menu.sort_by') },
    ...SORT_KEYS.map((k): MenuEntry => ({
      label: sortName(k),
      checked: sort === k,
      run: () => {
        setSort(k);
        setAscending(k === sort ? ascending : ascendsByDefault(k));
      },
    })),
    { kind: 'separator' },
    { label: t('main.sort.ascending'), checked: ascending, run: () => setAscending(true) },
    { label: t('main.sort.descending'), checked: !ascending, run: () => setAscending(false) },
  ];
  const setFilter = (f: PlaceFilter) => setFilters((all) => ({ ...all, [place]: f }));
  const filterMenu = (counts: Record<string, number>): MenuEntry[] => tidy([
    { kind: 'header', label: t('main.filter.kind_header') },
    { label: t('main.filter.all_kinds'), checked: !filter.kinds.length, run: () => setFilter({ ...filter, kinds: [] }) },
    ...KINDS.map((k): MenuEntry => ({
      label: menuCase(t(`main.filter.kind_plural.${k}`)), icon: <KindIcon kind={k} size={14} />, checked: filter.kinds.includes(k), badge: counts[k] !== undefined ? i18n().formatNumber(counts[k]) : undefined,
      run: () => setFilter({ ...filter, kinds: filter.kinds.includes(k) ? filter.kinds.filter((x) => x !== k) : [...filter.kinds, k] }),
    })),
    ...(showsState(place)
      ? [
        { kind: 'separator' } as MenuEntry,
        { kind: 'header', label: t('main.filter.state_header') } as MenuEntry,
        { label: t('main.filter.live'), checked: !filter.state, run: () => setFilter({ ...filter, state: null }) } as MenuEntry,
        // the open states, a line, the closed ones
        ...[...LIVE_STATES, 'discarded' as State].flatMap((s): MenuEntry[] => [
          ...(s === 'done' ? [{ kind: 'separator' } as MenuEntry] : []),
          { label: t(`state.${s}`), icon: <StatusRing state={s} size={13} />, checked: filter.state === s, run: () => setFilter({ ...filter, state: s }) },
        ]),
      ]
      : []),
    { kind: 'separator' },
    // Clear only while something is filtered (a greyed-out row read as a placeholder)
    kindsOn && { label: t('main.empty.clear_filters'), run: () => setFilter(NO_FILTER) },
  ]);
  const openFilterMenu = (el: HTMLElement) => {
    menu.open(filterMenu(kindCounts), { x: 0, y: 0, anchor: el }, t('main.toolbar.filter'));
    // each kind's count with the other filters as they are (MainModel.kindCounts)
    Promise.all(KINDS.map((k) => api.items(placeQuery(place, { ...filter, kinds: [k] }, text, sort, ascending, 1)).then((r) => [k, r.total] as const))).then((l) => {
      const c = Object.fromEntries(l);
      setKindCounts(c);
      menu.open(filterMenu(c), { x: 0, y: 0, anchor: el }, t('main.toolbar.filter'));
    }, () => {});
  };
  const moreMenu = (): MenuEntry[] => tidy([
    // items and projects are Recording & Items': with it off, none of these
    recordingOn && { label: t('main.new_item.menu'), icon: <Icon name="plus" size={14} />, keys: 'Ctrl+N', disabled: isPage(place), run: () => setNewItem(true) },
    recordingOn && { label: t('project.open_folder'), icon: <Icon name="folder-plus" size={14} />, keys: 'Ctrl+O', run: openFolder },
    recordingOn && registered.length > 0 && { label: t('menu.open_recent'), icon: <Icon name="folder" size={14} />, submenu: registered.slice(0, 10).map((p): MenuEntry => ({ label: p.name, icon: <ProjectGlyph id={p.id} size={14} />, tip: p.path, run: () => go(`project:${p.id}`) })) },
    recordingOn && { label: t('menu.rescan'), icon: <Icon name="refresh" size={14} />, run: () => api.rescan().catch(fail) },
    { kind: 'separator' },
    // the Mac's View menu words: what the item does now, not "Show or Hide"
    { label: t(sideOff ? 'menu.show_sidebar' : 'menu.hide_sidebar'), icon: <SidebarGlyph size={14} />, keys: 'Ctrl+Shift+S', run: toggleSide },
    { label: t(detailHidden ? 'menu.show_detail' : 'menu.hide_detail'), icon: <SidebarGlyph right size={14} />, keys: 'Ctrl+Alt+I', disabled: isPage(place), run: () => setDetailHidden((h) => !h) },
    { kind: 'separator' },
    { label: t('menu.palette'), icon: <Icon name="search" size={14} />, keys: 'Ctrl+K', run: () => setPalette(true) },
    { label: t('menu.shortcuts'), icon: <Icon name="keyboard" size={14} />, keys: 'Ctrl+/', run: () => setKeysOpen(true) },
    { label: t('menu.website'), icon: <Icon name="help-circle" size={14} />, run: () => api.openUrl(GUIDE + (i18n().lang === 'zh-Hans' ? encodeURIComponent('中文') : 'english')).catch(fail) },
    { kind: 'separator' },
    { label: t('mw.settings_menu'), icon: <Icon name="settings" size={14} />, keys: 'Ctrl+,', run: () => setScreen({ kind: 'settings' }) },
  ]);

  // ---------------------------------------------------------------- the selection summary (selectionPlan)
  const plan = (() => {
    const items = selectedRows;
    if (items.length < 2) return null;
    const b = handOffBlock(items);
    const n = items.length;
    const acts: PlanAction[] = [
      { id: 'hand_off', title: t('main.selection.hand_off'), tip: b ? blockText(b) : plural('main.selection.hand_off.tip', n), enabled: !b },
      { id: 'move', title: t('main.selection.move'), tip: plural('main.selection.move.tip', n), enabled: true },
    ];
    const states = actionsFor(items, false);
    const way: Action | null = b?.why === 'finished' ? (states.includes('reopen') ? 'reopen' : null) : b?.why === 'discarded' ? (states.includes('restore') ? 'restore' : null) : null;
    const st = way ?? states.find((a) => a !== 'discard') ?? null;
    if (st) {
      const valid = validFor(st, items).length;
      const key = actionKey(st, mac);
      acts.push({ id: st, title: menuCase(t(`action.${st}`)) + (valid < n ? ` (${i18n().formatNumber(valid)})` : ''), tip: t(`action.${st}.hint`) + (key ? ` (${key})` : ''), enabled: true });
    }
    const primary = !b ? 'hand_off' : way;
    const blocked = !b ? null : b.why === 'finished' ? t('main.selection.blocked.finished') : blockText(b);
    if (primary) acts.sort((x, y) => Number(y.id === primary) - Number(x.id === primary));
    // the Mac's selectionMoreMenu: the state verbs not on a button, the item's actions, and Discard last on its own
    // (one row from Mark as Done it was easy to hit)
    const rest = states.filter((a) => !acts.some((x) => x.id === a));
    const more = tidy([
      ...rest.filter((a) => a !== 'discard').map((a) => stateEntry(a, items)),
      { kind: 'separator' },
      ...itemActions(items, true),
      { kind: 'separator' },
      ...rest.filter((a) => a === 'discard').map((a) => ({ ...(stateEntry(a, items) as MenuItem), hint: t('action.discard.hint') })),
    ]);
    return { acts, primary, blocked, more };
  })();

  // ---------------------------------------------------------------- the heading
  const scopeTitle = place === 'inbox' ? t('main.place.inbox') : place === 'progress' ? t('main.place.progress') : place === 'unassigned' ? t('project.inbox')
    : place === 'all' ? t('main.place.all') : place === 'dictation' ? t('dictation.history.sidebar') : place === 'home' ? t('home.title')
      : place === 'cards' ? t('cards.title') : place === 'screen_text' ? t('feature.screen_text') : place === 'phone' ? t('feature.phone') : shownProject?.name ?? t('main.place.project');
  const headTitle = searching ? t('main.search.title', { a: text.trim() }) : scopeTitle;
  const counts = (() => {
    if (!loaded || missing || !rows.length) return '';
    if (scanning) return t('main.updating');
    if (filtered) {
      const of = t('main.items.of', { a: i18n().formatNumber(total), b: i18n().formatNumber(placeTotal) });
      return of;
    }
    if (place === 'inbox') return needsYouParts(summary?.new ?? 0, summary?.to_verify ?? 0, t);
    if (shownProject && current === shownProject.id) return t('main.project.current_count', { a: plural('main.items.count', total) });
    return plural('main.items.count', total);
  })();
  const filterCount = filter.kinds.length + (showsState(place) && filter.state ? 1 : 0);
  const filterParts = [
    filter.kinds.length ? KINDS.filter((k) => filter.kinds.includes(k)).map((k) => menuCase(t(`main.filter.kind_plural.${k}`))).join(t('mw.list_sep')) : '',
    showsState(place) && filter.state ? t(`state.${filter.state}`) : '',
  ].filter(Boolean);
  const filterText = filterParts.length ? t('main.filter.showing', { a: filterParts.join(' · ') }) : '';
  const placeJobs = useMemo(() => placeJobList(jobs, recs, place), [jobs, recs, place]);
  const sugGroups = place === 'unassigned' && !searching ? suggestionGroups(rows, registered) : [];

  // ---------------------------------------------------------------- the empty states (updateEmpty)
  const emptyView = (): ReactNode => {
    if (missing) {
      if (scanning) return <EmptyState busy title={t('main.empty.scanning')} body={t('main.empty.scanning.detail')} testId="empty-scanning" />;
      if (status && (!status.uv || !status.scripts)) return <EmptyState tone="trouble" icon={<Icon name="warning" size={34} />} title={t('main.empty.no_scripts')} body={t('main.empty.no_scripts.detail')} testId="empty-no-scripts" />;
      return (
        <EmptyState title={t('main.empty.no_index')} body={t('mw.empty.no_index.detail')} testId="empty-no-index">
          <button className="primary" onClick={() => api.rescan().catch(fail)}>{t('main.empty.scan')}</button>
        </EmptyState>
      );
    }
    if (!loaded || !emptyStateShown(rows.length, placeRecs.length)) return null;
    const q = text.trim();
    const clear = () => {
      setText('');
      setFilter(NO_FILTER);
      focusList();
    };
    if (q) {
      const hint = kindsOn ? t('main.empty.filters_on', { a: filterParts.join(' · ') }) : elsewhere > 0 ? plural('main.empty.elsewhere', elsewhere) : t('main.empty.try_shorter');
      return (
        <EmptyState tone="miss" icon={<Icon name="search" size={34} />} title={place === 'all' ? t('main.empty.no_results', { a: q }) : t('main.empty.no_results_in', { a: q, b: scopeTitle })} body={hint} testId="empty-search">
          {elsewhere > 0 && !kindsOn && <button onClick={() => go('all')}>{t('main.empty.search_all')}</button>}
          <button onClick={clear}>{t(kindsOn ? 'main.empty.clear_all' : 'main.empty.clear_search')}</button>
        </EmptyState>
      );
    }
    if (showsState(place) && filter.state === 'discarded' && !filter.kinds.length) return <EmptyState title={t('main.empty.discarded')} body={t('mw.empty.discarded.detail')} testId="empty-discarded" />;
    if (kindsOn)
      return (
        <EmptyState tone="miss" icon={<FilterGlyph size={34} />} title={t('main.empty.no_match')} body={t('main.empty.no_match.detail', { a: filterParts.join(' · ') })} testId="empty-filter">
          <button onClick={() => setFilter(NO_FILTER)}>{t('main.empty.clear_filters')}</button>
        </EmptyState>
      );
    if (place === 'inbox' && !emptyWorld) return <EmptyState title={t('main.empty.inbox_none')} body={t('main.empty.inbox_none.detail')} testId="inbox-empty" />;
    if (place === 'progress')
      return (
        <EmptyState title={t('main.empty.nothing_in_progress')} body={t('main.empty.nothing_in_progress.detail')} testId="empty-progress">
          {(summary?.inbox ?? 0) > 0 && <button className="primary" onClick={() => go('inbox')}>{t('main.empty.go_inbox')}</button>}
        </EmptyState>
      );
    if (place === 'unassigned') return <EmptyState title={t('main.empty.all_filed')} body={t('main.empty.all_filed.detail')} testId="empty-unassigned" />;
    if (shownProject && !shownProject.exists)
      return (
        <EmptyState tone="trouble" icon={<MissingFolderGlyph size={34} />} title={t('main.missing.title_named', { a: shownProject.name })} body={t(current === shownProject.id ? 'main.missing.detail_current' : 'main.missing.detail_named')} path={shownProject.path} testId="empty-missing">
          <button className="primary" onClick={() => locate(shownProject)}>{t('main.missing.locate_folder')}</button>
          <button className="link" onClick={() => removeProject(shownProject.id)}>{t('main.missing.remove')}</button>
        </EmptyState>
      );
    if (shownProject) {
      const cur = current === shownProject.id;
      return (
        <EmptyState title={t('main.empty.project')} body={t(cur ? 'main.empty.project.detail' : 'main.empty.project.detail_other')} testId="empty-project">
          {cur ? (
            <>
              <button className="primary" onClick={record}>{t('main.action.record')}</button>
              <button onClick={snap}>{t('main.action.snap')}</button>
            </>
          ) : (
            <>
              <button className="primary" onClick={() => useProject(shownProject.id)}>{t('main.project.use')}</button>
              <button onClick={record}>{t('main.action.record')}</button>
            </>
          )}
        </EmptyState>
      );
    }
    const none = !registered.length;
    return (
      <EmptyState title={t('main.empty.first')} body={t(none ? 'main.empty.first.detail' : 'main.empty.project.detail')} testId="empty-first">
        {none ? (
          <>
            <button className="primary" onClick={openFolder}>{t('project.open_folder')}</button>
            <button onClick={record}>{t('main.action.record')}</button>
          </>
        ) : (
          <>
            <button className="primary" onClick={record}>{t('main.action.record')}</button>
            <button onClick={snap}>{t('main.action.snap')}</button>
          </>
        )}
      </EmptyState>
    );
  };

  // ---------------------------------------------------------------- the detail
  live.current = {
    openFolders,
    go,
    reveal,
    openJob: (id) => {
      const j = jobs.find((x) => x.id === id);
      if (j) openJob(j);
    },
    focusList,
    pageStep: (label) => {
      undo.current.push({ kind: 'page', name: label });
      redo.current = [];
    },
    windowUndo: (r) => void (r ? doRedo() : doUndo()),
    undone: (uid) => {
      if (!selected.has(uid)) reveal(uid);
    },
    addedFiles: (uid, r) => {
      const it = itemsOf([uid])[0] ?? (current1?.uid === uid ? current1 : null);
      added({ kind: 'item', uid, title: it?.title || it?.item_id || t('main.item.untitled') }, r);
    },
  };
  const hostCb: HostCallbacks = useMemo(() => ({
    onHandoff: (_r: unknown, what: 'instruction' | 'full') => showToast(t(what === 'full' ? 'main.handoff.copied_full' : 'main.handoff.copied'), { mark: 'ok' }),
    onError: (e: unknown) => showToast(errText(e)),
    onFocusList: () => live.current.focusList(),
    onToast: (x: { msg: string; undo: boolean; label?: string }) =>
      new Promise<string>((done) => {
        let answered = false;
        const answer = (r: string) => {
          if (!answered) (answered = true), done(r);
        };
        showToast(x.msg, {
          // its Undo takes back only the step it was for: while that is still the window's next step
          undo: x.undo
            ? () => {
                const top = undo.current[undo.current.length - 1];
                answer(top?.kind === 'page' && (!x.label || top.name === x.label) ? 'undo' : 'gone');
              }
            : undefined,
          gone: () => answer('gone'),
        });
        if (!x.undo) answer('shown');
      }),
    onRegisterUndo: (label: string) => live.current.pageStep(label),
    onWindowUndo: (r: boolean) => live.current.windowUndo(r),
    onUndone: (uid: string) => live.current.undone(uid),
    onDownloaded: (name: string) => showToast(name ? t('main.toast.downloaded', { name }) : t('main.toast.download_failed')),
    onAddedFiles: (uid: string, r: AttachResult) => live.current.addedFiles(uid, r),
  }), []);
  /** an item the project's doc leaves out (discarded, moved in since): its page loads with it listed */
  const [docItem, setDocItem] = useState<string | null>(null);
  const host = useMemo(() => {
    if (!current1) return null;
    const p = projectRow(current1.project_id);
    if (docItem === current1.uid)
      return { ...hostFor({ project: current1.project_id, item: current1.uid }, p?.kind === 'inbox' ? null : p?.path ?? null, hostCb, editor), sessionBanner: true };
    // item mode: the banner above the page says who has the item (the Mac's blurtHostInfo.sessionBanner): the page's
    // work card doesn't repeat it
    return { ...hostFor({ project: current1.project_id }, p?.kind === 'inbox' ? null : p?.path ?? null, hostCb, editor), sessionBanner: true };
  }, [current1?.project_id, docItem === current1?.uid, projects, editor]);
  const reviewHost = useMemo(() => {
    if (detail?.kind !== 'session') return null;
    const p = detail.project ? projectRow(detail.project) : null;
    return hostFor({ session: detail.dir }, p && p.kind !== 'inbox' ? p.path : null, hostCb, editor);
  }, [detail, editor]);
  // a recording's own detail turns into its run's once one starts (Organize, Retry from there)
  const shownRec = detail?.kind === 'recording' ? recs.find((r) => samePath(r.info.dir, detail.dir)) ?? null : null;
  const shownRecJob = shownRec && (shownRec.state.kind === 'organising' || shownRec.state.kind === 'failed') ? shownRec.state.job : null;
  const shownJob = detail?.kind === 'job' ? jobs.find((j) => j.id === detail.id) ?? null : shownRecJob;
  /** the line above the item on show (the Mac's ItemBanner) */
  const banner = current1 ? bannerPlan(current1, jobs) : null;
  const bannerText = (() => {
    if (!banner) return '';
    if (banner.kind === 'organizing') {
      const j = jobs.find((x) => x.id === banner.job);
      const step = j?.steps.find((x) => x.state === 'running') ?? j?.steps.find((x) => x.state === 'pending');
      return t(banner.text.key, { what: step ? t(`job.step.${step.id}`) : t('job.state.running') });
    }
    if (banner.text.key === 'main.banner.working') {
      const id = banner.text.args[0];
      return t(banner.text.key, { who: id ? agentNames[id] ?? id : t('main.banner.your_agent') });
    }
    return t(banner.text.key, { who: banner.text.args[0], what: banner.text.args[1] });
  })();
  function bannerAction(a: string) {
    if (!current1 || !banner) return;
    const job = banner.job;
    if (a === 'progress' && job) {
      const j = jobs.find((x) => x.id === job);
      return j ? openJob(j) : undefined;
    }
    if (a === 'done' || a === 'wontfix' || a === 'take_back') void apply(a as Action, [current1]);
  }
  const jobTitle = (j: Job) => {
    // an organizing job with a name of its own is that name ("AI fill-in"), not "Organizing · AI fill-in": two names
    // glued by a dot read as one jargon phrase
    if (j.type === 'process' && j.title) return j.title;
    // a recording's run: the recording ("Recording · 3:12")
    const rec = recOfJob(j);
    if (rec) return [t('inbox.mode.video'), recLength(rec)].filter(Boolean).join(' · ');
    const what = t(`job.type.${j.type}`);
    return j.title ? `${what} · ${j.title}` : what;
  };
  /** A job row chosen from the keyboard: shown in the detail, the list keeps the keyboard. */
  function selectJob(j: Job) {
    setSelected(new Set());
    setFocus(null);
    setDetail({ kind: 'job', id: j.id });
  }
  function openJob(j: Job) {
    setScreen({ kind: 'main' });
    setSelected(new Set());
    setFocus(null);
    setDetail({ kind: 'job', id: j.id });
  }
  /** The recording a process job organises (its detail is that recording's: its words, its buttons). */
  const recOfJob = (j: Job): Recording | null => (j.type === 'process' && j.session ? recs.find((r) => samePath(r.info.dir, j.session)) ?? null : null);
  /** The recording a run's detail is: while this run is that recording's newest (an older run is just a job). */
  const recDetailOf = (j: Job): RecDetail | null => {
    const r = recOfJob(j);
    if (!r || (r.state.kind !== 'organising' && r.state.kind !== 'failed') || r.state.job?.id !== j.id) return null;
    return { r, agent: agentReady, handlers: recHandlers };
  };
  /** A recording's place: its project, or Unassigned. */
  const placeOfProject = (id: string | null | undefined): Place => (id && id !== 'inbox' ? `project:${id}` : 'unassigned');
  const recHandlers: RecHandlers = {
    // from Home (a page, no detail column): the recording's place, with it in the detail
    onReview: (r: Recording) => {
      if (isPage(place)) go(placeOfProject(r.info.project_id), { focusList: false });
      setScreen({ kind: 'main' });
      setDetail({ kind: 'session', dir: r.info.dir, project: r.info.project_id });
    },
    onJob: (j: Job) => {
      if (isPage(place)) go(placeOfProject(j.project), { focusList: false });
      openJob(j);
    },
    // from Home: the recording's place, with its detail (Play Video, Show in Folder, Organize… are there)
    onDetail: (r: Recording) => {
      if (isPage(place)) go(placeOfProject(r.info.project_id), { focusList: false });
      setScreen({ kind: 'main' });
      setSelected(new Set());
      setFocus(null);
      setDetail({ kind: 'recording', dir: r.info.dir });
    },
    onSettings: (pane: string) => (setScreen({ kind: 'settings' }), goSettingsPane(pane)),
    onToast: (m: string, action?: { label: string; run: () => void }) => showToast(m, action ? { action, mark: 'warn' } : {}),
    onChanged: () => refresh(),
  };
  const lang = i18n().lang;
  const platform = status?.platform ?? 'win';

  // ---------------------------------------------------------------- keyboard (handleKeyEquivalent + ItemTableView.keyDown)
  const overlay = palette || keysOpen || newItem || !!settingsFor || !!movePop || menu.isOpen;
  const onKey = (e: KeyboardEvent) => {
    if (e.defaultPrevented || isImeKey(e) || welcome) return;
    const ctrl = e.ctrlKey || e.metaKey;
    const key = e.key.length === 1 ? e.key.toLowerCase() : e.key;
    const field = inField(e.target);
    const inDetail = !!(e.target as HTMLElement)?.closest?.('.mw-detail');
    const stop = (f: () => void) => {
      e.preventDefault();
      f();
    };
    // keys that work wherever the focus is
    if (ctrl && !e.altKey && !e.shiftKey && !overlay) {
      const n = /^[1-9]$/.test(key) ? Number(key) : 0;
      if (key === 'k') return stop(() => setPalette((p) => !p));
      if (key === 'f') return stop(focusSearch);
      if (key === 'o' && recordingOn) return stop(openFolder);
      if (key === 'n' && recordingOn && !isPage(place)) return stop(() => setNewItem(true));
      if (key === ',') return stop(() => setScreen({ kind: 'settings' }));
      if (key === '/') return stop(() => setKeysOpen(true));
      // the window's own close (Blurt stays in the notification area)
      if (key === 'w' && inTauri) return stop(() => void getCurrentWindow().close().catch(() => {}));
      if (key === 'i' && shownProject) return stop(() => setSettingsFor(shownProject));
      // Ctrl+0 Home; Ctrl+1–4 the items' places and Ctrl+5–9 the projects, while Recording & Items is on
      if (key === '0') return stop(() => go('home'));
      if (n >= 1 && n <= 4 && recordingOn) return stop(() => go((['inbox', 'progress', 'unassigned', 'all'] as Place[])[n - 1]));
      if (n >= 5 && recordingOn) return stop(() => registered[n - 5] && go(`project:${registered[n - 5].id}`));
    }
    if (ctrl && e.altKey && !e.shiftKey && !overlay && key === 'd' && !off.has('dictation')) return stop(() => go('dictation'));
    if (ctrl && e.altKey && !e.shiftKey && !overlay && key === 'i') return stop(() => setDetailHidden((h) => !h));
    if (ctrl && e.shiftKey && !e.altKey && !overlay && key === 's') return stop(toggleSide);
    if (ctrl && e.shiftKey && !overlay && key === 'r' && selectedRows.length) return stop(() => revealItems(selectedRows));
    // the window's undo, outside text fields and the detail page (which keeps its own)
    if (ctrl && !e.altKey && !field && !inDetail && !overlay && (key === 'z' || key === 'y')) return stop(key === 'y' || e.shiftKey ? doRedo : doUndo);
    if (e.key === 'Escape') {
      if (overlay) return;
      if (narrow && sidePeek) return stop(() => setSidePeek(false));
      if (detail?.kind === 'session' || detail?.kind === 'recording') return stop(() => setDetail(null));
      if (inDetail && !field) return stop(focusList);
      return;
    }
    if (overlay || field || inDetail || renaming || (menu.isOpen && stateMenu) || screen.kind !== 'main' || isPage(place)) return;
    const sel = selectedRows;
    // Hand Off: Ctrl+Enter, and Ctrl+Shift+C (Copy Instruction's key before it was the one hand-off)
    if ((ctrl && e.key === 'Enter') || (ctrl && e.shiftKey && key === 'c')) return stop(() => sel.length && void handOff(sel.map((i) => i.uid)));
    if (ctrl && e.altKey && key === 'c') return stop(() => copyLines(sel.map(pathOf), t('mw.copied.path')));
    if (ctrl && !e.shiftKey && !e.altKey && key === 'c' && sel.length && !window.getSelection()?.toString()) return stop(() => copyLines(sel.map(pathOf), t('mw.copied.path')));
    if (ctrl && key === 'a') return stop(() => setSelected(new Set(order)));
    if (ctrl && (e.key === 'Delete' || e.key === 'Backspace')) return stop(() => act('Delete'));
    if (ctrl || e.altKey) return;
    const step = (d: number) => {
      // the running jobs above the list (TopRows.step): ↑ on the first item goes to the last of them, ↑ / ↓ walk them
      // (the detail shows a job, as a click does), ↓ from the last one is the first item again
      const jobIds = placeJobs.map((j) => j.id);
      const onJob = detail?.kind === 'job' && !selected.size ? jobIds.indexOf(detail.id) : -1;
      if (onJob >= 0) {
        if (d > 0 && onJob === jobIds.length - 1) {
          if (!order.length) return;
          setSelected(new Set([order[0]]));
          setFocus(order[0]);
          setDetail(null);
          setScrollTo({ uid: order[0], n: Date.now() });
        } else if (d < 0 && onJob === 0) return;
        else selectJob(placeJobs[onJob + d]);
        return;
      }
      if (d < 0 && !e.shiftKey && jobIds.length && (!focus || order.indexOf(focus) <= 0)) return selectJob(placeJobs[jobIds.length - 1]);
      if (!order.length) return;
      const i = focus ? order.indexOf(focus) : -1;
      const n = order[Math.max(0, Math.min(order.length - 1, i < 0 ? (d > 0 ? 0 : order.length - 1) : i + d))];
      if (e.shiftKey) setSelected((cur) => new Set([...cur, n]));
      else setSelected(new Set([n]));
      setFocus(n);
      setDetail(null);
      setScrollTo({ uid: n, n: Date.now() });
    };
    if (key === 'j' || e.key === 'ArrowDown') return stop(() => step(1));
    if (key === 'k' || e.key === 'ArrowUp') return stop(() => step(-1));
    if (e.key === 'Enter') {
      // Enter on a list with no rows: the empty state's primary
      if (!order.length) return stop(() => document.querySelector<HTMLButtonElement>('.mw-list .hero-empty .acts button.primary')?.click());
      return stop(() => document.querySelector<HTMLElement>('.mw-detail textarea, .mw-detail input')?.focus());
    }
    if (key === ' ') return stop(() => openPicture(sel));
    if (key === '?' || (key === '/' && e.shiftKey)) return stop(() => setKeysOpen(true));
    if (key === '/') return stop(focusSearch);
    if (key === 'e') return stop(() => sel.length === 1 && setRenaming(sel[0].uid));
    // F2 (Windows' rename): the selected item while the list has the focus, else the project on show
    if (e.key === 'F2' && !e.defaultPrevented) {
      const inList = !!listRef.current?.contains(document.activeElement);
      return stop(() => (inList && sel.length === 1 ? setRenaming(sel[0].uid) : isProject(place) && setRenamingProject(place.slice(8))));
    }
    if (key === 'm') return stop(() => pickProject());
    if (key === 's')
      return stop(() => {
        const el = sel.length ? document.querySelector<HTMLElement>(`.mw-row[data-uid="${CSS.escape(sel[0].uid)}"] .mw-c-ring button`) : null;
        if (el) openStateMenu(sel[0], el);
      });
    if (['a', 'd', 'r', 'w', 'x', 'Delete', 'Backspace'].includes(key)) return stop(() => act(key));
    if (/^[1-4]$/.test(key)) return stop(() => setKind(KINDS[Number(key) - 1]));
  };
  const keyRef = useRef(onKey);
  keyRef.current = onKey;
  useEffect(() => {
    const h = (e: KeyboardEvent) => keyRef.current(e);
    window.addEventListener('keydown', h);
    return () => window.removeEventListener('keydown', h);
  }, []);

  // Ctrl+V wherever the focus is, unless the page took it itself (pasteTarget, pasteInto)
  const onPaste = (e: ClipboardEvent) => {
    if (e.defaultPrevented || welcome || overlay) return;
    const el = e.target as HTMLElement | null;
    const field = inField(el);
    const item = detailZone();
    const types = [...(e.clipboardData?.types ?? [])];
    const to = pasteTarget({ field, detail: !!el?.closest?.('.mw-detail'), item: !!item, files: types.includes('Files'), main: screen.kind === 'main' && !isPage(place) });
    if (to === 'page' || to === 'none') return;
    const sync = { files: [...(e.clipboardData?.files ?? [])], text: e.clipboardData?.getData('text/plain') ?? '', field: field ? el : null };
    e.preventDefault();
    void pasteInto(to, item, sync);
  };
  const pasteRef = useRef(onPaste);
  pasteRef.current = onPaste;
  useEffect(() => {
    const h = (e: ClipboardEvent) => pasteRef.current(e);
    document.addEventListener('paste', h);
    return () => document.removeEventListener('paste', h);
  }, []);

  // The dictation key while this window has the focus: Windows' key hook doesn't hear it then, so it is passed on.
  useEffect(() => {
    const on = (e: KeyboardEvent) => {
      if (e.code !== 'AltRight' && e.code !== 'AltLeft') return;
      if (document.querySelector('.st-key.rec')) return; // a shortcut field is recording keys: Alt is part of the combo
      if (e.code === 'AltRight') e.preventDefault(); // a lone right Alt would put the window in menu mode (the next key lost)
      if (document.querySelector('[data-key-probe]')) return; // the Welcome's key check: the press only checks the key
      if (!e.repeat) void api.dictationKey(e.code, e.type === 'keydown').catch(() => {});
    };
    window.addEventListener('keydown', on, true);
    window.addEventListener('keyup', on, true);
    return () => {
      window.removeEventListener('keydown', on, true);
      window.removeEventListener('keyup', on, true);
    };
  }, []);

  // ---------------------------------------------------------------- palette entries (CommandPalette.entries)
  const paletteEntries = (): PaletteEntry[] => {
    const items = selectedRows;
    const out: PaletteEntry[] = [];
    const ic = (n: string) => <Icon name={n as never} size={15} />;
    if (items.length) {
      out.push(
        { id: 'hand_off', title: t('main.menu.hand_off'), icon: <StatusRing state="handed_off" size={14} />, keys: 'Ctrl+Enter', hint: t('main.palette.hint.copy_instruction'), section: 'selected', pinned: true, run: () => void handOff(items.map((i) => i.uid)) },
        { id: 'copy_full', title: t('main.cmd.copy_full'), icon: ic('align-left'), hint: t('main.palette.hint.copy_full'), section: 'selected', run: () => void handOff(items.map((i) => i.uid), true) },
        ...actionsFor(items, false).map((a): PaletteEntry => ({ id: `state:${a}`, title: menuCase(t(`action.${a}`)), icon: <StatusRing state={stateTarget(a, items)} size={14} />, keys: actionKey(a, mac), hint: t(`action.${a}.hint`), section: 'selected', pinned: true, run: () => apply(a, items) })),
        { id: 'move_pick', title: t('main.palette.move_pick'), icon: ic('move'), keys: 'M', hint: plural('main.selection.move.tip', items.length), section: 'selected', pinned: true, run: () => setTimeout(() => pickProject(items.map((i) => i.uid))) },
        { id: 'export', title: t('main.menu.export_bundle'), icon: ic('archive'), section: 'selected', run: () => exportBundle(items) },
        { id: 'picture', title: t('mw.open_picture'), icon: ic('eye'), keys: t('main.keys.space'), section: 'selected', run: () => openPicture(items) },
        { id: 'reveal', title: revealLabel(), icon: ic('reveal'), keys: 'Ctrl+Shift+R', section: 'selected', run: () => revealItems(items) },
        { id: 'copy_path', title: t('action.copy_path'), icon: ic('copy'), keys: 'Ctrl+Alt+C', section: 'selected', run: () => copyLines(items.map(pathOf), t('mw.copied.path')) },
        { id: 'rename', title: t('main.menu.rename'), icon: ic('pencil'), keys: 'E', section: 'selected', run: () => items.length === 1 && setRenaming(items[0].uid) },
        { id: 'enrich', title: t('main.menu.enrich'), icon: ic('text-plus'), section: 'selected', run: () => enrich(items) },
      );
    }
    // only what the capabilities that are on can do (an off one's places and actions aren't offered)
    const rec = recordingOn;
    const on = (c: Parameters<typeof off.has>[0]) => !off.has(c);
    out.push(
      ...(rec ? [{ id: 'record', title: t('main.action.record'), icon: ic('record'), keys: hotkeyOf('record') || undefined, hint: t('main.toolbar.record.tip', { a: '' }).trim(), section: 'capture', pinned: true, run: record } as PaletteEntry] : []),
      ...(on('cards') ? [{ id: 'snap', title: t('main.action.snap'), icon: ic('screenshot'), keys: hotkeyOf('snap') || undefined, hint: t('main.toolbar.snap.tip', { a: '' }).trim(), section: 'capture', pinned: true, run: snap } as PaletteEntry] : []),
      { id: 'go:home', title: t('home.title'), icon: ic('home'), keys: 'Ctrl+0', section: 'go', pinned: true, run: () => go('home') },
      ...(on('dictation') ? [{ id: 'go:dictation', title: t('dictation.history.menu'), icon: ic('character-cursor'), keys: 'Ctrl+Alt+D', section: 'go', pinned: true, run: () => go('dictation') } as PaletteEntry] : []),
      ...(on('cards') ? [{ id: 'go:cards', title: t('cards.title'), icon: ic('cards'), section: 'go', run: () => go('cards') } as PaletteEntry] : []),
      ...(on('screen_text') && status && builds(status).screenText ? [{ id: 'go:screen_text', title: t('feature.screen_text'), icon: ic('text-viewfinder'), section: 'go', run: () => go('screen_text') } as PaletteEntry] : []),
      ...(on('phone') ? [{ id: 'go:phone', title: t('feature.phone'), icon: ic('phone'), section: 'go', run: () => go('phone') } as PaletteEntry] : []),
      ...(rec
        ? ([
            { id: 'go:inbox', title: t('main.place.inbox'), icon: ic('inbox'), keys: 'Ctrl+1', section: 'go', pinned: true, run: () => go('inbox') },
            { id: 'go:progress', title: t('main.place.progress'), icon: <ProgressGlyph size={15} />, keys: 'Ctrl+2', section: 'go', pinned: true, run: () => go('progress') },
            { id: 'go:unassigned', title: t('project.inbox'), icon: <Icon name="tray-2" size={15} />, keys: 'Ctrl+3', section: 'go', run: () => go('unassigned') },
            { id: 'go:all', title: t('main.place.all'), icon: ic('list-box'), keys: 'Ctrl+4', section: 'go', pinned: true, run: () => go('all') },
            { id: 'new_item', title: t('main.new_item.menu'), icon: ic('plus'), keys: 'Ctrl+N', run: () => setNewItem(true) },
            { id: 'open_folder', title: t('project.open_folder'), icon: ic('folder-plus'), keys: 'Ctrl+O', run: openFolder },
            ...(kindsOn ? [{ id: 'clear_filters', title: t('main.empty.clear_filters'), icon: <FilterGlyph size={15} />, run: () => setFilter(NO_FILTER) }] : []),
            { id: 'rescan', title: t('menu.rescan'), icon: ic('refresh'), run: () => api.rescan().catch(fail) },
          ] as PaletteEntry[])
        : []),
      { id: 'shortcuts', title: t('menu.shortcuts'), icon: ic('keyboard'), keys: '?', run: () => setKeysOpen(true) },
      ...(rec ? KINDS.map((k): PaletteEntry => ({ id: `only:${k}`, title: t('main.palette.only_kind', { a: t(`kind.${k}`) }), icon: <KindIcon kind={k} size={15} />, run: () => setFilter({ ...filter, kinds: [k] }) })) : []),
      ...(rec ? jobs.filter((j) => j.state === 'running' || j.state === 'queued').map((j): PaletteEntry => ({ id: `job:${j.id}`, title: jobTitle(j), icon: ic('spark'), run: () => openJob(j) })) : []),
      { id: 'settings', title: t('mw.settings_menu'), icon: ic('settings'), keys: 'Ctrl+,', run: () => setScreen({ kind: 'settings' }) },
    );
    for (const p of rec ? registered : []) {
      out.push({ id: `project:${p.id}`, title: p.name, icon: <ProjectGlyph id={p.id} size={15} />, hint: p.id === current ? t('main.project.current_count', { a: p.path }) : t('main.palette.project', { a: p.path }), run: () => go(`project:${p.id}`) });
      // a move target is a project the items aren't all in already, whose folder is there; it carries its own folder
      if (items.length && p.exists && !items.every((i) => i.project_id === p.id))
        out.push({ id: `move:${p.id}`, title: t('main.palette.move_to', { a: p.name }), icon: <ProjectGlyph id={p.id} size={15} />, hint: t('main.list.move.tip', { a: p.name }), section: 'selected', run: () => moveItems(items.map((i) => i.uid), p.id) });
      if (p.id !== current) out.push({ id: `use:${p.id}`, title: t('main.palette.use_project', { a: p.name }), icon: <ScopeGlyph size={14} />, hint: t('main.project.use.tip'), run: () => useProject(p.id) });
    }
    if (current) out.push({ id: 'use:none', title: t('main.palette.use_none'), icon: <Icon name="tray-2" size={15} />, run: () => useProject(null) });
    return out;
  };

  // ---------------------------------------------------------------- column dividers
  const drag = (which: 'side' | 'list') => (e: React.MouseEvent) => {
    e.preventDefault();
    const x0 = e.clientX;
    const w0 = which === 'side' ? sideW : listW;
    const mv = (ev: MouseEvent) => {
      const w = w0 + ev.clientX - x0;
      if (which === 'side') setSideW(Math.max(190, Math.min(320, w)));
      else setListW(Math.max(330, Math.min(window.innerWidth - (sideOff ? 0 : sideFit) - 380, w)));
    };
    const up = () => {
      window.removeEventListener('mousemove', mv);
      window.removeEventListener('mouseup', up);
      document.body.classList.remove('mw-resizing');
    };
    document.body.classList.add('mw-resizing');
    window.addEventListener('mousemove', mv);
    window.addEventListener('mouseup', up);
  };

  // ---------------------------------------------------------------- render
  if (welcome)
    return (
      <div className="app wl-app" data-platform={platform} lang={lang}>
        <Welcome onb={welcome.onb} firstRun={welcome.firstRun} onDone={() => setWelcome(null)} onToast={(m) => showToast(m)}
          onSettings={(pane) => (setWelcome(null), setScreen({ kind: 'settings' }), goSettingsPane(pane))} />
        {toast && <div className="shell-toast" role="status">{toast.msg}</div>}
        <AgentSetupAsk />
        <PhoneAsk />
      </div>
    );

  const mainScreen = screen.kind === 'main';
  const dictationPage = mainScreen && place === 'dictation';
  /** a page of its own (Home, Dictation, Cards, Phone): it takes the list and the detail columns */
  const pageShown = mainScreen && isPage(place);
  // a narrow window with the sidebar shown on demand: sidebar and list, the detail comes back once a place is picked
  // the sidebar shown on demand in a narrow window lies over the list (Windows 11 NavigationView's overlay pane):
  // nothing under it reflows, the open item stays open; a click outside, Esc or a pick folds it back (windows-parity
  // main-window.md 12.1 / 14.4)
  const peek = narrow && sidePeek && screen.kind !== 'settings';
  const showDetail = mainScreen && !pageShown && !detailHidden && !fold;
  const sideFit = narrow ? sideW : Math.max(190, Math.min(sideW, winW - 330 - 380));
  const sideIn = sideOff || peek ? 0 : sideFit;
  const listFit = Math.max(330, Math.min(listW, winW - sideIn - 380));
  const cols = [`${sideIn}px`, !mainScreen || pageShown ? '1fr' : showDetail ? `${listFit}px` : '1fr', showDetail ? `minmax(${winW < 710 ? 0 : 380}px, 1fr)` : '0px'].join(' ');
  const empty = mainScreen && !pageShown ? emptyView() : null;
  // a toast sits under the column it is about — the detail's when there is one, else the content's — never across a
  // pane divider (it straddled the list and the detail when centred on the window)
  const toastAt = (() => {
    const left = sideIn;
    if (showDetail) return left + listFit + (winW - left - listFit) / 2;
    return left + (winW - left) / 2;
  })();

  return (
    <div className="app mw" data-platform={platform} lang={lang} style={{ gridTemplateColumns: cols }}>
      <header className="mw-toolbar">
        <button className={`mw-tool ${peek ? 'on' : ''}`} onClick={toggleSide} aria-pressed={narrow ? peek : !sideHidden} aria-label={t('menu.toggle_sidebar')} title={`${t('menu.toggle_sidebar')} (Ctrl+Shift+S)`} data-testid="toggle-sidebar">
          <SidebarGlyph size={16} />
        </button>
        <span className="grow" />
        {!dictationPage && (
          <>
            {/* icon-only, as the Mac's toolbar: the words and the user's key are the tooltip; each only while its
                capability is on */}
            {recordingOn && (
              <button className="mw-tool sq" onClick={record} aria-label={t('main.action.record')} title={t('main.toolbar.record.tip', { a: hotkeyOf('record') }).trim()} data-testid="record">
                <Icon name="record" size={16} />
              </button>
            )}
            {!off.has('cards') && (
              <button className="mw-tool sq" onClick={snap} aria-label={t('main.action.snap')} title={t('main.toolbar.snap.tip', { a: hotkeyOf('snap') }).trim()} data-testid="snap">
                <Icon name="screenshot" size={16} />
              </button>
            )}
          </>
        )}
        <button className="mw-tool" onClick={(e) => menu.open(moreMenu(), { x: 0, y: 0, anchor: e.currentTarget }, t('mw.more'))} aria-label={t('mw.more')} title={t('mw.more')} aria-haspopup="menu" data-testid="more">
          <Icon name="more" size={16} />
        </button>
      </header>

      {peek && <div className="mw-peek-scrim" onMouseDown={() => setSidePeek(false)} aria-hidden="true" />}
      <div className={`mw-side-col ${sideOff ? 'hidden' : ''} ${peek ? 'peek' : ''}`} style={peek ? { width: sideFit } : undefined}>
        {!sideOff && (
          <>
            <Sidebar
              place={mainScreen ? place : ('' as Place)}
              dragging={dragging}
              fresh={freshProject}
              onGo={go}
              summary={summary}
              projects={registered}
              current={current}
              onMove={(u, p) => moveItems(u, p)}
              onDropAt={(e, p, phase) => sidebarDrop(e, p ?? listTarget, phase)}
              onOpenFolder={openFolder}
              onReorder={(id, onto, after) => {
                const ids = reorderedProjects(registered, id, onto, after);
                if (ids) api.orderProjects(ids).then(refresh, (e) => showToast(`${t('main.project.save_failed')} — ${errText(e)}`));
              }}
              onSettings={() => setScreen({ kind: 'settings' })}
              off={off}
              screenText={!!status && builds(status).screenText}
              cards={cardsWaiting}
              phoneAlert={!!remote && phoneNeedsAttention(remote)}
              onProjectMenu={(p, at) => menu.open(projectMenu(p), at, p.name)}
              renaming={renamingProject}
              onRename={(id) => setRenamingProject(id)}
              onRenameDone={(id, name) => {
                setRenamingProject(null);
                if (name) saveProject(id, { name });
              }}
            />
            <div className="mw-divider" onMouseDown={drag('side')} role="separator" aria-orientation="vertical" />
          </>
        )}
      </div>

      {screen.kind === 'settings' && status && (
        <main className="mw-wide content">
          <section className="pad st-host">
            <SettingsView status={status} onToast={(m) => showToast(m)} onBack={() => setScreen({ kind: 'main' })} onGo={(p) => (setScreen({ kind: 'main' }), go(p))} onWelcome={() => api.onboarding().then((o) => setWelcome({ onb: o, firstRun: false }), fail)} onLang={(l) => (l === 'auto' ? api.status().then((s) => relang(s.lang)) : relang(l))} />
          </section>
        </main>
      )}
      {dictationPage && (
        <main className="mw-wide content">
          <DictationView project={projects?.current ?? null} onShowItem={(uid) => reveal(uid)} onSettings={() => setScreen({ kind: 'settings' })} onToast={(m) => showToast(m)} />
        </main>
      )}

      {pageShown && place === 'home' && status && (
        <main className="mw-wide content">
          <HomePage status={status} hotkeys={hotkeys} summary={summary} cardsWaiting={cardsWaiting} onGo={go} onReveal={(uid) => void reveal(uid)} onToast={(m) => showToast(m)}
            onSettings={(pane) => (setScreen({ kind: 'settings' }), goSettingsPane(pane))} tick={tick}
            recordings={recs} recAgent={agentReady} recHandlers={recHandlers} />
        </main>
      )}
      {pageShown && place === 'cards' && (
        <main className="mw-wide content">
          <CardsPage hotkeys={hotkeys} platform={platform} onSnap={snap} onToast={(m, undo) => showToast(m, undo ? { undo } : {})} />
        </main>
      )}
      {pageShown && place === 'screen_text' && (
        <main className="mw-wide content">
          <ScreenTextPage hotkeys={hotkeys} onToast={(m) => showToast(m)} onSettings={() => (setScreen({ kind: 'settings' }), goSettingsPane('screentext'))} />
        </main>
      )}
      {pageShown && place === 'phone' && status && (
        <main className="mw-wide content">
          <PhonePage status={status} onSettings={(pane) => (setScreen({ kind: 'settings' }), goSettingsPane(pane))} />
        </main>
      )}

      {mainScreen && !pageShown && (
        <section
          className="mw-list"
          ref={listRef}
          tabIndex={-1}
          aria-label={scopeTitle}
          data-testid="list"
          onDragOver={(e) => {
            // files, pictures, text from another app, or the island's cards (rows of the list have their own drag)
            const what = dragWhat(e);
            if (what === 'rows' || what === 'none') return;
            e.preventDefault();
            e.dataTransfer.dropEffect = 'copy'; // (Windows' drag of files and cards allows only a copy)
            dragOverZone(e, listZone(e.target as HTMLElement), what, 'list');
          }}
          onDragLeave={(e) => {
            if (!e.currentTarget.contains(e.relatedTarget as Node | null)) setDrop((d) => (d?.where === 'list' ? null : d));
          }}
          onDrop={(e) => {
            const what = dragWhat(e);
            if (what === 'rows' || what === 'none') return;
            e.preventDefault();
            dropOn(e, listZone(e.target as HTMLElement), what);
          }}
          onMouseDown={(e) => {
            const el = e.target as HTMLElement;
            if (!inField(el) && !el.closest('button')) listRef.current?.focus({ preventScroll: true });
          }}
        >
          {drop?.where === 'list' && (
            // pinned at the top while something is dragged over the list: a full list has no empty area to drop on
            <div className={`mw-drop-band ${drop.zone.kind === 'new' ? 'on' : ''}`} aria-hidden="true" data-testid="drop-band">
              <Icon name="plus" size={14} />
              {drop.what === 'cards' ? t('main.drop.file_into', { a: projectName(listTarget) }) : t('main.drop.new')}
            </div>
          )}
          <ListHeading
            title={headTitle}
            counts={counts}
            sortLabel={`${sortName(sort)} ${ascending ? '↑' : '↓'}`}
            sortTip={t('main.sort.label', { a: sortName(sort), b: ascending ? t('main.sort.ascending') : t('main.sort.descending') })}
            filters={filterCount}
            filterTip={filterText || t('main.toolbar.filter.tip')}
            showControls={!placeEmpty && !missing}
            canSort={rows.length > 0}
            canAdd
            onSort={(el) => menu.open(sortMenu(), { x: 0, y: 0, anchor: el }, t('menu.sort_by'))}
            onFilter={openFilterMenu}
            onAdd={() => setNewItem(true)}
          />
          {!placeEmpty && !missing && (
            <SearchField
              ref={searchRef}
              value={text}
              enabled
              onChange={setText}
              onClear={() => setText('')}
              onEnterList={() => {
                if (!selected.size && order.length) {
                  setSelected(new Set([order[0]]));
                  setFocus(order[0]);
                }
                focusList();
              }}
            />
          )}
          {shownProject && !shownProject.exists && rows.length > 0 && <MissingFolderBanner onLocate={() => locate(shownProject)} />}
          {place === 'inbox' && <CapturesBanner count={cardsWaiting} onChoose={() => void api.revealCards().catch(() => {})} />}
          <RecordingsSection recs={placeRecs} agent={agentReady} selectedJob={detail?.kind === 'job' ? detail.id : null} selectedDir={detail?.kind === 'recording' ? detail.dir : null} handlers={recHandlers}
            onMenu={(entries, at) => menu.open(entries, at)} />
          <JobsSection jobs={placeJobs} selected={detail?.kind === 'job' ? detail.id : null} projectName={projectName} showProject={!isProject(place) && place !== 'unassigned'} onSelect={openJob} />
          <SuggestionsBanner groups={sugGroups} onMoveAll={(p, u) => moveItems(u, p)} />
          {filterText && !emptyWorld && <FilterBar text={filterText} canClear={rows.length > 0} onOpen={openFilterMenu} onClear={() => setFilter(NO_FILTER)} />}
          {empty ?? (
            <ItemList
              rows={rows}
              sections={grouped.sections}
              grouping={how}
              selected={selected}
              focus={focus}
              searching={searching}
              projectName={projectName}
              canSuggest={(id) => registered.some((p) => p.id === id)}
              suggestRows={place === 'unassigned' && !searching}
              onSelect={(uid, how2) => {
                setDetail(null);
                setRenaming(null);
                setSelected((cur) => nextSelection(order, cur, focus, uid, how2));
                if (how2 !== 'range') setFocus(uid);
              }}
              onOpen={() => (page.current ? page.current.focusTitle() : document.querySelector<HTMLElement>('.mw-detail textarea, .mw-detail input')?.focus())}
              onAction={(r, a) => apply(a, selected.has(r.uid) ? selectedRows : [r])}
              onMenu={(r, at) => menu.open(contextMenu(selected.has(r.uid) ? selectedRows : [r]), at)}
              onMoveTo={(u, p) => moveItems(u, p)}
              stateMenu={menu.isOpen ? stateMenu : null}
              onStateMenu={setStateMenu}
              onRingMenu={openStateMenu}
              renaming={renaming}
              onRenameDone={(r, title) => {
                setRenaming(null);
                focusList();
                if (title) editItems([r], { title });
              }}
              mac={mac}
              scrollTo={scrollTo}
              nativeDrag={nativeDrag}
              dropUid={drop?.zone.kind === 'item' ? drop.zone.uid : null}
              onNativeDrag={(uids) => {
                dragging.current = uids;
                api.dragOut(uids).then((ok) => !ok && (dragging.current = null), () => (dragging.current = null));
              }}
            />
          )}
          {showDetail && <div className="mw-divider right" onMouseDown={drag('list')} role="separator" aria-orientation="vertical" />}
        </section>
      )}

      {showDetail && (
        <aside
          className={`mw-detail ${drop?.where === 'detail' ? 'drop' : ''}`}
          data-testid="detail"
          aria-label={t('main.detail.label')}
          // files, pictures and the island's cards dropped on the item on show are added to it (drag-drop.md §4);
          // text stays the page's (into the field under the pointer)
          onDragOver={(e) => {
            const what = dragWhat(e);
            const zone = detailZone();
            if (!zone || !detailTakes(what, e.dataTransfer.types)) return;
            e.preventDefault();
            e.dataTransfer.dropEffect = 'copy';
            dragOverZone(e, zone, what, 'detail');
          }}
          onDragLeave={(e) => {
            if (!e.currentTarget.contains(e.relatedTarget as Node | null)) setDrop((d) => (d?.where === 'detail' ? null : d));
          }}
          onDrop={(e) => {
            const what = dragWhat(e);
            const zone = detailZone();
            if (!zone || !detailTakes(what, e.dataTransfer.types)) return;
            e.preventDefault();
            dropOn(e, zone, what);
          }}
        >
          {detail?.kind === 'session' && reviewHost ? (
            <ReviewPane host={reviewHost} hostKey={detail.dir} opts={{ mode: 'review', platform, theme: 'auto', lang }} rev={tick} onHandle={onPage} />
          ) : shownJob ? (
            <JobDetail job={shownJob} title={jobTitle(shownJob)} onItem={(u) => reveal(u)} onSettings={(pane) => (setScreen({ kind: 'settings' }), goSettingsPane(pane))}
              rec={recDetailOf(shownJob)} />
          ) : shownRec ? (
            <RecordingDetail rec={{ r: shownRec, agent: agentReady, handlers: recHandlers }} />
          ) : plan ? (
            <SelectionView
              items={selectedRows}
              actions={plan.acts}
              primary={plan.primary}
              blocked={plan.blocked}
              onAction={(id, el) => (id === 'hand_off' ? void handOff(selectedRows.map((i) => i.uid)) : id === 'move' ? pickProject(undefined, el) : apply(id as Action, selectedRows))}
              onMore={(el) => menu.open(plan.more, { x: 0, y: 0, anchor: el }, t('main.selection.more'))}
              onRemove={(uid) =>
                setSelected((s) => {
                  const n = new Set(s);
                  n.delete(uid);
                  return n;
                })
              }
            />
          ) : current1 && projectRow(current1.project_id)?.exists === false ? (
            // its project's folder is gone: say that, with the one way back (the generic "couldn't load" is for real
            // read errors — restarting wouldn't help here)
            <EmptyState tone="trouble" icon={<MissingFolderGlyph size={40} />} title={t('main.item.folder_missing.title')} body={t('main.item.folder_missing.detail', { a: current1.project_name })} path={projectRow(current1.project_id)?.path} testId="detail-missing">
              <button className="primary" onClick={() => locate(projectRow(current1.project_id)!)}>{t('main.missing.locate_folder')}</button>
            </EmptyState>
          ) : current1 && host ? (
            <>
              {banner && (
                <ItemBanner
                  row={current1}
                  plan={banner}
                  text={bannerText}
                  onAction={bannerAction}
                  onMore={(el) => menu.open(banner.more.map((a) => ({ label: bannerTitle(a), run: () => bannerAction(a) })), { x: 0, y: 0, anchor: el }, t('main.banner.more'))}
                />
              )}
              <ReviewPane
                host={host}
                hostKey={docItem === current1.uid ? `${current1.project_id}:${current1.uid}` : current1.project_id}
                opts={{ mode: 'item', itemId: current1.uid, platform, theme: 'auto', lang }}
                rev={tick}
                onHandle={onPage}
                onMissing={(uid) => uid === current1.uid && setDocItem(uid)}
              />
            </>
          ) : quietDetail ? null : (
            <EmptyState tone="miss" icon={<SidebarGlyph right size={30} />} title={t('main.detail.none')} body={t('main.detail.none.detail')} testId="detail-none" />
          )}
        </aside>
      )}

      {menu.node}
      {(() => {
        const label = drop && dropLabel(drop.zone, drop.what, projectName);
        return label ? (
          <div ref={dropTip} className="mw-drop-tip" role="status" style={{ transform: `translate(${dropAt.current.x + 14}px, ${dropAt.current.y + 18}px)` }}>
            {t(label.key, label.vars)}
          </div>
        ) : null;
      })()}
      <Tooltip />
      {movePop && <MovePopover projects={registered} here={movePop.here} subject={movePop.subject} anchor={movePop.anchor} onClose={() => setMovePop(null)} onPick={(p) => moveItems(movePop.uids, p)} onOpenFolder={openFolder} />}
      {newItem && (() => {
        const target = (typeof newItem === 'object' && newItem.target) || listTarget;
        return (
          <NewItemSheet
            target={target}
            prefill={typeof newItem === 'object' ? newItem : undefined}
            targetName={projectName(target)}
            onClose={() => setNewItem(false)}
            onCreated={(uid) => {
              setNewItem(false);
              refresh();
              if (uid) setTimeout(() => reveal(uid), 300);
            }}
          />
        );
      })()}
      {settingsFor && <ProjectSettingsSheet project={settingsFor} onClose={() => setSettingsFor(null)} onSave={(patch) => saveProject(settingsFor.id, patch)} />}
      {keysOpen && <Shortcuts onClose={() => setKeysOpen(false)} />}
      <AgentSetupAsk />
      <PhoneAsk />
      {palette && (
        <Palette
          entries={paletteEntries()}
          chip={
            selectedRows.length === 1 ? (
              <>
                <KindIcon kind={selectedRows[0].kind} size={13} /> <span className="mw-pal-id">{selectedRows[0].item_id}</span> {selectedRows[0].title}
              </>
            ) : selectedRows.length > 1 ? t('main.palette.chip.n', { a: i18n().formatNumber(selectedRows.length) }) : null
          }
          onClose={() => setPalette(false)}
          onItem={(r) => reveal(r.uid)}
        />
      )}
      {toast && (
        <div
          className="shell-toast mw-toast"
          role="status"
          style={{ left: toastAt }}
          data-testid="toast"
          onMouseEnter={() => clearTimeout(toastTimer.current)}
          onMouseLeave={() => {
            const id = toast.id;
            toastTimer.current = setTimeout(() => setToastState((x) => (x?.id === id ? null : x)), 2500);
          }}
        >
          {toast.mark && <span className={`mw-toast-mark ${toast.mark}`} aria-hidden="true"><Icon name={toast.mark === 'ok' ? 'check' : 'warning'} size={14} /></span>}
          <span>{toast.msg}</span>
          {toast.undo && (
            <button className="mw-toast-btn" onClick={() => { toast.undo!(); setToastState(null); }}>
              {t('action.undo')}
            </button>
          )}
          {toast.action && (
            <button className="mw-toast-btn" onClick={() => { toast.action!.run(); setToastState(null); }}>
              {toast.action.label}
            </button>
          )}
        </div>
      )}
    </div>
  );
}
