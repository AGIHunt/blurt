/* Kind eggs (16×16, the same shapes the menu-bar app draws): issue = speckled with a tiny bug, idea = golden,
   note = white, task = brown with a check, custom lenses = a pastel egg in currentColor. One sprite per page. */
const EGGS = new Set(["issue", "idea", "note", "task"]);

export function EggSprite() {
  return (
    <svg width="0" height="0" style={{ position: "absolute" }} aria-hidden="true" focusable="false">
      <defs>
        <path id="egg-o" d="M8 1.1C5.15 1.1 2.95 5.25 2.95 9.2c0 3.3 2.2 5.7 5.05 5.7s5.05-2.4 5.05-5.7C13.05 5.25 10.85 1.1 8 1.1Z" />
        <radialGradient id="eg-gloss" cx=".34" cy=".26" r=".62">
          <stop offset="0" stopColor="#fff" stopOpacity=".85" />
          <stop offset=".45" stopColor="#fff" stopOpacity=".18" />
          <stop offset="1" stopColor="#fff" stopOpacity="0" />
        </radialGradient>
        <radialGradient id="eg-issue" cx=".4" cy=".34" r=".78">
          <stop offset="0" stopColor="#fbf4e6" />
          <stop offset=".7" stopColor="#ead7b5" />
          <stop offset="1" stopColor="#c9ad80" />
        </radialGradient>
        <radialGradient id="eg-idea" cx=".4" cy=".32" r=".8">
          <stop offset="0" stopColor="#fff1a8" />
          <stop offset=".5" stopColor="#f4c22e" />
          <stop offset="1" stopColor="#bf830a" />
        </radialGradient>
        <radialGradient id="eg-note" cx=".4" cy=".32" r=".82">
          <stop offset="0" stopColor="#fff" />
          <stop offset=".72" stopColor="#f2efe9" />
          <stop offset="1" stopColor="#d6d0c4" />
        </radialGradient>
        <radialGradient id="eg-task" cx=".4" cy=".32" r=".82">
          <stop offset="0" stopColor="#e9b783" />
          <stop offset=".6" stopColor="#c3824a" />
          <stop offset="1" stopColor="#8e5427" />
        </radialGradient>
        <radialGradient id="eg-shade" cx=".5" cy=".42" r=".62">
          <stop offset=".6" stopColor="#000" stopOpacity="0" />
          <stop offset="1" stopColor="#000" stopOpacity=".22" />
        </radialGradient>
        <symbol id="egg-issue" viewBox="0 0 16 16">
          <use href="#egg-o" fill="url(#eg-issue)" stroke="#7a5c38" strokeOpacity=".5" strokeWidth=".7" />
          <g fill="#9a7650">
            <circle cx="5.5" cy="6.6" r=".5" />
            <circle cx="7.3" cy="3.9" r=".35" />
            <circle cx="10.5" cy="5.6" r=".4" />
            <circle cx="5" cy="10.4" r=".42" />
            <circle cx="11.5" cy="8.4" r=".3" />
            <circle cx="6.6" cy="13" r=".3" />
          </g>
          <g fill="#33261d" stroke="#33261d" strokeWidth=".6" strokeLinecap="round" transform="translate(9.4 11) scale(.72) translate(-8.8 -10.6)">
            <path d="M7.55 9.7 6.3 9.15M7.4 10.9H6.05M7.6 12.05l-1.05.75M10.05 9.7l1.25-.55M10.2 10.9h1.35M10 12.05l1.05.75M8.35 7.6l-.55-.85M9.25 7.6l.55-.85" fill="none" />
            <ellipse cx="8.8" cy="10.85" rx="1.55" ry="1.9" stroke="none" />
            <circle cx="8.8" cy="8.55" r=".85" stroke="none" />
          </g>
          <use href="#egg-o" fill="url(#eg-gloss)" />
        </symbol>
        <symbol id="egg-idea" viewBox="0 0 16 16">
          <use href="#egg-o" fill="url(#eg-idea)" stroke="#8a5d05" strokeOpacity=".55" strokeWidth=".7" />
          <use href="#egg-o" fill="url(#eg-gloss)" />
          <path d="M10.4 4.1l.32.9.9.32-.9.32-.32.9-.32-.9-.9-.32.9-.32z" fill="#fff" />
        </symbol>
        <symbol id="egg-note" viewBox="0 0 16 16">
          <use href="#egg-o" fill="url(#eg-note)" stroke="#6f695e" strokeOpacity=".75" strokeWidth=".75" />
          <use href="#egg-o" fill="url(#eg-gloss)" />
        </symbol>
        <symbol id="egg-task" viewBox="0 0 16 16">
          <use href="#egg-o" fill="url(#eg-task)" stroke="#5e3615" strokeOpacity=".55" strokeWidth=".7" />
          <use href="#egg-o" fill="url(#eg-gloss)" opacity=".7" />
          <path d="M5.5 9.6l1.75 1.75 3.3-3.6" fill="none" stroke="#fff" strokeWidth="1.55" strokeLinecap="round" strokeLinejoin="round" />
        </symbol>
        <symbol id="egg-custom" viewBox="0 0 16 16">
          <use href="#egg-o" fill="currentColor" />
          <use href="#egg-o" fill="url(#eg-shade)" stroke="#000" strokeOpacity=".22" strokeWidth=".7" />
          <use href="#egg-o" fill="url(#eg-gloss)" />
        </symbol>
      </defs>
    </svg>
  );
}

export function Egg({ kind, className }: { kind: string; className?: string }) {
  const cls = "egg" + (className ? " " + className : "");
  if (EGGS.has(kind))
    return (
      <svg className={cls} viewBox="0 0 16 16" aria-hidden="true">
        <use href={`#egg-${kind}`} />
      </svg>
    );
  let h = 0;
  for (const c of String(kind)) h = (h * 31 + c.charCodeAt(0)) % 360;
  return (
    <svg className={cls} viewBox="0 0 16 16" aria-hidden="true" style={{ color: `hsl(${h} 62% 80%)` }}>
      <use href="#egg-custom" />
    </svg>
  );
}
