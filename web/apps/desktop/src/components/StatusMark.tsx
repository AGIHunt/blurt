// The status mark of an agent session (the Mac's SessionStatusMark, TerminalStyle.swift): one shape per state, readable
// without colour — a turning arc while the agent works; an attention ring around a dot whenever it's the user's move
// (it breathes twice when it becomes so); an ok disc with a check once merged or a pull request is open; an error disc
// with "×" when it failed (never a bare red dot: that is the recording dot); a hollow ring once it's over with nothing
// to do; an outward arrow in a ring when it goes on in the agent's desktop app. Reduced motion: no turning, no breathing.
import { t } from '../i18n';
import type { Mark } from '../sessions';

export function StatusMark({ mark, size = 10 }: { mark: Mark; size?: number }) {
  const r = size / 2;
  const label = t(`ses.mark.${mark}`);
  const body = (() => {
    switch (mark) {
      case 'working': {
        const w = Math.max(1.6, size / 8);
        const rr = r - w / 2;
        const c = 2 * Math.PI * rr;
        return (
          <>
            <circle cx={r} cy={r} r={rr} fill="none" stroke="var(--brand-ink)" strokeOpacity={0.22} strokeWidth={w} />
            <circle className="smark-arc" cx={r} cy={r} r={rr} fill="none" stroke="var(--brand-ink)" strokeWidth={w} strokeLinecap="round"
              strokeDasharray={`${c * 0.28} ${c}`} />
          </>
        );
      }
      case 'waiting': {
        const w = Math.max(1.5, size / 7);
        return (
          <>
            <circle className="smark-pulse" cx={r} cy={r} r={r} fill="var(--attn)" fillOpacity={0.28} />
            <circle cx={r} cy={r} r={r - w / 2} fill="none" stroke="var(--attn)" strokeWidth={w} />
            <circle cx={r} cy={r} r={size * 0.2} fill="var(--attn)" />
          </>
        );
      }
      case 'done': {
        const k = size / 10;
        return (
          <>
            <circle cx={r} cy={r} r={r} fill="var(--ok)" />
            <path d={`M${3 * k} ${5.2 * k}L${4.4 * k} ${6.6 * k}L${7.1 * k} ${3.6 * k}`} fill="none" stroke="var(--on-ok)" strokeWidth={Math.max(1.2, 1.3 * k)}
              strokeLinecap="round" strokeLinejoin="round" />
          </>
        );
      }
      case 'failed': {
        const k = size / 10;
        return (
          <>
            <circle cx={r} cy={r} r={r} fill="var(--err)" />
            <path d={`M${3.4 * k} ${3.4 * k}L${6.6 * k} ${6.6 * k}M${6.6 * k} ${3.4 * k}L${3.4 * k} ${6.6 * k}`} fill="none" stroke="#fff"
              strokeWidth={Math.max(1.2, 1.3 * k)} strokeLinecap="round" />
          </>
        );
      }
      case 'idle': {
        const w = Math.max(1.4, size / 9);
        return <circle cx={r} cy={r} r={r - w / 2} fill="none" stroke="var(--faint)" strokeWidth={w} />;
      }
      case 'elsewhere': {
        const w = Math.max(1.2, size / 11);
        const k = size / 10;
        return (
          <>
            <circle cx={r} cy={r} r={r - w / 2} fill="none" stroke="var(--brand-ink)" strokeWidth={w} />
            <path d={`M${3.6 * k} ${6.4 * k}L${6.4 * k} ${3.6 * k}M${4.2 * k} ${3.6 * k}H${6.4 * k}V${5.8 * k}`} fill="none" stroke="var(--brand-ink)"
              strokeWidth={w} strokeLinecap="round" strokeLinejoin="round" />
          </>
        );
      }
    }
  })();
  return (
    <svg key={mark} className={`smark m-${mark}`} width={size} height={size} viewBox={`0 0 ${size} ${size}`} role="img" aria-label={label} overflow="visible">
      <title>{label}</title>
      {body}
    </svg>
  );
}
