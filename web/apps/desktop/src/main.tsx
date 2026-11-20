import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import App from './App';
import { ViewerWindow } from './viewer/ViewerWindow';
import { RemoteBanner } from './viewer/RemoteBanner';
import '@blurt/ui/tokens.css';
import '@blurt/ui/base.css';
import '@blurt/icons/mascot.css';
import '@blurt/icons/peep-l';
import './styles.css';

// the browser's own menu (Back / Refresh / Print) only where it is useful: in a text field or over selected text
// (cut, copy, paste); the
// app's own right-click menus call preventDefault themselves. Its reload / find / print keys are off (lib.rs).
document.addEventListener('contextmenu', (e) => {
  const el = e.target as HTMLElement | null;
  if (el?.closest('input, textarea, [contenteditable=""], [contenteditable="true"]') || window.getSelection()?.toString()) return;
  e.preventDefault();
});

// a computer's window (src-tauri viewer.rs opens index.html?viewer=<host id>) or the main window
// or the bar on a computer being controlled (remote.rs opens index.html?banner=1)
const params = new URLSearchParams(location.search);
const viewer = params.get('viewer');
createRoot(document.getElementById('root')!).render(
  <StrictMode>
    {params.has('banner') ? <RemoteBanner /> : viewer ? <ViewerWindow id={viewer} /> : <App />}
  </StrictMode>,
);
