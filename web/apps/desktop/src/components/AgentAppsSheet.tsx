// Settings → General → Cards → "Dragging a card into an agent" → Agents… (Windows; the Mac's AgentAppsSheet): which
// programs are agents that get the picture's path and the note, as a terminal does (card_drop.rs AGENTS). The
// built-in list, each with a switch (record.agent_apps: one switched off is stored as false), and the programs the
// user added (stored as true), each with Remove; Add Program… picks any program (island.rs agent_apps_pick). A list,
// not rules on names: a name doesn't say whether a program reads this PC's files (Kimi / Kimi Code, 豆包 / 豆包工作).
// The rows come from Rust (agent_apps_get / _set), so the built-in list lives in one place.
import { useCallback, useEffect, useState } from 'react';
import { api, type AgentApp } from '../api';
import { Group, Line, S, Switch, lang } from '../settings/kit';
import { Sheet } from './AgentsSettings';

/** The built-ins' names (ids are executable stems); a program the user added shows its stem. */
const NAMES: Record<string, string> = {
  workbuddy: 'WorkBuddy', qoderwork: 'QoderWork', qoder: 'Qoder', 'kimi code': 'Kimi Code', doubaowork: '豆包工作 DoubaoWork',
  cursor: 'Cursor', windsurf: 'Windsurf', trae: 'Trae', 'trae cn': 'Trae CN', antigravity: 'Antigravity', kiro: 'Kiro', codex: 'Codex',
};
export const agentAppName = (id: string) => NAMES[id] ?? id;

export function AgentAppsSheet({ close }: { close: () => void }) {
  const [rows, setRows] = useState<AgentApp[] | null>(null);
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    api.agentApps().then(setRows, () => setRows([]));
  }, []);
  const set = (id: string, on: boolean) => api.setAgentApp(id, on).then(setRows, () => {});
  const add = async () => {
    setBusy(true);
    try {
      const r = await api.pickAgentApps(S('settings.general.agent_apps.add_title'));
      for (const id of r.ids ?? []) setRows(await api.setAgentApp(id, true));
    } catch {
      // the dialog failed to open or the config couldn't be written: the list stays as it was
    }
    setBusy(false);
  };
  const done = useCallback(() => !busy && close(), [busy, close]);
  // the user's own first, then the built-ins, each by name (the Mac's order)
  const byName = (a: AgentApp, b: AgentApp) => agentAppName(a.id).localeCompare(agentAppName(b.id), lang(), { sensitivity: 'base' });
  const list = rows ? [...rows.filter((r) => !r.builtin).sort(byName), ...rows.filter((r) => r.builtin).sort(byName)] : [];
  return (
    <Sheet label={S('settings.general.agent_apps.title')} close={done} width={480}>
      <div data-testid="agent-apps-sheet">
        <div className="st-sheet-title">{S('settings.general.agent_apps.title')}</div>
        <div className="st-detail">{S('settings.general.agent_apps.note')}</div>
        {/* the list scrolls, Add Program… and Done stay in view (the Mac's 320 pt list) */}
        <div style={{ maxHeight: 'min(320px, 50vh)', overflowY: 'auto' }}>
          <Group id="agentApps">
            {list.map((a) => (
              <Line key={a.id} title={agentAppName(a.id)}>
                {a.builtin ? (
                  <Switch on={a.on} label={agentAppName(a.id)} set={(v) => set(a.id, v)} />
                ) : (
                  <button onClick={() => set(a.id, false)}>{S('settings.general.agent_apps.remove')}</button>
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
