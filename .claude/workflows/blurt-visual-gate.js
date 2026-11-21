export const meta = {
  name: 'blurt-visual-gate',
  description: 'Visual quality gate: shoot the screens in scope, 2 judges each (a third when they disagree) against reference products, retake shots that miss their state, one redesigner per page for anything under 8/10, re-judged up to 2 rounds',
  whenToUse: 'After every round of changes and before a release: catches screens that work but look cluttered, misaligned or cheap',
  phases: [
    { title: 'Inventory', detail: 'every screen and state, shot in light/dark, zh/en' },
    { title: 'Judge', detail: '2 judges per screen (3 on disagreement), rubric 1-10; missed shots retaken' },
    { title: 'Redesign', detail: 'pages with a screen under 8: one redesigner per page, re-judged by fresh judges, up to 2 rounds' },
  ],
}

// args: { repo: '<worktree to build and judge; default this repo>', out: 'promo/cases/<dir>', base: '<commit to build>',
//         only: ['settings.remote', 'viewer', …] (screen-id prefixes: ONLY these are shot and judged; give it for a release gate),
//         focus: [...] (shot first), note: '…', sp: '<scratchpad>', harness: '<text replacing the fix.sh harness lines when they are gone>' }
// Lessons from the 1.1 run (169 screens, ~850 agents, mostly unmergeable): scope is enforced in code, a shot that misses its state is
// reshot instead of redesigned, and a page is redesigned by ONE agent covering all its failing states (per-state redesigners rewrote
// the same file 15 different ways).
const A = typeof args === 'string' ? { note: args } : (args || {})
const SP = A.sp || '/private/tmp/claude-501/-Users-john-workspace-bug-agent/8c47c519-267a-43f5-a42d-afd466477cd9/scratchpad'
const REPO = A.repo || '/Users/john/workspace/bug-agent'
// evidence stays in this repo's untracked promo/, whichever worktree is judged
const OUT = `/Users/john/workspace/bug-agent/${A.out || 'promo/cases/visual-gate'}`
const PASS = 8, MAX_ROUNDS = 2
const ONLY = A.only || null
const inScope = id => !ONLY || ONLY.some(p => id === p || id.startsWith(p + '.'))

const SAFETY = `${A.harness ? 'Repo under test: ' + REPO + ' (build and run THIS tree).\n' + A.harness + '\n' : `Isolated scratch app only: ${SP}/agents/audit-base/fix.sh (ROLE=<role> REPO=<repo or worktree>; read it; BLURT_APPEARANCE=dark, QA_LANG=en|zh-Hans; seed by adapting ${SP}/agents/audit-final/seed.py; test hooks in SelfTest.swift / SelfTests.swift / *TestHooks.swift).
`}The user is at the machine:
- Screenshots of your own app's windows only${A.harness ? ', one GUI action at a time' : ', with GUI actions under python3 ' + SP + '/gui_lock.py --'}.
- No full-screen overlays longer than 3 s.
- No real mic, no clipboard, no events into other apps.
- Never write ~/.blurt, ~/Blurt or ~/Applications/Blurt.app.
- Stop what you start.`

// the deterministic layout lint (BlurtApp/System/LayoutCheck.swift; tests/test_gui_layout.py runs it over every screen)
const LAYOUT = `Layout lint, on EVERY screen you shoot (right after the shot, same state): \`fix.sh wp6 layoutcheck\`, then \`fix.sh ev layoutcheck 1\`
(for a resizable window also \`layoutcheck min\`, then \`layoutcheck restore\`: the same check at its minimum size). The answer lists, per visible
window, elements outside the window, under the traffic lights, controls on top of each other and truncated texts. Every problem it reports
is at least P2: put it in that screen's layout_problems (kind, window, role, label, frame) and never drop it as noise. On a build without
the hook, say so and check the window edges by eye. Whole-app sweep: \`BLURT_GUI_TESTS=1 uv run pytest tests/test_gui_layout.py -q -s\`.`

