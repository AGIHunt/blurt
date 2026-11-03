// "Allow an app on your PC to set up models?" (control.rs `ask`): an agent asked, on the control endpoint, to connect
// services and choose models for 30 minutes. Blurt's own confirm sheet in the main window — the Clear History one
// (.dict-confirm: light or dark with the app, centred, Windows' ContentDialog band) — not Windows' light box, which
// made Allow the default. Here Don't Allow is the focused default and neither Enter nor Esc can allow: the user may be
// typing in the agent's terminal when it comes up, so only a click on Allow does (the Mac's: Return must not allow).
// Esc and a click outside answer Don't Allow. The app's icon names who asks. When the wait runs out Rust closes it,
// and a click after that answers nothing.
import { useEffect, useState } from 'react';
import appIcon from '@blurt/ui/app-icon.png';
import { invoke, listen } from '../api';

type Ask = { id: number; title: string; detail: string; allow: string; deny: string };

export function AgentSetupAsk() {
  const [ask, setAsk] = useState<Ask | null>(null);
  useEffect(() => {
    const offs = [
      listen<Ask>('agent-setup://ask', (a) => {
        setAsk(a);
        void invoke('agent_setup_answer', { id: a.id, allow: null }).catch(() => {});
      }),
      listen<{ id: number }>('agent-setup://ask-close', (p) => setAsk((a) => (a && a.id === p.id ? null : a))),
    ];
    return () => offs.forEach((o) => o());
  }, []);
  if (!ask) return null;
  const answer = (allow: boolean) => {
    void invoke('agent_setup_answer', { id: ask.id, allow }).catch(() => {});
    setAsk(null);
  };
  return (
    <div className="overlay" onClick={() => answer(false)}>
      <div className="sheet dict-confirm agent-ask" role="alertdialog" aria-modal="true" aria-labelledby="agent-ask-title" onClick={(e) => e.stopPropagation()}
        onKeyDown={(e) => {
          // Return never allows: Return and Esc both say no
          if (e.key === 'Enter' || e.key === 'Escape') {
            e.preventDefault();
            answer(false);
          }
        }}>
        <div className="agent-ask-head">
          <img className="agent-ask-icon" src={appIcon} alt="" width={40} height={40} />
          <h3 id="agent-ask-title">{ask.title}</h3>
        </div>
        <p>{ask.detail}</p>
        <div className="dict-confirm-foot">
          <button autoFocus className="dict-confirm-cancel" onClick={() => answer(false)}>{ask.deny}</button>
          <button className="primary" onClick={(e) => (e.detail > 0 ? answer(true) : undefined)}>{ask.allow}</button>
        </div>
      </div>
    </div>
  );
}
