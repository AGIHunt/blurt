export const meta = {
  name: 'blurt-dogfood',
  description: 'Use Blurt like real users: catalogue every scenario, run each domain end-to-end in an isolated app with timelines and screenshots, then judge them through three lenses',
  whenToUse: 'Before every release or after a big round of changes: find the problems a user would hit, not only the ones tests catch',
  phases: [
    { title: 'Catalogue', detail: 'every feature × entry point × state' },
    { title: 'Run', detail: 'one runner per domain, a timeline with screenshots' },
    { title: 'Judge', detail: 'flow, craft and robustness lenses per domain' },
  ],
}

// args: { base: '<sha or branch>', note: 'what changed / what is being redesigned elsewhere', out: 'promo/cases/<dir>' }
const A = args || {}
const SP = '/private/tmp/claude-501/-Users-john-workspace-bug-agent/8c47c519-267a-43f5-a42d-afd466477cd9/scratchpad'
const REPO = '/Users/john/workspace/bug-agent'
const OUT = `${REPO}/${A.out || 'promo/cases/dogfood'}`

const CONTEXT = `
Product: **Blurt (口喷鸡)**. It is an open-source Agent Skill (skills/blurt, Python scripts) plus a native macOS menu-bar app (Swift; skills/blurt/recorder/macos).
Users: the Typeless audience, vibe coders and indie developers. They want it fast, clear and recognisably Blurt, at the polish level of Claude desktop, Linear and Raycast.
Features:
- Typeless-style **dictation** (听写): press Fn → the text goes in at the cursor. Tap = hands-free, hold = push-to-talk, double-tap = Return. Local Qwen3-ASR + Gemma polish. Styles. Words list. A Dictation page.
- **Snap** (截图, ⌥⇧A) with a spoken or typed note.
- **Voice Note** (语音备注, ⌥⇧V).
- Screen **Record** (录屏, ⌥⇧R) → an agent turns it into items.
- Cards hanging under the notch (刘海), to drag or paste into other apps.
- Projects, an inbox and AI sorting.
- Hand-off to coding agents (Claude Code, Codex) in tmux sessions shown in an embedded terminal.
- The review page and export; the menu bar; onboarding; Settings.
Docs: docs/guide.md (en and zh), docs/design/*.md (system.md = the design system).
${A.note ? 'Context for this run: ' + A.note : ''}`

const SAFETY = `
Testing tools: ${SP}/agents/audit-base/fix.sh. Read it first. It builds and runs an isolated scratch copy of the app:
- \`ROLE=<role> REPO=${REPO} fix.sh build|run|stop|log|ev|shell|wins|shot|ax|x|py\`
- Env for variants: BLURT_APPEARANCE=dark, QA_LANG=en|zh-Hans, QA_HOME/QA_WS (a fresh first-run world).
- Seed a world by adapting ${SP}/agents/audit-final/seed.py to your own scratch dir.
- Test hooks are in BlurtApp SelfTest.swift, System/SelfTests.swift, Terminal/TerminalSelfTests.swift and *TestHooks.swift.
- More tools: ${SP}/agents/e2e-v07/tools (post, winlist, ax, mouse, mock agents).
- For audio, use \`say -o x.aiff\` → wav with BLURT_TEST_MIC_WAV or the dictation test hooks. Use real models, symlinked read-only from ~/.blurt/models into your scratch home.
STRICT safety (the user's real machine and real Blurt are in use):
- Never write ~/.blurt, ~/Applications/Blurt.app, ~/Blurt, ~/Desktop or ~/.claude.
- ~/.codex: only what running the codex CLI writes by itself. Never answer its update prompt with anything but Esc, so you don't change the user's settings.
- Never kill processes you didn't start.
- No real mic.
- Never post key or mouse events into other apps, and never read other apps' AX. Your own app's windows are fine, under \`python3 ${SP}/gui_lock.py -- <cmd>\`, after checking the window owner pid.
- Never touch the general clipboard.
- No localhost ports that may be the user's.
- Screenshots only of your own app's windows.
- Use tmux only on \`-L blurt-test-<role>\`.
- When done, stop everything you started and unregister scratch bundles with lsregister -u.
Real coding-agent runs are allowed only where the domain says so: a scratch git repo, a trivial task, at most one run per agent CLI.
Never edit or commit the repo. Write evidence under ${OUT}/<domain>/ (promo/ is untracked; never git add it).`

// the deterministic layout lint (BlurtApp/System/LayoutCheck.swift; tests/test_gui_layout.py runs it over every screen)
const LAYOUT = `
Layout lint, on EVERY screen you shoot (right after the shot, same state): \`fix.sh wp6 layoutcheck\`, then \`fix.sh ev layoutcheck 1\`
(for a resizable window also \`layoutcheck min\`, then \`layoutcheck restore\`: the same check at its minimum size). It lists, per visible window,
elements outside the window, under the traffic lights, controls on top of each other and truncated texts. Report every problem it
finds as an observation of severity P2 or higher (P1 when a control or its text is cut off at a window edge), with the layoutcheck
line and the screenshot as evidence; never drop one as noise. On a build without the hook, say so and check the window edges by eye.`

