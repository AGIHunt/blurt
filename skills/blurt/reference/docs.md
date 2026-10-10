# From recordings to a document

Some recordings aren't a list of things to file — they are the raw material for one document: a requirements doc and
a design doc after browsing reference sites, a competitor teardown, a brief for a redesign. The user walks through
what they see ("这个首屏好", circles it, "我们也要这样") and expects something they can start building from.

Do §2–§5 as usual first: the items are the evidence, and the review is where the user corrects what you misheard.
Then write the document(s) from the **kept** items.

- **Where:** `<session>/docs/<name>.md`. Several recordings feeding one document (dozens of sites over a few days):
  `.blurt/docs/<topic>/`, citing items as `<session>/<id>`.
- **Every statement traces back.** After each requirement / decision put the item ids it came from, and embed the
  frame the user marked (`![…](../frames/D-003-1.jpg)`) — the picture is half the spec.
- **Separate what they said from what you added.** Gaps are worth filling (a footer, an empty state, a non-goal), but
  label them (补充 / added) so they are easy to strike. Never upgrade a passing remark into a hard requirement.
- **Merge, then rank.** The same wish voiced on three sites is one requirement with three references. Contradictions
  ("深色好看" … "还是用浅色") are resolved by the later statement and noted, or raised as a question.
- **Keep the open questions.** Unanswered `questions` from the items go into a "to decide" section; don't guess.
- **Use the repo.** Inside a project, ground the document in what exists: real names, colours, commands, constraints.

Typical shapes (adapt; the user's own template wins):
- *Requirements:* goal · who it is for · requirements (statement, source items, frame, acceptance, open points) ·
  non-functional · out of scope · to decide.
- *Design:* structure / wireframe · visual language (tokens, type) with the reference frames · components and their
  states · implementation notes · open points that would change the design · build order.

Afterwards offer the next step: "want me to start building from this?"
