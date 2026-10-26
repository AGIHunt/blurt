/* blurt.agihunt.info, round 9: Peep.
   Every Peep on the page is a frame set rendered from the brand-book model (logo/peep/peep.py), played at 30 fps from
   sprite sheets (one background image per state, the frame picked by background-position). The table of sheets is
   inlined in the page (#peepm, written by build_pages9.py).
   1. the notch: Peep sits in the left ear for the whole scroll story and plays the real states; main.js tells it the
      scene and step (Peep.scene) and a few beats (Peep.once, Peep.count). When nothing happens it follows the pointer
      with a 7 x 5 grid of head turns.
   2. dictation: the words leave Peep's beak and land at the cursor; a dashed mint pencil box holds the phrase until
      the ink lands.
   3. the snap: Peep leaves the notch, pecks the circled total and carries the card back under the notch.
   4. the hero idle loop (video with alpha), 5. the footer: clay Peep peeks up from the bottom edge, eyes on the pointer.
   Reduced motion: nothing here runs; the CSS shows a still per scene (each scene's end state). */
(() => {
  const mEl = document.getElementById("peepm");
  if (!mEl) return;
  const M = JSON.parse(mEl.textContent);
  const me = document.currentScript;
  const BASE = new URL(".", me.src), V = new URL(me.src).search;
  const url = (src) => new URL(src, BASE).href + V;
  const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const fine = matchMedia("(pointer: fine)").matches;
  const wait = (ms) => new Promise((r) => setTimeout(r, ms));
  const clamp = (x, a = -1, b = 1) => Math.min(b, Math.max(a, x));
  const FR = { cx: 0.397, cy: 0.55, R: 0.292, bx: 0.83, by: 0.55 };   // body centre, radius, beak tip in a full frame

  /* ---------------------------------------------------------------- sheets */
  const loading = new Map();
  const load = (s) => {
    const u = url(s.src);
    if (!loading.has(u)) loading.set(u, new Promise((r) => { const i = new Image(); i.onload = i.onerror = () => r(); i.decoding = "async"; i.src = u; }));
    return loading.get(u);
  };
  const paint = (el, s, f) => {
    if (el._s !== s) {
      el._s = s;
      el.style.backgroundImage = `url("${url(s.src)}")`;
      el.style.backgroundSize = `${s.cols * 100}% ${Math.ceil(s.n / s.cols) * 100}%`;
    }
    const rows = Math.ceil(s.n / s.cols), c = f % s.cols, r = Math.floor(f / s.cols);
    el.style.backgroundPosition = `${s.cols > 1 ? (c / (s.cols - 1)) * 100 : 0}% ${rows > 1 ? (r / (rows - 1)) * 100 : 0}%`;
  };
  // where the body and the beak are inside an element showing a frame of sheet s (CSS px, element space)
  const geo = (el, s) => {
    const r = el.getBoundingClientRect(), [x0, y0, x1, y1] = s.box;
    const fw = r.width / (x1 - x0), fh = r.height / (y1 - y0);
    return { r, R: FR.R * fw, cx: r.left + (FR.cx - x0) * fw, cy: r.top + (FR.cy - y0) * fh, bx: r.left + (FR.bx - x0) * fw, by: r.top + (FR.by - y0) * fh,
      ox: (FR.cx - x0) * fw, oy: (FR.cy - y0) * fh };
  };

  /* a player: one element, one state at a time; loops or plays once then calls back */
  class Spr {
    constructor(el, fam) { this.el = el; this.fam = fam; this.s = null; this.f = 0; this.hold = 0; }
    play(state, then) {
      const s = M.s[`${this.fam}/${state}`];
      if (!s) return;
      this.want = s;
      load(s).then(() => {
        if (this.want !== s) return;
        this.want = null; this.s = s; this.state = state; this.f = 0; this.then = then || null; this.once = !!then; this.hold = 0;
        this.look = false; paint(this.el, s, 0);
      });
    }
    tick(now) {
      if (!this.s || this.look || now < this.hold) return;
      if (++this.f >= this.s.n) {
        if (this.then) { const t = this.then; this.then = null; t(); return; }
        if (this.once) { this.f = this.s.n - 1; return; }
        this.f = 0;
        if (this.onloop) this.onloop(now);
      }
      paint(this.el, this.s, this.f);
    }
  }
  const players = new Set();
  let last = 0;
  const loop = (t) => {
    if (t - last >= 1000 / 30 - 2) { last = t; players.forEach((p) => p.tick(t)); }
    requestAnimationFrame(loop);
  };

  const api = { scene() {}, once() {}, count() {}, footer: false };
  window.Peep = api;
  if (reduce) { hero(); footer(); return; }

  /* ---------------------------------------------------------------- 1. the notch */
  const isl = document.getElementById("isl");
  const npEl = isl && isl.querySelector("[data-peep]");
  const N = npEl ? new Spr(npEl, "n") : null;
  let base = "idle", busy = false, lookT = 0, lastMove = 0;
  if (N) {
    players.add(N);
    // idle: a random 0-2 s hold before each loop, so the blinks never line up; one loop in six blinks twice
    N.onloop = (now) => { if (N.state === "idle") N.hold = now + (Math.random() < 1 / 6 ? 0 : 400 + Math.random() * 1700); };
    N.play("idle");
  }
  let busyWith = "";
  const setBase = (st) => {
    if (base === st && (busy || N.state === st || N.want)) return;
    base = st;
    if (busy && busyWith === "hello" && st !== "idle") { busy = false; npEl.classList.remove("beat"); }     // a greeting gives way to work
    if (!busy) N.play(st);
  };
  // a one-shot (done = hop and peep, hello = turn to you), then back to the loop the scene wants
  const once = (st) => {
    if (!N || busy) return;
    busy = true; busyWith = st;
    npEl.classList.add("beat");
    N.play(st, () => { busy = false; npEl.classList.remove("beat"); N.play(base); });
  };
  api.once = once;
  api.now = () => (N.look ? "look" : N.state || "") + (busy ? "*" : "");     // for the review scripts

  // gaze: when nothing happens, the head turns toward the pointer (7 turns x 5 pitches, rendered)
  if (N && fine) addEventListener("pointermove", (e) => {
    lastMove = performance.now();
    if (busy || base !== "idle" || api.away) return;
    const g = geo(npEl, M.s["n/idle"]);
    const L = M.look, x = clamp((e.clientX - g.cx) / 420), y = clamp((e.clientY - g.cy) / 360);
    // turn index 2 is the rest pose; Peep faces right, so a pointer on the right turns the beak toward it (index 0)
    const ti = Math.round(x > 0 ? 2 - x * 2 : 2 + -x * 4), pj = Math.round((y * 0.5 + 0.5) * (L.pitches - 1));
    load(L).then(() => {
      if (busy || base !== "idle") return;
      N.look = true; paint(npEl, L, ti * L.pitches + pj);
      clearTimeout(lookT);
      lookT = setTimeout(() => { if (N.look) { N.look = false; N.s = null; N.play(base); } }, 1600);
    });
  }, { passive: true });

  /* what each scene and step asks of Peep (main.js calls this every frame with the active scene) */
  let last0 = { name: "", k: -1, mode: "" };
  api.scene = (name, k, prev, mode) => {
    if (!N) return;
    const fwd = name === last0.name && k > last0.k;
    const into = (n) => fwd && k === n && last0.k < n;
    let st = "idle";
    if (mode === "listen" || mode === "rec") st = "listening";
    if (mode === "list") st = "talking";
    if (name === "dict" && k === 3) st = words.on ? "talking" : "idle";
    if (name === "struct" && k >= 3) st = "talking";
    if (name === "snap" && k >= 3 && k < 9) st = "listening";
    if (name === "rec" && k === 5) st = "thinking";
    if (name === "hand" && k >= 1 && k <= 3) st = "thinking";
    setBase(st);
    if (name === "dict") { if (k === 3 && last0.name === "dict" && last0.k === 2) words.start(); else if (k !== 3) words.stop(); }
    if (name === "snap") { if (k === 10 && last0.name === "snap" && last0.k === 9) carry.start(); else if (k !== 10) carry.stop(k); }
    else carry.stop(-1);
    // beats
    if (mode === "done" && last0.mode !== "done" && !(name === "dict" && k === 3)) once("done");
    if (name === "rec" && into(4)) once("done");
    if (name === "hand" && (into(4) || into(6))) once("done");
    if (mode === "hello" && last0.mode !== "hello" && st === "idle" && !carry.on) once("hello");     // turns to you, blinks twice
    last0 = { name, k, mode };
  };
  // the 52 items stream out: a peep for each batch of 13
  let batch = 0;
  api.count = (n) => { const b = Math.floor(n / 13); if (b > batch && n > 0) once("done"); batch = b; };

  /* ---------------------------------------------------------------- 2. dictation: the words leave the beak */
  const words = { on: false, run: 0 };
  Object.defineProperty(api, "typing", { get: () => words.on });
  const dictEl = document.querySelector(".sc-dict");
  words.start = async () => {
    if (!dictEl || words.on) return;
    const run = ++words.run;
    const box = dictEl.querySelector(".t-in"), typed = box && box.querySelector(".t-typed");
    if (!typed) return;
    const spaced = document.documentElement.lang === "en";
    const list = (dictEl.dataset.say || "").split(" ").filter(Boolean);
    words.on = true; words.typed = typed; words.text = words.text || typed.textContent;
    dispatchEvent(new Event("scroll"));                       // the notch shows no tick until the ink lands
    dictEl.classList.add("pv-w");
    typed.textContent = "";
    const spans = list.map((w, i) => { const s = document.createElement("span"); s.className = "pw"; s.textContent = w + (spaced && i < list.length - 1 ? " " : ""); typed.appendChild(s); return s; });
    // the pencil box: dashed mint, the size of the whole phrase, where it will be written
    spans.forEach((s) => s.classList.add("ms"));
    const rt = typed.getBoundingClientRect(), rb = box.getBoundingClientRect();
    spans.forEach((s) => s.classList.remove("ms"));
    const pen = document.createElement("span");
    pen.className = "pencil";
    Object.assign(pen.style, { left: `${rt.left - rb.left - 5}px`, top: `${rt.top - rb.top - 4}px`, width: `${rt.width + 10}px`, height: `${rt.height + 8}px` });
    box.appendChild(pen); words.pen = pen;
    setBase("talking");
    await wait(140);
    const cs = getComputedStyle(typed);
    const FLY = Math.min(5, list.length);
    const flights = [];
    for (let i = 0; i < list.length; i++) {
      if (run !== words.run) return;
      const s = spans[i];
      if (i < FLY) {
        s.classList.add("ms");
        const t = s.getBoundingClientRect(), g = geo(npEl, N.s || M.s["n/idle"]);
        const fw = document.createElement("span");
        fw.className = "fw"; fw.textContent = list[i];
        Object.assign(fw.style, { font: cs.font, letterSpacing: cs.letterSpacing });
        document.body.appendChild(fw); words.fws = (words.fws || []).concat(fw);
        const mx = g.bx + (t.left - g.bx) * 0.5 + 40, my = g.by + (t.top - g.by) * 0.22;
        const a = fw.animate([
          { transform: `translate(${g.bx}px, ${g.by - 6}px) scale(.5)`, opacity: .9 },
          { transform: `translate(${mx}px, ${my}px) scale(1.25)`, opacity: 1, offset: 0.42 },
          { transform: `translate(${t.left}px, ${t.top}px) scale(1)`, opacity: 1 }],
          { duration: 520, easing: "cubic-bezier(.3,.7,.3,1.06)", fill: "forwards" });
        flights.push(a.finished.then(() => { fw.remove(); s.classList.remove("ms"); s.classList.add("in"); }).catch(() => {}));
        await wait(170);
      } else {
        await Promise.all(flights);
        s.classList.add("in");
        await wait(75);
      }
    }
    await Promise.all(flights);
    if (run !== words.run) return;
    await wait(220);
    pen.classList.add("ink");
    await wait(320);
    pen.classList.add("gone");
    words.on = false;
    setBase("idle"); once("done");
    dispatchEvent(new Event("scroll"));
  };
  words.stop = () => {
    if (!words.typed) return;
    words.run++; words.on = false;
    (words.fws || []).forEach((f) => f.remove()); words.fws = [];
    if (words.pen) words.pen.remove();
    words.typed.textContent = words.text;
    dictEl.classList.remove("pv-w");
    words.typed = null;
  };

  /* ---------------------------------------------------------------- 3. the snap: peck the circle, carry the card */
  const snapEl = document.querySelector(".sc-snap");
  const carry = { on: false, run: 0, anims: [] };
  const flyEl = document.createElement("span");
  flyEl.className = "pp pf"; flyEl.setAttribute("aria-hidden", "true");
  const dark = matchMedia("(prefers-color-scheme: dark)");
  const F = new Spr(flyEl, "f");
  carry.start = async () => {
    if (!snapEl || !N || carry.on) return;
    const ghost = snapEl.querySelector(".ghost"), ell = ghost && ghost.querySelector(".s-ell"), card = snapEl.querySelector(".c-snap");
    if (!ell || !card) return;
    const run = ++carry.run;
    carry.on = true;
    const ok = () => run === carry.run;
    F.fam = dark.matches && M.s["fd/done"] ? "fd" : "f";       // dark pages: the dark set, the beak one step lighter
    const sF = M.s[`${F.fam}/done`];
    await Promise.all([load(sF), load(M.s[`${F.fam}/peck`])]);
    if (!ok()) return;
    snapEl.classList.add("pv-c");
    // sizes: the flying body is about a seventh of the snap's width
    const gr = ghost.getBoundingClientRect(), er = ell.getBoundingClientRect();
    const R = Math.max(16, Math.min(64, gr.width * 0.15, innerWidth * 0.075));
    const full = R / FR.R, [x0, y0, x1, y1] = sF.box;
    const W = full * (x1 - x0), H = W * sF.h / sF.w;
    Object.assign(flyEl.style, { width: `${W}px`, height: `${H}px` });
    document.body.appendChild(flyEl); players.add(F);
    const ox = (FR.cx - x0) * full, oy = (FR.cy - y0) * full;     // body centre inside the element
    const bdx = (FR.bx - FR.cx) * full;                           // beak tip, right of the centre
    const at = (cx, cy, s, r = 0) => `translate(${cx - ox * s}px, ${cy - oy * s}px) scale(${s}) rotate(${r}deg)`;
    const n = geo(npEl, N.s || M.s["n/idle"]);
    const s0 = n.R / R;
    // 1. out of the notch, down to the left end of the circle (the beak touches the line)
    const lx = Math.max(R * 1.1 + 4, er.left + 2 - bdx), ly = er.top + er.height * 0.5;   // the beak tip on the line; on screen, even on a phone
    flyEl.style.transformOrigin = "0 0";
    F.play("done", () => {});
    N.el.style.visibility = "hidden";
    const go = (kf, o) => { const a = flyEl.animate(kf, { fill: "forwards", ...o }); carry.anims.push(a); return a.finished.catch(() => {}); };
    await go([{ transform: at(n.cx, n.cy, s0) }, { transform: at(n.cx + (lx - n.cx) * 0.3, n.cy + 8, (s0 + 1) / 2, -8), offset: 0.35 },
              { transform: at(lx, ly, 1) }], { duration: 760, easing: "cubic-bezier(.45,.05,.35,1)" });
    if (!ok()) return;
    // 2. two pecks; the circle wobbles on each
    F.play("peck", () => {});
    for (const t of [230, 330]) { await wait(t); if (!ok()) return; ell.classList.remove("wob"); void ell.getBoundingClientRect(); ell.classList.add("wob"); }
    await wait(420);
    if (!ok()) return;
    // 3. takes the snap by its top edge and flies it up under the notch; the snap swings under the beak
    const hang = card.parentElement.getBoundingClientRect();
    const cw = card.offsetWidth, cl = hang.left + card.offsetLeft, ct = hang.top + card.offsetTop;
    const g2 = ghost.getBoundingClientRect();
    const ax = g2.left + g2.width * 0.03, ay = g2.top + g2.height * 0.02;  // the beak holds the top-left corner
    const tx = cl + cw * 0.03, ty = ct + 2, k = cw / g2.width;
    ghost.style.transformOrigin = `${g2.width * 0.03}px ${g2.height * 0.02}px`;
    F.play("done", () => {});
    const hold = (x, y, s, r) => at(x - bdx * s, y, s, r);                    // body placed so the beak tip is at x, y
    await go([{ transform: at(lx, ly, 1) }, { transform: hold(ax, ay, 0.95, 4) }], { duration: 300, easing: "cubic-bezier(.3,0,.3,1)" });
    if (!ok()) return;
    const ease = "cubic-bezier(.45,0,.25,1)", D = 1050;
    const pk = (s) => ({ x: ax + (tx - ax) * s, y: ay + (ty - ay) * s });
    const P = [0, 0.4, 0.75, 1].map(pk);
    go([0, 1, 2, 3].map((i) => ({ transform: hold(P[i].x, P[i].y, 0.95 - 0.35 * i / 3, 4 - 2 * i) })), { duration: D, easing: ease });
    const ga = ghost.animate([
      { transform: "none", opacity: 1 },
      { transform: `translate(${P[1].x - ax}px, ${P[1].y - ay}px) scale(${1 + (k - 1) * 0.4}) rotate(9deg)`, offset: 0.4 },
      { transform: `translate(${P[2].x - ax}px, ${P[2].y - ay}px) scale(${1 + (k - 1) * 0.75}) rotate(-6deg)`, offset: 0.75 },
      { transform: `translate(${tx - ax}px, ${ty - ay}px) scale(${k}) rotate(0deg)`, opacity: 1 }], { duration: D, easing: ease, fill: "forwards" });
    carry.anims.push(ga);
    await ga.finished.catch(() => {});
    if (!ok()) return;
    // 4. the card takes its place; Peep drops the snap and goes home
    snapEl.classList.add("pv-cd");
    const m = flyEl.getAnimations()[0];
    const from = m ? getComputedStyle(flyEl).transform : at(tx, ty, 0.6);
    const n2 = geo(npEl, N.s || M.s["n/idle"]);
    await go([{ transform: from }, { transform: at(n2.cx, n2.cy, n2.R / R) }], { duration: 360, easing: "cubic-bezier(.5,0,.6,1)" });
    if (!ok()) return;
    carry.end(); once("done");
  };
  carry.end = () => {
    carry.anims.forEach((a) => a.cancel()); carry.anims = [];
    flyEl.remove(); players.delete(F);
    if (N) N.el.style.visibility = "";
    const ghost = snapEl && snapEl.querySelector(".ghost");
    if (ghost) ghost.getAnimations().forEach((a) => a.cancel());
    if (snapEl) snapEl.classList.remove("pv-c");
    carry.on = false;
  };
  carry.stop = (k) => {
    if (carry.on) { carry.run++; carry.end(); if (k >= 10) snapEl.classList.add("pv-cd"); }
    if (snapEl && k >= 0 && k < 10) snapEl.classList.remove("pv-cd");
  };

  /* ---------------------------------------------------------------- 4, 5 */
  hero(); footer();
  requestAnimationFrame(loop);
  // the notch's other states load once the page has settled; the snap's sheets when the snap is a screen away
  const idle = window.requestIdleCallback || ((f) => setTimeout(f, 1500));
  addEventListener("scroll", () => idle(() => Object.keys(M.s).filter((k) => k[0] === "n").forEach((k) => load(M.s[k]))), { once: true, passive: true });
  if (snapEl) new IntersectionObserver(([e], o) => {
    if (e.isIntersecting) { o.disconnect(); const f = dark.matches && M.s["fd/done"] ? "fd" : "f"; [`${f}/done`, `${f}/peck`].forEach((k) => load(M.s[k])); }
  }, { rootMargin: "100% 0px" }).observe(snapEl);

  // the hero idle loop plays while it is on screen (the poster is its first frame)
  // (light pages show the video-model clip, dark pages the clay three-quarter loop; only the one on show plays)
  function hero() {
    const vs = [...document.querySelectorAll("[data-hero]")];
    if (!vs.length || reduce) return;
    let on = false;
    const sync = () => vs.forEach((v) => {
      if (on && getComputedStyle(v).display !== "none") { v.preload = "auto"; const p = v.play(); if (p) p.catch(() => {}); } else v.pause();
    });
    new IntersectionObserver(([e]) => { on = e.isIntersecting; sync(); }).observe(vs[0].parentElement);
    matchMedia("(prefers-color-scheme: dark)").addEventListener("change", sync);
  }

  // the page ends with clay Peep peeking up from the bottom edge: three-quarter, top of the head and eyes only.
  // It rises when you get there, looks at the pointer, looks around when you stop, blinks at uneven times. Come
  // close and it ducks; the third time it stays.
  function footer() {
    const el = document.querySelector("[data-peek]");
    const L = M.peek;
    if (!el || !L) return;
    const wrap = el.parentElement;
    let ti = L.rest[0], pj = L.rest[1], lid = 0, lastP = 0, on = false, ducks = 0, ducking = false;
    const draw = () => paint(el, L, (ti * L.pitches + pj) * L.lids + lid);
    const aim = (x, y) => {
      // index 4 is the rest (three-quarter); lower turns toward the beak side, higher toward you
      // never past the three-quarter rest toward you: no front view, ever (brand book)
      ti = x > 0 ? Math.max(0, Math.round(L.rest[0] - x * L.rest[0])) : L.rest[0];
      pj = Math.max(0, Math.min(L.pitches - 1, Math.round((y * 0.5 + 0.5) * (L.pitches - 1))));
      draw();
    };
    new IntersectionObserver(([e]) => {
      if (e.isIntersecting && !el._s) load(L).then(draw);
    }, { rootMargin: "600px 0px" }).observe(wrap);
    if (reduce) return;
    new IntersectionObserver(([e]) => {
      on = e.isIntersecting; api.footer = on;
      wrap.classList.toggle("up", on);
      dispatchEvent(new Event("scroll"));
    }, { threshold: 0.6 }).observe(wrap);
    addEventListener("pointermove", (ev) => {
      if (!on) return;
      const b = el.getBoundingClientRect();
      const hx = b.left + b.width * 0.47, hy = b.top + b.height * 0.55;
      lastP = performance.now();
      aim(clamp((ev.clientX - hx) / (innerWidth * 0.4)), clamp((ev.clientY - hy) / 420));
      if (ducks < 3 && !ducking && Math.hypot(ev.clientX - hx, ev.clientY - hy) < b.width * 0.3) {
        ducking = true; ducks++;
        wrap.classList.add("duck");
        setTimeout(() => { wrap.classList.remove("duck"); setTimeout(() => { ducking = false; }, 500); }, 650);
      }
    }, { passive: true });
    (async () => { for (;;) {                      // blinks at uneven times, one in five twice
      await wait(2200 + Math.random() * 3800);
      if (!on) continue;
      const n = Math.random() < 0.2 ? 2 : 1;
      for (let k = 0; k < n; k++) { lid = 1; draw(); await wait(110); lid = 0; draw(); if (n > 1) await wait(130); }
    } })();
    (async () => { for (;;) {                      // looks around by itself when the pointer rests
      await wait(1400 + Math.random() * 2200);
      if (on && performance.now() - lastP > 2500) aim(Math.random() * 1.6 - 0.6, Math.random() * 1.2 - 0.9);
    } })();
  }
})();
