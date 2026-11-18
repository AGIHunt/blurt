// Settings → Agents → Dragging Cards → Edit… (the Mac's AgentAppsSheet): the apps a dragged card carries the
// picture's path and the note into, as a terminal gets them — one list with the agents Blurt connects (agents.json
// `drop`, card_drop.rs drop_rows), each with a switch (record.agent_drop.<id> = false: off), and the programs the
// user added (custom agents in record.agent_defs), each with Remove; Add Program… picks any program (island.rs
// agent_apps_pick). A list, not rules on names: a name doesn't say whether a program reads local files (Kimi /
// Kimi Code, 豆包 / 豆包工作).
import { useCallback, useEffect, useState } from 'react';
import { api, type AgentApp } from '../api';
import { Group, Line, S, Switch, lang } from '../settings/kit';
import { Sheet } from './AgentsSettings';

export function AgentAppsSheet({ close }: { close: () => void }) {
  const [rows, setRows] = useState<AgentApp[] | null>(null);
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    api.agentApps().then(setRows, () => setRows([]));
  }, []);
  const set = (id: string, op: 'on' | 'off' | 'remove') => api.setAgentApp(id, op).then(setRows, () => {});
  const add = async () => {
    setBusy(true);
    try {
      const r = await api.pickAgentApps(S('settings.general.agent_apps.add_title'));
      for (const id of r.ids ?? []) setRows(await api.setAgentApp(id, 'add'));
    } catch {
      // the dialog failed to open or the config couldn't be written: the list stays as it was
    }
    setBusy(false);
  };
  const done = useCallback(() => !busy && close(), [busy, close]);
  // the user's own first, then the others, each by name (the Mac's order)
  const byName = (a: AgentApp, b: AgentApp) => a.name.localeCompare(b.name, lang(), { sensitivity: 'base' });
  const list = rows ? [...rows.filter((r) => r.custom).sort(byName), ...rows.filter((r) => !r.custom).sort(byName)] : [];
  return (
    <Sheet label={S('settings.general.agent_apps.title')} close={done} width={480}>
      <div data-testid="agent-apps-sheet">
        <div className="st-sheet-title">{S('settings.general.agent_apps.title')}</div>
        <div className="st-detail">{S('settings.general.agent_apps.note')}</div>
        {/* the list scrolls, Add Program… and Done stay in view (the Mac's 320 pt list) */}
        <div style={{ maxHeight: 'min(320px, 50vh)', overflowY: 'auto' }}>
          <Group id="agentApps">
            {list.map((a) => (
              <Line key={a.id} title={a.name}>
                {a.custom ? (
                  <button onClick={() => set(a.id, 'remove')}>{S('settings.general.agent_apps.remove')}</button>
                ) : (
                  <Switch on={a.on} label={a.name} set={(v) => set(a.id, v ? 'on' : 'off')} />
                )}
              </Line>
            ))}
          </Group>
        </div>
        <div className="st-ctl st-sheet-foot" style={{ justifyContent: 'space-between' }}>
          <button disabled={busy} onClick={add}>{S('settings.general.agent_apps.add')}</button>
          <button className="primary" disabled={busy} onClick={close}>{S('settings.general.agent_apps.done')}</button>
        </div>
      </div>
    </Sheet>
  );
}
