/* Synthetic product screenshots for the v3 suite and its screenshots: small, plausible pages rendered once per run
   (no real app, no real desktop). */
import type { Browser } from "@playwright/test";
import { existsSync, mkdirSync, renameSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const FONT = `font-family: -apple-system, 'SF Pro Text', 'Segoe UI', Inter, sans-serif;`; // inside style="…": single quotes
const page = (body: string, bg = "#f7f7f8") =>
  `<html><body style="margin:0;${FONT};background:${bg};width:1280px;height:800px;overflow:hidden">${body}</body></html>`;
const nav = (dark = false) => `<div style="height:56px;display:flex;align-items:center;gap:28px;padding:0 40px;border-bottom:1px solid ${dark ? "#26262b" : "#e6e6ea"};background:${dark ? "#0d0d10" : "#fff"};color:${dark ? "#d6d6dc" : "#3a3a40"};font-size:14px">
  <b style="font-size:17px;color:${dark ? "#fff" : "#111"};letter-spacing:-.01em">Northwind</b><span>Product</span><span>Pricing</span><span>Docs</span><span style="margin-left:auto">Sign in</span></div>`;

export const SCENES: Record<string, string> = {
  login: page(`${nav()}<div style="display:grid;place-items:center;height:744px">
    <div style="width:380px;background:#fff;border-radius:14px;box-shadow:0 1px 2px rgba(0,0,0,.06),0 12px 32px -12px rgba(0,0,0,.18);padding:32px">
      <h2 style="margin:0 0 6px;font-size:22px">Welcome back</h2><p style="margin:0 0 22px;color:#71717a;font-size:14px">Sign in to your workspace</p>
      <div style="font-size:13px;color:#52525b;margin-bottom:6px">Email</div><div style="height:40px;border:1px solid #d4d4d8;border-radius:8px;padding:0 12px;display:flex;align-items:center;font-size:14px">ana@northwind.io</div>
      <div style="font-size:13px;color:#52525b;margin:14px 0 6px">Password</div><div style="height:40px;border:1px solid #d4d4d8;border-radius:8px;padding:0 12px;display:flex;align-items:center;font-size:18px;letter-spacing:2px">••••••••••</div>
      <div style="position:relative;margin-top:22px"><div style="height:42px;border-radius:8px;background:#c7c7cf;color:#fff;display:grid;place-items:center;font-weight:600">Sign in</div>
      <div style="position:absolute;inset:-8px;border:3px solid #ef4444;border-radius:12px"></div></div>
    </div></div>`),
  devtools: page(`${nav()}<div style="display:flex;height:744px"><div style="flex:1"></div>
    <div style="width:560px;background:#fff;border-left:1px solid #e4e4e7;font:12px ui-monospace,Menlo,monospace;color:#3f3f46">
      <div style="padding:10px 14px;border-bottom:1px solid #e4e4e7;${FONT};font-size:13px"><b>Console</b> &nbsp; Network &nbsp; Sources</div>
      <div style="padding:8px 14px;background:#fef2f2;color:#b91c1c;border-bottom:1px solid #fee2e2">Uncaught TypeError: Cannot read properties of undefined (reading 'submit')<br>&nbsp;&nbsp;at LoginForm.tsx:42</div>
      <div style="padding:8px 14px;border-bottom:1px solid #f4f4f5">POST /api/session &nbsp;&nbsp;— not sent</div>
      <div style="padding:8px 14px;color:#a1a1aa">Safari 18.2 · macOS</div></div></div>`),
  pricing: page(`${nav()}<div style="text-align:center;padding:56px 0 30px"><h1 style="margin:0;font-size:40px;letter-spacing:-.02em">Simple pricing</h1>
    <p style="color:#71717a">Pay for the seats you use.</p></div><div style="display:flex;gap:20px;justify-content:center">
    ${["Starter|$0|For trying it out", "Team|$12|per seat / month", "Business|$29|per seat / month"].map((t, n) => {
      const [a, b, c] = t.split("|");
      return `<div style="width:300px;height:360px;background:#fff;border-radius:16px;padding:28px;box-sizing:border-box;${n === 1 ? "box-shadow:0 0 0 2px #6366f1" : "box-shadow:0 0 0 1px #e4e4e7"}">
      <div style="font-weight:600">${a}</div><div style="font-size:40px;font-weight:700;margin:14px 0 4px">${b}</div><div style="color:#71717a;font-size:14px">${c}</div>
      <div style="margin-top:36px;height:42px;border-radius:9px;background:${n === 1 ? "#6366f1" : "#f4f4f5"};color:${n === 1 ? "#fff" : "#18181b"};display:grid;place-items:center;font-weight:600">Choose ${a}</div></div>`;
    }).join("")}</div>`),
  toasts: page(`${nav()}<div style="padding:40px"><h2 style="margin:0 0 16px">Settings</h2><div style="width:560px;height:220px;background:#fff;border-radius:12px;box-shadow:0 0 0 1px #e4e4e7"></div></div>
    <div style="position:absolute;right:32px;bottom:32px;display:flex;flex-direction:column;gap:10px">
    ${[0, 1, 2].map(() => `<div style="width:300px;height:52px;background:#18181b;color:#fff;border-radius:10px;display:flex;align-items:center;padding:0 16px;font-size:14px;gap:10px"><span style="width:8px;height:8px;border-radius:9px;background:#22c55e"></span>Changes saved</div>`).join("")}</div>`),
  hero: page(`${nav(true)}<div style="height:744px;display:grid;place-items:center;background:radial-gradient(60% 60% at 50% 30%,#312e81 0%,#0d0d10 70%);color:#fff;text-align:center">
    <div><div style="display:inline-block;padding:6px 12px;border-radius:99px;background:rgba(255,255,255,.08);font-size:13px;margin-bottom:22px">New · Triage, reimagined</div>
    <h1 style="font-size:64px;margin:0;letter-spacing:-.03em;line-height:1.05">Build the thing,<br>not the backlog.</h1>
    <p style="color:#a1a1aa;font-size:18px">Keyboard-first issue tracking for fast teams.</p></div></div>`, "#0d0d10"),
  notes: page(`<div style="display:flex;height:800px"><div style="width:240px;background:#f4f4f5;padding:20px;box-sizing:border-box;font-size:14px;color:#52525b;line-height:2">Workspace<br><b style="color:#18181b">Release notes</b><br>Roadmap<br>Meeting notes</div>
    <div style="flex:1;background:#fff;padding:56px 80px"><h1 style="margin:0 0 8px;font-size:34px">v2.4 release notes</h1><p style="color:#a1a1aa;margin:0 0 30px">Draft · last edited 2 hours ago</p>
    ${["Faster sign-in on Safari", "Pricing calculator", "Fewer duplicate toasts"].map((x) => `<div style="display:flex;gap:12px;align-items:center;margin:12px 0;font-size:17px"><span style="width:18px;height:18px;border:2px solid #d4d4d8;border-radius:5px"></span>${x}</div>`).join("")}
    <div style="margin-top:26px;height:14px;width:62%;background:#f4f4f5;border-radius:4px"></div><div style="margin-top:10px;height:14px;width:48%;background:#f4f4f5;border-radius:4px"></div></div></div>`),
};

/** render every scene to <tmp>/blurt-e2e-scenes/<name>.png once; returns name → absolute path */
export async function renderScenes(browser: Browser): Promise<Record<string, string>> {
  const dir = join(tmpdir(), "blurt-e2e-scenes");
  mkdirSync(dir, { recursive: true });
  const out: Record<string, string> = {};
  let p: Awaited<ReturnType<Browser["newPage"]>> | null = null;
  for (const [name, html] of Object.entries(SCENES)) {
    const f = join(dir, `${name}.png`);
    out[name] = f;
    if (existsSync(f)) continue;
    p ??= await browser.newPage({ viewport: { width: 1280, height: 800 } });
    await p.setContent(html);
    const tmp = `${f}.${process.pid}.png`; // workers render in parallel: publish whole files only
    await p.screenshot({ path: tmp });
    renameSync(tmp, f);
  }
  await p?.close();
  return out;
}
