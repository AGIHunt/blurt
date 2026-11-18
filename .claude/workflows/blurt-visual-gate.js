export const meta = {
  name: 'blurt-visual-gate',
  description: 'Visual quality gate: list every screen, screenshot it, have 3 independent judges score it against reference products, redesign anything under 8/10 and re-judge with fresh judges until it passes',
  whenToUse: 'After every round of changes and before a release: catches screens that work but look cluttered, misaligned or cheap',
  phases: [
    { title: 'Inventory', detail: 'every screen and state, shot in light/dark, zh/en' },
    { title: 'Judge', detail: '3 independent judges per screen, rubric 1-10' },
    { title: 'Redesign', detail: 'screens under 8: redesign, reshoot and re-judge with fresh judges, up to 3 rounds' },
  ],
}

// args: { base: '<sha>', out: 'promo/cases/<dir>', focus: ['settings.agents', …] (screens to put first), note: '…' }
const A = args || {}
const SP = '/private/tmp/claude-501/-Users-john-workspace-bug-agent/8c47c519-267a-43f5-a42d-afd466477cd9/scratchpad'
const REPO = '/Users/john/workspace/bug-agent'
const OUT = `${REPO}/${A.out || 'promo/cases/visual-gate'}`
const PASS = 8, MAX_ROUNDS = 3

const SAFETY = `Isolated scratch app only: ${SP}/agents/audit-base/fix.sh (ROLE=<role> REPO=<repo or worktree>; read it; BLURT_APPEARANCE=dark, QA_LANG=en|zh-Hans; seed by adapting ${SP}/agents/audit-final/seed.py; test hooks in SelfTest.swift / SelfTests.swift / *TestHooks.swift).
The user is at the machine:
- Screenshots of your own app's windows only, with GUI actions under python3 ${SP}/gui_lock.py --.
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
  id: { type: 'string' }, what: { type: 'string' }, owner_files: { type: 'array', items: { type: 'string' } },
  shots: { type: 'array', items: { type: 'string' } },
  layout_problems: { type: 'array', items: { type: 'string' }, description: 'what layoutcheck reported on this screen (each at least P2)' } },
  required: ['id', 'what', 'owner_files', 'shots', 'layout_problems'] } } }, required: ['screens'] }
const SCORE = { type: 'object', properties: { overall: { type: 'number' }, scores: { type: 'object' },
  problems: { type: 'array', items: { type: 'string' } }, redesign: { type: 'string', description: 'concrete redesign direction if overall < 8' } },
  required: ['overall', 'problems', 'redesign'] }
const BUILT = { type: 'object', properties: { worktree: { type: 'string' }, branch: { type: 'string' }, head: { type: 'string' },
  shots: { type: 'array', items: { type: 'string' } }, changes: { type: 'string' } }, required: ['worktree', 'branch', 'head', 'shots', 'changes'] }

phase('Inventory')
const inv = await agent(`List EVERY screen and state of Blurt (口喷鸡), the macOS app at ${REPO}/skills/blurt/recorder/macos, and screenshot each one in light/dark and zh/en.
Derive the list from the code, not from memory. It must include:
- every Settings pane and its states;
- the main window views (lists, item detail, Dictation page, Lab, empty states, banners);
- the island and toast states, hanging cards and their overview;
- the note bubble, the picker, the recording chrome;
- the panels (Recently Dragged Out, palette, project switcher, keyboard shortcuts);
- onboarding steps and the permission guide;
- the menu-bar menu (render it through test hooks if possible);
- alerts.
Seed a realistic world so lists are full.
${A.focus ? 'Shoot these first: ' + JSON.stringify(A.focus) + '.' : ''}
${SAFETY}
${LAYOUT}
Save the shots under ${OUT}/inventory/<screen-id>/. Return one entry per screen with the source files that own it. Build the app from ${A.base ? 'commit ' + A.base + ' (check it out read-only in a scratch git worktree)' : 'the main checkout'}; never edit the repo.`,
  { label: 'inventory', phase: 'Inventory', schema: SHOTS })

const screens = (inv && inv.screens) || []
log(`${screens.length} screens`)

const judge = (s, shots, round, k) => agent(`You are independent design judge #${k} (round ${round}) for one screen of Blurt (口喷鸡), a premium, restrained macOS app.
Read docs/design/system.md in ${REPO}.
Screen: ${s.id}, ${s.what}. Screenshots: ${JSON.stringify(shots)}. Owner files: ${JSON.stringify(s.owner_files)}.
Layout lint on this screen (each at least P2; cut off at a window edge = blocker): ${JSON.stringify(s.layout_problems || [])}.
Compare it with how Claude desktop, Linear, Raycast or macOS System Settings would present the same content. Describe the reference concretely. Use web screenshots or docs if you can find them; otherwise use your knowledge of those products.
${RUBRIC}
Be strict and specific. List each problem with where it is. If the overall score is below ${PASS}, give a concrete redesign direction: layout, what to merge, what to hide behind disclosure or hover, component choices.`,
  { label: `judge:${s.id}:r${round}:${k}`, phase: round === 0 ? 'Judge' : 'Redesign', schema: SCORE })

const panel = async (s, shots, round) => {
  const v = (await parallel([1, 2, 3].map(k => () => judge(s, shots, round, k)))).filter(Boolean)
  const avg = v.reduce((a, x) => a + x.overall, 0) / Math.max(1, v.length)
  return { avg, min: Math.min(...v.map(x => x.overall)), verdicts: v }
}

phase('Judge')
const results = await pipeline(screens,
  s => panel(s, s.shots, 0).then(p => ({ s, p })),
  async ({ s, p }) => {
    let cur = p, wt = null, round = 0, shots = s.shots
    while ((cur.avg < PASS || cur.min < PASS - 1) && round < MAX_ROUNDS) {
      round++
      const brief = cur.verdicts.map(v => `- (${v.overall}) ${v.problems.join('; ')} → ${v.redesign}`).join('\n')
      const b = await agent(`Redesign one screen of Blurt (口喷鸡) until it is excellent, as a senior macOS product designer and engineer.
