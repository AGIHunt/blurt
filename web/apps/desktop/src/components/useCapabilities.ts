// One copy of the capability switches for the whole window (the sidebar, Home, Settings, the Welcome): read once, kept
// fresh by `capabilities://changed` — whoever turned one on or off (Home, Settings, a hand edit of config.json).
import { useEffect, useState } from 'react';
import { api, onCapabilities } from '../api';
import { offSet, type Capability } from '../capabilities';

let latest: Set<Capability> = new Set();
let known = false;
const subs = new Set<(s: Set<Capability>) => void>();
let started = false;

function publish(ids: string[]) {
  latest = offSet(ids);
  known = true;
  subs.forEach((f) => f(latest));
}

function start() {
  if (started) return;
  started = true;
  onCapabilities((p) => publish(p.off));
  api.capabilities().then((p) => publish(p.off), () => publish([]));
}

/** The capabilities that are off, and whether the host has answered yet. */
export function useOff(): { off: Set<Capability>; known: boolean } {
  const [s, setS] = useState(latest);
  const [k, setK] = useState(known);
  useEffect(() => {
    start();
    const f = (x: Set<Capability>) => {
      setS(x);
      setK(true);
    };
    subs.add(f);
    setS(latest);
    setK(known);
    return () => {
      subs.delete(f);
    };
  }, []);
  return { off: s, known: k };
}

/** Turn one on or off; its answer is shown at once (the event follows). */
export const setCapability = (c: Capability, on: boolean) => api.setCapability(c, on).then((p) => publish(p.off));
