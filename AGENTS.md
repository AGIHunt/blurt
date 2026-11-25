# Working on Blurt

- **User-facing copy** (any string a user sees, in any language, on any platform): follow
  [docs/design/copy.md](docs/design/copy.md). Run `python3 tools/copy-check.py` and read every line it prints before sending a change.
  When you hand work that touches strings to another agent, include that file and the agreed terms in its brief.
  Write the way macOS, the iPhone and Figma do: plain, short, ordinary words, nothing a reader has to stop and work out.
- **The copy judge**: the agent that writes copy never passes it. Before a pull request that adds or rewords strings, a separate subagent
  ([.claude/agents/copy-judge.md](.claude/agents/copy-judge.md)) reads every one; fix what it reports and give the result to a new judge, until
  none finds a serious problem. Then list every change, old and new, for the founder to review before it merges
  ([docs/design/copy.md](docs/design/copy.md), The judge).
- **Design docs** in docs/design say why things are the way they are, with measurements. Read the one for the area you change, and update it.
- **The phone ↔ computer wire** has three implementations kept in sync by `tests/remote-vectors/vectors.json`
  ([docs/design/remote-protocol.md](docs/design/remote-protocol.md)).