const SCEN = { type: 'object', properties: { domains: { type: 'array', items: { type: 'object', properties: {
  key: { type: 'string' }, scenarios: { type: 'array', items: { type: 'string' } } }, required: ['key', 'scenarios'] } } }, required: ['domains'] }

const RUN = { type: 'object', properties: {
  timeline: { type: 'string', description: `path of ${OUT}/<domain>/timeline.md: per scenario, every step with what the user sees (screenshot path), how long it took, and what the user would think` },
  observations: { type: 'array', items: { type: 'object', properties: {
    scenario: { type: 'string' }, what: { type: 'string' }, evidence: { type: 'string' }, severity: { enum: ['P0', 'P1', 'P2', 'P3'] } }, required: ['scenario', 'what', 'evidence', 'severity'] } },
  not_run: { type: 'array', items: { type: 'string' } },
}, required: ['timeline', 'observations', 'not_run'] }

const FIND = { type: 'object', properties: { findings: { type: 'array', items: { type: 'object', properties: {
  severity: { enum: ['P0', 'P1', 'P2', 'P3'] }, title: { type: 'string' }, user_impact: { type: 'string' }, evidence: { type: 'string' },
  where: { type: 'string', description: 'file:line or surface' }, fix: { type: 'string' }, needs_user_decision: { type: 'boolean' } },
  required: ['severity', 'title', 'user_impact', 'evidence', 'where', 'fix', 'needs_user_decision'] } } }, required: ['findings'] }

const DOMAINS = {
  dictation: 'Dictation end to end. Cover each of these:\n- First use, and the key in every mode, including double-tap Return in a real chat-like text field of your own test pad.\n- What the user sees at every moment while talking: live text, island states, the mascot. Compare with Typeless and Wispr Flow. Does the user always know what was heard before they double-tap to send?\n- Long takes, pauses, mixed zh/en, and styles (⇧, ⌥⇧L).\n- Words list, learning, the Dictation page and history.\n- Errors: no model, slow model, polish timeout.\n- Latency at every step.',
  capture: 'Snap, Voice Note and Record from start to card. Cover each of these:\n- The note bubble and the picker.\n- The island in every state, and the hanging cards with 1, 5 and 12 cards.\n- Copy, paste and drag-out: verify the payloads per target class via the test hooks.\n- Recently Dragged Out, undo paths, and cancel/Esc paths.\n- Multi-display assumptions, from code.\n- Light/dark and zh/en.',
  work: 'Items, projects, inbox, AI sort, the main window, and the original screen-recording → items pipeline, using the fixtures in tests/fixtures. Also the review page and export.\nHand-off to coding agents:\n- Dispatch a REAL Codex session and a REAL Claude Code session, once each, from your scratch app, on a scratch git repo, with a trivial task ("create hello.txt containing hi, then mark the item fixed").\n- Watch them in the embedded terminal: visible window, pointer over it.\n- Follow them through status, Open Session, finish, merge and discard.\nThe user just hit "Error: timed out discarding buffered terminal input": a Codex 0.157 session exited at startup. The error comes from codex-rs tui/src/tui/input_boundary.rs: before an interactive startup screen (update or trust prompt), Codex drains terminal input and fails if a partial control sequence stays unresolved for 1 s.\n- Find what in our path produces it: the embedded SwiftTerm (allowMouseReporting, focus events), tmux options in $BLURT_HOME/tmux.conf, the attach timing, the -c hooks/MCP args, or the prompt delivery.\n- Reproduce it, and say exactly which fix would remove it, e.g. -c check_for_update_on_startup=false, or pre-trusting worktrees of projects the user already trusts in ~/.codex/config.toml (read-only).\n- Also check what the user sees when any agent CLI exits early: is it explained, is there a retry?',
  shell: 'First run, from install to onboarding, permissions, the menu-bar icon and menu, Settings (every pane), updates, storage, help and quit/relaunch.\n- What happens on a reboot or login, or when permissions are revoked mid-use.\n- Note: the onboarding mascot and the Settings layout are being redesigned in parallel. Judge their function and flows; do not report their old visual design.',
}

phase('Catalogue')
const cat = await agent(CONTEXT + `
Build the scenario catalogue (the inventory: include one "layoutcheck" scenario per window and state, in zh and en and at the
window's minimum size; the runners run the layout lint on every screen they shoot): every user-facing feature × every way to start it (menu, hotkey, island, main window, palette, URL, CLI) × the states that matter (first time, empty, many, slow, failure, offline, permission missing, light/dark, zh/en).
Derive it from the code (menus, hotkeys, Settings rows, test hooks, URL routes, CLI commands), docs/guide.md and SKILL.md, not from memory.
Group the scenarios into these domains: ${Object.keys(DOMAINS).join(', ')}.
Write the full catalogue to ${OUT}/scenarios.md, and return it. Keep each scenario to one line, concrete and checkable, about 25–60 per domain.
Read-only on the repo.`, { label: 'catalogue', phase: 'Catalogue', schema: SCEN })