const RUBRIC = `Rubric (score each 1–10, then an overall 1–10; 8 = "would ship in Claude desktop / Linear / Raycast"):
- hierarchy: one clear focus; title > section > row > secondary.
- alignment & grid: columns line up across rows; consistent insets.
- density & whitespace: no wall of controls; at most ~2 controls per row visible at rest; secondary actions on hover or in a menu.
- control economy: no repeated controls that could be one shared setting; nothing shown that the user rarely needs (disclose it).
- consistency: the same component looks the same everywhere (rows, buttons, badges, pickers).
- typography: sizes and weights carry meaning; no orphan lines; no truncation.
- colour discipline: per docs/design/system.md; brand colour only where it means something; status colours consistent.
- clarity of labels: plain words, no unexplained badges.
- polish: crisp icons, no stray separators, balanced spacing, a premium feel.
BLOCKER: anything cut off at a window edge is a blocker (a button, text or control partly outside its window, or under the
title bar's traffic lights): overall at most 5 until it is fixed, whatever else is good. Look at all four edges of every shot, and
treat every layout_problems entry as confirmed unless the screenshot proves it wrong.`

const SHOTS = { type: 'object', properties: { screens: { type: 'array', items: { type: 'object', properties: {
  id: { type: 'string' }, what: { type: 'string' },
  page: { type: 'string', description: 'the view file that renders it; every state of one page gets the same value' },
  owner_files: { type: 'array', items: { type: 'string' } },
  shots: { type: 'array', items: { type: 'string' } },
  layout_problems: { type: 'array', items: { type: 'string' }, description: 'what layoutcheck reported on this screen (each at least P2)' } },
  required: ['id', 'what', 'page', 'owner_files', 'shots', 'layout_problems'] } } }, required: ['screens'] }
const SCORE = { type: 'object', properties: {
  shows_state: { type: 'boolean', description: 'false when the shots do not show the screen/state under review (a capture problem): then score nothing else' },
  overall: { type: 'number' }, scores: { type: 'object' },
  problems: { type: 'array', items: { type: 'string' } }, redesign: { type: 'string', description: 'concrete redesign direction if overall < 8' } },
  required: ['shows_state', 'overall', 'problems', 'redesign'] }
const BUILT = { type: 'object', properties: { worktree: { type: 'string' }, branch: { type: 'string' }, head: { type: 'string' },
  shots: { type: 'object', description: 'screen id → its new shots', additionalProperties: { type: 'array', items: { type: 'string' } } },
  changes: { type: 'string' } }, required: ['worktree', 'branch', 'head', 'shots', 'changes'] }
const RESHOT = { type: 'object', properties: { shots: { type: 'array', items: { type: 'string' } }, shows_state: { type: 'boolean' },
  layout_problems: { type: 'array', items: { type: 'string' } }, why: { type: 'string' } }, required: ['shots', 'shows_state', 'layout_problems', 'why'] }

phase('Inventory')
const inv = await agent(`${ONLY ? `List the screens and states of Blurt (口喷鸡), the macOS app at ${REPO}/skills/blurt/recorder/macos, whose id starts with one of ${JSON.stringify(ONLY)} — ONLY those — and screenshot each one in light/dark and zh/en.` : `List EVERY screen and state of Blurt (口喷鸡), the macOS app at ${REPO}/skills/blurt/recorder/macos, and screenshot each one in light/dark and zh/en.
It must include every Settings pane and its states, the main window views (lists, item detail, Dictation page, Lab, empty states, banners),
the island and toast states, hanging cards and their overview, the note bubble, the picker, the recording chrome, the panels (Recently Dragged Out,
palette, project switcher, keyboard shortcuts), onboarding steps and the permission guide, the menu-bar menu (via test hooks if possible), and alerts.`}
Derive the list from the code, not from memory. Seed a realistic world so lists are full.
Look at every shot before you list it: it must show the state it is named for (the popover open, the alert up, the hover on). Retake it until it does, or leave the screen out and say why in its what.
${A.focus ? 'Shoot these first: ' + JSON.stringify(A.focus) + '.' : ''}
${A.note || ''}
${SAFETY}
${LAYOUT}
Save the shots under ${OUT}/inventory/<screen-id>/. Return one entry per screen with its page and the source files that own it. Build the app from ${A.base ? 'commit ' + A.base + ' (check it out read-only in a scratch git worktree)' : 'the main checkout'}; never edit the repo.`,
  { label: 'inventory', phase: 'Inventory', schema: SHOTS })

