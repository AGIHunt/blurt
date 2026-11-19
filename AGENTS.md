# Working on Blurt

- **User-facing copy** (any string a user sees, in any language, on any platform): follow
  [docs/design/copy.md](docs/design/copy.md). Run `python3 tools/copy-check.py` and read every line it prints before sending a change.
  When you hand work that touches strings to another agent, include that file and the agreed terms in its brief.
- **Design docs** in docs/design say why things are the way they are, with measurements. Read the one for the area you change, and update it.
- **The phone ↔ computer wire** has three implementations kept in sync by `tests/remote-vectors/vectors.json`
  ([docs/design/remote-protocol.md](docs/design/remote-protocol.md)).