const LENSES = [
  { key: 'flow', prompt: 'FLOW lens. Check:\n- At every moment, does the user know what is happening and what to do next?\n- Is the path the shortest it could be, with no dead ends or silent failures?\n- Is it as good as the best competitor for this job (Typeless or Wispr Flow for dictation, CleanShot X for snaps, Claude desktop or Raycast for windows and settings, Linear for lists)?' },
  { key: 'craft', prompt: 'CRAFT lens. Check:\n- One recognisable brand everywhere: one chick (the 4A line chick), the mint/gradient tokens from docs/design/system.md used where they mean something.\n- Icon quality: no coarse or oversized generic glyphs. Judge each icon SET as a family (item kinds, states, toolbar, sidebar): same grid, stroke weight, optical size, level of detail and metaphor style. A set where one icon is filled and dense while the others are thin, or where SF Symbols are mixed with custom drawings, is a finding.\n- Raw internals shown to people are a finding: bundle ids (com.apple.TextEdit), file paths, uids, pids, exit codes, JSON keys, enum raw values, model ids. Read every label in every screenshot with this in mind.\n- Copy: plain words people already use. No coined terms or rare phrasings (e.g. 「挂成卡片」 or 「不归项目」 where 「未归类」 is the app\'s own word). One term for one concept across the app.\n- Alignment, spacing, typography and truncation, in light/dark and zh/en.\n- Motion that is premium, not flashy.\n- Copy that is short and natural.\n- Micro-interactions, as a Mac user expects them:\n  - Edit in place, not in a dialog: renaming, titles, notes, project names.\n  - Undo instead of confirm wherever data is recoverable.\n  - Double-click and Return to edit; Esc to cancel; click away to commit.\n  - Keyboard paths for every action; focus rings; hover states.\n  - Optimistic updates; no spinners for instant things.\n  - Drag to reorder where order matters.\n  - Inline validation; sensible default focus; no modal where a popover or inline row would do; no redundant confirmations.\n- BLOCKER: anything cut off at a window edge (a button, text or control partly outside its window, or under the traffic lights) is a\n  blocker: P1 at least, never accepted as polish. Check all four edges of every screenshot, and the runner\'s layoutcheck observations.' },
  { key: 'robust', prompt: 'ROBUSTNESS lens. Check:\n- Races, slow or failed external tools (models, uv, tmux, codex/claude CLIs, git), restarts, and stale data.\n- Recovery: undo, retry, clear errors.\n- Data loss, and resource use over time.\n- For each P0/P1, give the root cause from the code.' },
]

const keys = Object.keys(DOMAINS)
const out = await pipeline(keys,
  k => {
    const sc = ((cat && cat.domains) || []).find(d => d.key === k)
    return agent(CONTEXT + SAFETY + LAYOUT + `
## You are the ${k.toUpperCase()} runner (ROLE=df${k})
Use Blurt like a real user would, scenario by scenario. Build the app once with fix.sh, seed a realistic world, and run each scenario for real.
- Screenshot every step that the user would look at.
- Time each step that the user would wait on.
- Write down what a demanding user would think at that moment.
- Run layoutcheck on every screen you shoot (see Layout lint above).
- Don't stop at "it works": note every moment of confusion, waiting without feedback, inconsistency, roughness or failure.
Domain focus:
${DOMAINS[k]}
Scenarios from the catalogue: ${JSON.stringify(sc ? sc.scenarios : [])}
Add any scenario you discover that is missing from the catalogue.
Write the timeline to ${OUT}/${k}/timeline.md, with screenshots under ${OUT}/${k}/shots/. Return your observations.`,
      { label: 'run:' + k, phase: 'Run', schema: RUN })
  },
  (run, k) => run && parallel(LENSES.map(l => () => agent(CONTEXT + SAFETY + LAYOUT + `
## You are an independent judge, ${l.key.toUpperCase()} lens, for the ${k} domain (ROLE=dj${k}${l.key})
${l.prompt}
Read the runner's timeline ${run.timeline} and look at its screenshots. Read the code behind what you see.
Re-run any step you doubt in your own scratch app.
The runner's observations, which you may confirm, reject or deepen: ${JSON.stringify(run.observations)}
Not run by the runner: ${JSON.stringify(run.not_run)}
Rubric for every lens: anything cut off at a window edge is a blocker (P1 at least), and every layoutcheck problem is at least P2.
Report findings only through your lens, verified and concrete, each with a precise fix. Mark needs_user_decision for product calls.`,
    { label: `judge:${k}:${l.key}`, phase: 'Judge', schema: FIND }).then(f => f && f.findings.map(x => ({ ...x, domain: k, lens: l.key })))))
    .then(fs => ({ domain: k, timeline: run.timeline, not_run: run.not_run, findings: fs.filter(Boolean).flat() })),
)
return { catalogue: `${OUT}/scenarios.md`, domains: out.filter(Boolean) }