${wt ? `Continue in the EXISTING worktree ${wt.worktree} (branch ${wt.branch}); cd there.` : `You are in your own git worktree. First \`git reset --hard ${A.base || 'HEAD'}\`.`}
Screen: ${s.id}, ${s.what}. Owner files: ${JSON.stringify(s.owner_files)}.
Judges' problems and directions (round ${round}):
${brief}
Keep every function. Move rare settings behind disclosure, hover or a detail view instead of deleting them.
Follow docs/design/system.md and Mac conventions. Copy must be plain, with no coined terms, in zh and en.
Then:
1. Run swift build and swift test.
2. Run uv run pytest tests -q.
3. Reshoot the screen in light/dark and zh/en to ${OUT}/redesign/${s.id}/r${round}/, and run layoutcheck on every shot (and at the
   window's minimum size): it must report nothing; fix what it reports.
4. Commit.
${SAFETY}
${LAYOUT}`,
        { label: `redesign:${s.id}:r${round}`, phase: 'Redesign', schema: BUILT, ...(wt ? {} : { isolation: 'worktree' }) })
      if (!b) break
      wt = b; shots = b.shots
      cur = await panel(s, shots, round)
    }
    log(`${s.id}: ${p.avg.toFixed(1)} → ${cur.avg.toFixed(1)} after ${round} round(s)`)
    return { id: s.id, before: p.avg, after: cur.avg, rounds: round, passed: cur.avg >= PASS && cur.min >= PASS - 1,
             branch: wt && wt.branch, worktree: wt && wt.worktree, head: wt && wt.head, last: cur.verdicts.map(v => v.problems) }
  })
return { screens: results.filter(Boolean) }
