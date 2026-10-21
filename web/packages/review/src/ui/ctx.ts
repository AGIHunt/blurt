import { createContext, useContext, useSyncExternalStore } from "react";
import type { ReviewStore } from "../store";

export const StoreCtx = createContext<ReviewStore | null>(null);

/** the store; the calling component re-renders on every change */
export function useStore(): ReviewStore {
  const s = useContext(StoreCtx);
  if (!s) throw new Error("no ReviewStore");
  useSyncExternalStore(s.subscribe, s.getVersion, s.getVersion);
  return s;
}

export const cx = (...a: (string | false | null | undefined)[]) => a.filter(Boolean).join(" ");

/** tiny markdown for the digest: headings, lists, bold, code, links — escaped first */
export const esc = (s: unknown) =>
  String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]!);
export function mdLite(src: string): string {
  const lines = String(src || "").split("\n");
  let out = "";
  let inList = false;
  const inline = (x: string) =>
    esc(x)
      .replace(/\*\*(.+?)\*\*/g, "<b>$1</b>")
      .replace(/`([^`]+)`/g, "<code>$1</code>")
      .replace(/\[([^\]]+)\]\((https?:[^)\s]+)\)/g, '<a href="$2" target="_blank" rel="noreferrer">$1</a>');
  for (const l of lines) {
    const m = l.match(/^\s*[-*]\s+(.*)/);
    const h = l.match(/^(#{1,4})\s+(.*)/);
    if (m) {
      if (!inList) {
        out += "<ul>";
        inList = true;
      }
      out += `<li>${inline(m[1])}</li>`;
      continue;
    }
    if (inList) {
      out += "</ul>";
      inList = false;
    }
    if (h) out += `<h${h[1].length + 1}>${inline(h[2])}</h${h[1].length + 1}>`;
    else if (l.trim()) out += `<p>${inline(l)}</p>`;
  }
  return out + (inList ? "</ul>" : "");
}