const all = (inv && inv.screens) || []
const screens = all.filter(s => inScope(s.id))
if (screens.length < all.length) log(`dropped ${all.length - screens.length} screens outside ${JSON.stringify(ONLY)}: ${all.filter(s => !inScope(s.id)).map(s => s.id).join(', ')}`)
log(`${screens.length} screens`)

const judge = (s, shots, round, k) => agent(`You are independent design judge #${k} (round ${round}) for one screen of Blurt (口喷鸡), a premium, restrained macOS app.
Read docs/design/system.md in ${REPO}.
Screen: ${s.id}, ${s.what}. Screenshots: ${JSON.stringify(shots)}. Owner files: ${JSON.stringify(s.owner_files)}.
First: do the shots show this screen in this state? If not, set shows_state=false, overall 0, one problem saying what the shots show instead, and stop.
Layout lint on this screen (each at least P2; cut off at a window edge = blocker): ${JSON.stringify(s.layout_problems || [])}.
Compare it with how Claude desktop, Linear, Raycast or macOS System Settings would present the same content. Describe the reference concretely, from your knowledge of those products.
${RUBRIC}
Be strict and specific. List each problem with where it is, real defects first. If the overall score is below ${PASS}, give a concrete, modest redesign direction: layout, what to merge, what to hide behind disclosure or hover, component choices.`,
  { label: `judge:${s.id}:r${round}:${k}`, phase: round === 0 ? 'Judge' : 'Redesign', schema: SCORE })

// two judges; a third only when they disagree by 2 or more
const panel = async (s, shots, round) => {
  let v = (await parallel([1, 2].map(k => () => judge(s, shots, round, k)))).filter(Boolean)
  if (v.length === 2 && v[0].shows_state && v[1].shows_state && Math.abs(v[0].overall - v[1].overall) >= 2) {
    const third = await judge(s, shots, round, 3)
    if (third) v.push(third)
  }
  const shown = v.filter(x => x.shows_state)
  const missed = shown.length * 2 < v.length || !shown.length
  const avg = shown.reduce((a, x) => a + x.overall, 0) / Math.max(1, shown.length)
  return { missed, avg, min: shown.length ? Math.min(...shown.map(x => x.overall)) : 0, verdicts: shown, all: v }
}
const fails = p => !p.missed && (p.avg < PASS || p.min < PASS - 1)

phase('Judge')
// judge each screen; a shot that missed its state is retaken once, then judged again
const judged = await pipeline(screens,
  s => panel(s, s.shots, 0),
  async (p, s) => {
    if (!p.missed) return { s, p }
    const r = await agent(`The visual gate's judges say these shots of Blurt's screen ${s.id} (${s.what}) don't show that state: ${JSON.stringify(p.all.map(x => x.problems[0]))}.
Shots: ${JSON.stringify(s.shots)}. Retake them so they show it, in light/dark and zh/en, to ${OUT}/inventory/${s.id}/retake/, and run layoutcheck on each. If the state can't be reached in a test build, say why and set shows_state=false.
${SAFETY}
${LAYOUT}
Build from ${A.base ? 'commit ' + A.base + ' in a scratch git worktree' : 'the main checkout'}; never edit the repo.`, { label: `reshoot:${s.id}`, phase: 'Judge', schema: RESHOT })
    if (!r || !r.shows_state) return { s, p, capture_failed: (r && r.why) || 'shots never showed the state' }
    const s2 = { ...s, shots: r.shots, layout_problems: r.layout_problems }
    return { s: s2, p: await panel(s2, r.shots, 0) }
  })

