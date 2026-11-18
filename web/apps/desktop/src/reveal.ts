// "Show in File Explorer" / "Show in Files" (GNOME): the one label of Show in Folder everywhere in the window. The
// platform comes from the app's status (api.status notes it).
import { t } from './i18n';

let gnome = false;

export function notePlatform(platform: string | null | undefined): void {
  gnome = platform === 'gnome';
}

export const revealLabel = (): string => t(gnome ? 'mw.reveal.files' : 'mw.reveal');
