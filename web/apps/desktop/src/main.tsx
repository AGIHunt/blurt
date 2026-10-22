import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import App from './App';
import '@blurt/ui/tokens.css';
import '@blurt/ui/base.css';
import '@blurt/icons/mascot.css';
import './styles.css';

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