// one redesigner per page, covering every failing state of that page
const pages = {}
for (const j of judged.filter(Boolean)) if (!j.capture_failed && fails(j.p)) (pages[j.s.page] = pages[j.s.page] || []).push(j)
log(`${Object.keys(pages).length} pages to redesign: ${Object.entries(pages).map(([k, v]) => `${k.split('/').pop()} (${v.length})`).join(', ')}`)

phase('Redesign')
const redesigned = await pipeline(Object.entries(pages), async ([page, items]) => {
  let wt = null, round = 0, cur = items
  while (cur.length && round < MAX_ROUNDS) {
    round++
    const brief = cur.map(({ s, p }) => `## ${s.id}: ${s.what} (avg ${p.avg.toFixed(1)})\nOwner files: ${JSON.stringify(s.owner_files)}\n` +
      p.verdicts.map(v => `- (${v.overall}) ${v.problems.join('; ')} → ${v.redesign}`).join('\n')).join('\n\n')
    const b = await agent(`Improve one page of Blurt (口喷鸡), ${page}, as a senior macOS product designer and engineer: ONE coherent design for all its states below, not a different look per state.
${wt ? `Continue in the EXISTING worktree ${wt.worktree} (branch ${wt.branch}); cd there.` : `You are in your own git worktree. First \`git reset --hard ${A.base || 'HEAD'}\`.`}
Judges' problems and directions (round ${round}):
${brief}
Fix, in order: real defects (cut off, overlapping, unreadable, wrong or misleading state, inconsistent wording); then problems two judges agree on, with modest changes. Skip one judge's taste notes, big restructures and new features. Keep every function; move rare settings behind disclosure, hover or a detail view instead of deleting them.
Follow docs/design/system.md and docs/design/copy.md and Mac conventions. Copy must be plain, with no coined terms, in zh and en. Touch only this page's files and its strings.
Then:
1. Run swift build and the swift tests for the files you touched.
2. Run uv run pytest tests -q -k "l10n or strings or icons".
3. Reshoot every state above in light/dark and zh/en to ${OUT}/redesign/<screen-id>/r${round}/, and run layoutcheck on every shot (and at the window's minimum size): it must report nothing; fix what it reports.
4. Commit.
${A.note || ''}
${SAFETY}
${LAYOUT}`,
      { label: `redesign:${page.split('/').pop()}:r${round}`, phase: 'Redesign', schema: BUILT, ...(wt ? {} : { isolation: 'worktree' }) })
    if (!b) break
    wt = b
    const again = await parallel(cur.map(({ s }) => () => panel(s, (b.shots && b.shots[s.id]) || s.shots, round).then(p => ({ s, p }))))
    cur = again.filter(Boolean).filter(j => fails(j.p) || j.p.missed)
  }
  log(`${page.split('/').pop()}: ${items.length} state(s), ${cur.length} still under ${PASS} after ${round} round(s)`)
  return { page, states: items.map(j => j.s.id), before: items.map(j => +j.p.avg.toFixed(1)), still_failing: cur.map(j => ({ id: j.s.id, avg: +j.p.avg.toFixed(1), problems: j.p.verdicts.map(v => v.problems) })),
           rounds: round, branch: wt && wt.branch, worktree: wt && wt.worktree, head: wt && wt.head, changes: wt && wt.changes }
})
const ok = judged.filter(Boolean)
return { passed: ok.filter(j => !j.capture_failed && !fails(j.p)).map(j => ({ id: j.s.id, avg: +j.p.avg.toFixed(1) })),
         capture_failed: ok.filter(j => j.capture_failed).map(j => ({ id: j.s.id, why: j.capture_failed })),
         pages: redesigned.filter(Boolean) }
