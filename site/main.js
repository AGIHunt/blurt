// blurt.agihunt.info — the recording bar, the visitor's pen, the review demo, copy, stars. No dependencies.
(() => {
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => [...r.querySelectorAll(s)];
  const html = document.documentElement;
  const NS = "http://www.w3.org/2000/svg";
  const zh = html.lang.startsWith("zh");
  const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const fine = matchMedia("(pointer: fine)").matches;
  const ink = $(".ink-layer");

  /* ---------- page-drawn pen marks: refit each path to real pixels so draw-on reaches the end ---------- */
  const pens = $$("[data-mark] > svg, svg.brace");
  const fit = () => pens.forEach((svg) => {
    const path = svg.querySelector("path");
    if (!path.dataset.d0) {
      const vb = svg.viewBox.baseVal;
      Object.assign(path.dataset, { d0: path.getAttribute("d"), vw: vb.width, vh: vb.height });
    }
    const cs = getComputedStyle(svg), W = parseFloat(cs.width), H = parseFloat(cs.height);
    if (!W || !H) return;
    const sx = W / path.dataset.vw, sy = H / path.dataset.vh;
    let i = 0;
    path.setAttribute("d", path.dataset.d0.replace(/-?\d*\.?\d+/g, (n) => (+n * (i++ % 2 ? sy : sx)).toFixed(1)));
    svg.setAttribute("viewBox", `0 0 ${W.toFixed(1)} ${H.toFixed(1)}`);
    svg.classList.add("fit");
  });

  const once = (el, fn, threshold = 0.35) => {
    if (!el) return;
    if (!("IntersectionObserver" in window)) return fn();
    const io = new IntersectionObserver((es) => es.forEach((e) => { if (e.isIntersecting) { io.disconnect(); fn(); } }), { threshold });
    io.observe(el);
  };

  /* ---------- the screen in the recording frame: a wrist-drawn loop, then the agent's box ---------- */
  const frame = $(".frame"), screen = $(".screen", frame), target = $("[data-target]", frame);
  const loopPath = $(".scribble path", frame), aibox = $(".aibox", frame);
  const rng = (s) => () => { s = (s + 0x6d2b79f5) | 0; let t = Math.imul(s ^ (s >>> 15), 1 | s); t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
  // a little over one turn, not closed, drifting outward: how a wrist circles something
  function loop(b, seed) {
    const R = rng(seed), cx = b.x + b.w / 2, cy = b.y + b.h / 2, rx = b.w / 2 + b.h * .55, ry = b.h * .5 + b.h * .5;
    const rot = -4 * Math.PI / 180, turns = 1.12, n = 26, start = -0.3, pts = [];
    for (let i = 0; i <= n; i++) {
      const k = i / n, a = start - k * turns * Math.PI * 2, s = 1 + k * .07 + (R() - .5) * .04;
      const x = Math.cos(a) * rx * s, y = Math.sin(a) * ry * s;
      pts.push([cx + x * Math.cos(rot) - y * Math.sin(rot), cy + x * Math.sin(rot) + y * Math.cos(rot)]);
    }
    const f = (v) => v.toFixed(1);
    let d = `M${f(pts[0][0])} ${f(pts[0][1])}`;
    for (let i = 0; i < pts.length - 1; i++) {
      const a = pts[i - 1] || pts[i], p = pts[i], c = pts[i + 1], e = pts[i + 2] || c;
      d += `C${f(p[0] + (c[0] - a[0]) / 6)} ${f(p[1] + (c[1] - a[1]) / 6)} ${f(c[0] - (e[0] - p[0]) / 6)} ${f(c[1] - (e[1] - p[1]) / 6)} ${f(c[0])} ${f(c[1])}`;
    }
    return d;
  }
  function placeScreen() {
    if (!target) return;
    const s = screen.getBoundingClientRect(), t = target.getBoundingClientRect();
    const b = { x: t.left - s.left, y: t.top - s.top, w: t.width, h: t.height };
    loopPath.setAttribute("d", loop(b, 7));
    Object.assign(aibox.style, { left: b.x - 7 + "px", top: b.y - 7 + "px", width: b.w + 14 + "px", height: b.h + 14 + "px" });
  }
  let boxT = 0;
  function drawScreen() {
    frame.classList.remove("drawn"); aibox.classList.remove("on"); clearTimeout(boxT);
    placeScreen();
    requestAnimationFrame(() => requestAnimationFrame(() => {
      frame.classList.add("drawn");
      boxT = setTimeout(() => aibox.classList.add("on"), reduce ? 0 : 1050);
    }));
  }

  let readRail = () => {};
  const layout = () => { fit(); placeScreen(); sizeInk(); readRail(); };
  let rz = 0;
  addEventListener("resize", () => { cancelAnimationFrame(rz); rz = requestAnimationFrame(layout); });
  if (document.fonts) document.fonts.ready.then(layout);
  layout();

  /* ---------- the recording bar: the page is the recording, so the clock follows the time rail ---------- */
  const take = $(".take"), clock = $(".clock", frame), bars = $$(".vu i", frame), cbar = $(".cbar", frame);
  const fmt = (s) => String(Math.floor(s / 60)).padStart(2, "0") + ":" + String(s % 60).padStart(2, "0");
  const level = (n) => bars.forEach((b, i) => b.classList.toggle("on", i < n));
  let intro = 0, paused = false, shown = -1, timers = [];
  const later = (ms, fn) => timers.push(setTimeout(fn, ms));
  // every [data-t] in the gutter is a point on the rail: (page y, seconds); the clock reads the rail at 35% of the viewport
  let rail = [];
  readRail = () => { rail = $$("[data-t]").map((el) => ({ y: el.getBoundingClientRect().top + scrollY, t: +el.dataset.t })).sort((a, b) => a.y - b.y); };
  function railTime() {
    if (!rail.length) return 0;
    const y = scrollY + innerHeight * 0.35;
    if (y <= rail[0].y) return rail[0].t;
    for (let i = 0; i < rail.length - 1; i++) {
      const a = rail[i], b = rail[i + 1];
      if (y < b.y) return a.t + (b.t - a.t) * (y - a.y) / Math.max(1, b.y - a.y);
    }
    return rail[rail.length - 1].t;
  }
  function tick() {
    if (paused) return;
    const t = Math.max(intro, Math.floor(railTime()));
    if (t !== shown) { shown = t; clock.textContent = fmt(t); }
  }
  function play() {
    timers.forEach(clearTimeout); timers = [];
    take.classList.remove("play"); void take.offsetWidth;
    take.classList.add("play");
    intro = 0; shown = -1; tick();
    if (reduce) return;
    [[0, 2], [60, 3], [220, 4], [400, 1], [560, 5], [900, 2]].forEach(([t, n]) => later(t, () => level(n)));
  }
  setInterval(() => { if (!paused && intro < 6) { intro += 1; tick(); } }, 1000);
  setInterval(() => { if (!paused && !reduce) level(Math.random() < .35 ? 0 : 1 + Math.floor(Math.random() * 3)); else if (paused) level(0); }, 260);
  // once the frame scrolls away the bar docks to the bottom, like the real one floats over whatever you record
  let dockQ = 0;
  const dock = () => { cbar.classList.toggle("docked", frame.getBoundingClientRect().top < 12); tick(); };
  addEventListener("scroll", () => { cancelAnimationFrame(dockQ); dockQ = requestAnimationFrame(dock); }, { passive: true });
  const fontsReady = document.fonts ? Promise.race([document.fonts.ready, new Promise((r) => setTimeout(r, 900))]) : Promise.resolve();
  fontsReady.then(() => requestAnimationFrame(() => { layout(); readRail(); play(); dock(); }));
  addEventListener("load", readRail);

  const btn = (act) => $(`[data-act="${act}"]`, frame);
  btn("pause").addEventListener("click", (e) => {
    paused = !paused;
    frame.dataset.state = paused ? "paused" : "rec";
    html.classList.toggle("paused", paused);
    if (!paused) tick();
    e.currentTarget.setAttribute("aria-pressed", paused);
    e.currentTarget.setAttribute("aria-label", paused ? (zh ? "继续" : "Resume") : (zh ? "暂停" : "Pause"));
    const v = $(".promo", frame);
    if (v && !v.hidden) paused ? v.pause() : v.play().catch(() => {});
  });
  function redo() {
    paused = false; frame.dataset.state = "rec"; html.classList.remove("paused");
    btn("pause").setAttribute("aria-pressed", "false");
    if (scrollY > 40) scrollTo({ top: 0, behavior: reduce ? "auto" : "smooth" });
    play(); drawScreen();
  }
  btn("redo").addEventListener("click", redo);
  // the real shortcut works here too: the keycaps go down and the take starts over
  const caps = $$(".keys kbd");
  addEventListener("keydown", (e) => {
    if (!(e.altKey && e.shiftKey && e.code === "KeyR")) return;
    e.preventDefault();
    caps.forEach((k) => k.classList.add("down"));
    setTimeout(() => caps.forEach((k) => k.classList.remove("down")), 220);
    redo();
  });
  btn("pen").addEventListener("click", () => setPen(!penOn));
  const doneT = $(".done-t", frame), doneLabel = doneT.textContent;
  btn("done").addEventListener("click", () => {
    doneT.textContent = doneT.dataset.busy;
    setTimeout(() => {
      doneT.textContent = doneLabel;
      $("#review").scrollIntoView({ behavior: reduce ? "auto" : "smooth", block: "center" });
      sheetBusy();
    }, reduce ? 0 : 700);
  });

  /* ---------- the film: plays inside the frame, with sound, only when asked ---------- */
  const filmBtn = $(".film-btn"), filmLabel = $("span", filmBtn).textContent;
  let film = null;
  filmBtn.addEventListener("click", () => {
    if (!film) {
      film = document.createElement("video");
      Object.assign(film, { className: "promo", src: frame.dataset.film || (zh ? "assets/promo.mp4" : "../assets/promo.mp4"), controls: true, playsInline: true, preload: "auto" });
      film.poster = zh ? "assets/poster.jpg" : "../assets/poster.jpg";
      frame.appendChild(film);
    }
    const open = film.hidden || !film.isConnected || film.dataset.open !== "1";
    film.hidden = !open; film.dataset.open = open ? "1" : "0";
    $("span", filmBtn).textContent = open ? filmBtn.dataset.close : filmLabel;
    if (open) { film.currentTime = 0; film.muted = false; film.play().catch(() => {}); } else film.pause();
  });

  /* ---------- section marks draw themselves once they scroll into view ---------- */
  once(frame, drawScreen, 0.5);
  once($(".ledger"), () => $(".ledger").classList.add("play"), 0.3);
  $$("[data-mark]").forEach((el) => { if (!el.closest(".take, .ledger")) once(el, () => el.classList.add("drawn"), 0.9); });

  // the chickens squawk only while on screen
  $$("video.chick").forEach((v) => {
    if (reduce) return;
    new IntersectionObserver((es) => es.forEach((e) => (e.isIntersecting ? v.play().catch(() => {}) : v.pause()))).observe(v);
  });

  /* ---------- the review demo: A keep, X drop, J/K move ---------- */
  const sheet = $(".sheet"), items = $$(".items li", sheet);
  const tally = (k) => $(`[data-n="${k}"]`, sheet);
  const total = +tally("left").textContent;
  let cur = 0;
  function render() {
    items.forEach((li, i) => li.classList.toggle("cur", i === cur));
    const keep = $$(".keep", sheet).length, drop = $$(".drop", sheet).length;
    tally("keep").textContent = keep; tally("drop").textContent = drop; tally("left").textContent = total - keep - drop;
  }
  function act(k) {
    if (sheet.dataset.state === "busy") return;
    const li = items[cur];
    if (k === "a" || k === "x") {
      li.classList.remove("keep", "drop"); li.classList.add(k === "a" ? "keep" : "drop");
      cur = Math.min(items.length - 1, cur + 1);
    } else if (k === "j") cur = Math.min(items.length - 1, cur + 1);
    else if (k === "k") cur = Math.max(0, cur - 1);
    else if (k === "z") li.classList.remove("keep", "drop");
    render();
  }
  function sheetBusy() {
    sheet.dataset.state = "busy";
    setTimeout(() => { sheet.dataset.state = "idle"; sheet.focus({ preventScroll: true }); }, reduce ? 0 : 1400);
  }
  $$(".sheet-f button", sheet).forEach((b) => b.addEventListener("click", () => act(b.dataset.k)));
  let sheetSeen = false;
  if ("IntersectionObserver" in window) new IntersectionObserver((es) => es.forEach((e) => { sheetSeen = e.isIntersecting; }), { threshold: 0.45 }).observe(sheet);
  addEventListener("keydown", (e) => {
    if (e.metaKey || e.ctrlKey || e.altKey || /input|textarea/i.test(e.target.tagName)) return;
    const k = e.key.toLowerCase();
    if (!"axjkz".includes(k) || k.length !== 1) return;
    if (!sheetSeen && document.activeElement !== sheet) return;
    e.preventDefault(); act(k);
  });
  render();

  /* ---------- the visitor's pen: hold ⌃ and move, or switch it on in the bar; ink fades 3 s after the last stroke ---------- */
  function sizeInk() {
    const W = html.scrollWidth, H = html.scrollHeight;
    ink.setAttribute("width", W); ink.setAttribute("height", H); ink.setAttribute("viewBox", `0 0 ${W} ${H}`);
  }
  let penOn = false, stroke = null, mouse = null, fadeT = 0;
  const hints = $$(".pen-hint span");
  hints.forEach((el) => { el.dataset.off = el.textContent; });
  function setPen(on) {
    penOn = on;
    btn("pen").setAttribute("aria-pressed", on);
    html.classList.toggle("pen-on", on);
    // say how to get out while it's on — the app learned this the hard way
    hints.forEach((el) => { el.textContent = on ? el.parentElement.dataset.on : (fine ? el.dataset.off : el.parentElement.dataset.touch); });
  }
  const blocked = (t) => t.closest && t.closest("a, button, .cmd, .sheet, video, kbd");
  function begin(x, y) {
    clearTimeout(fadeT);
    sizeInk();
    const p = document.createElementNS(NS, "path");
    ink.appendChild(p);
    stroke = { p, pts: [[x, y]] };
    html.classList.add("drawing");
  }
  function move(x, y) {
    if (!stroke) return;
    const q = stroke.pts, l = q[q.length - 1];
    if (Math.hypot(x - l[0], y - l[1]) < 2) return;
    q.push([x, y]);
    let d = `M${q[0][0]} ${q[0][1]}`;
    for (let i = 1; i < q.length - 1; i++) d += `Q${q[i][0]} ${q[i][1]} ${(q[i][0] + q[i + 1][0]) / 2} ${(q[i][1] + q[i + 1][1]) / 2}`;
    d += `L${q[q.length - 1][0]} ${q[q.length - 1][1]}`;
    stroke.p.setAttribute("d", d);
  }
  function end() {
    if (!stroke) return;
    if (stroke.pts.length < 3) stroke.p.remove();
    stroke = null; html.classList.remove("drawing");
    clearTimeout(fadeT);
    // like the app: the whole group fades together, so two circles can land in the same frame
    fadeT = setTimeout(() => {
      const ps = $$("path", ink);
      ps.forEach((p) => p.classList.add("gone"));
      setTimeout(() => ps.forEach((p) => p.remove()), 600);
    }, 3000);
  }
  const page = (e) => [e.clientX + scrollX, e.clientY + scrollY];
  addEventListener("pointerdown", (e) => {
    if (!penOn || e.button !== 0 || blocked(e.target)) return;
    e.preventDefault(); begin(...page(e));
  });
  addEventListener("pointermove", (e) => {
    mouse = page(e);
    if (stroke) move(...mouse);
  });
  addEventListener("pointerup", () => { if (!keyPen) end(); });
  addEventListener("pointercancel", end);
  let keyPen = false;
  addEventListener("keydown", (e) => { if (e.key === "Escape" && penOn) { end(); setPen(false); } });
  addEventListener("keydown", (e) => {
    if (e.key !== "Control" || e.repeat || !mouse || stroke) return;
    keyPen = true; begin(...mouse);
  });
  addEventListener("keyup", (e) => { if (e.key === "Control" && keyPen) { keyPen = false; end(); } });
  addEventListener("scroll", () => { if (stroke && keyPen && mouse) move(mouse[0], mouse[1]); }, { passive: true });
  addEventListener("blur", () => { keyPen = false; end(); });
  addEventListener("contextmenu", (e) => { if (stroke) e.preventDefault(); });
  if (!fine) {
    $$(".pen-hint").forEach((el) => { $("span", el).textContent = el.dataset.touch; $("kbd", el).innerHTML = '<svg viewBox="0 0 20 20" width="16" height="16" aria-hidden="true"><path d="M3.5 15.5C5.6 11 8.4 5 10.6 5c2 0-2.9 9.4-.4 9.4 1.7 0 2.5-3.6 4.1-3.6 1.2 0 .6 2.9 2.2 2.9" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"/></svg>'; });
    $$(".try[data-touch]").forEach((el) => { el.textContent = el.dataset.touch; });
  }

  /* ---------- copy the install command ---------- */
  $$(".cmd").forEach((box) => {
    const b = $(".copy", box), code = $(".cmd-t", box), label = b.textContent;
    b.addEventListener("click", async () => {
      try { await navigator.clipboard.writeText(code.textContent.trim()); }
      catch {
        const r = document.createRange(); r.selectNodeContents(code);
        const s = getSelection(); s.removeAllRanges(); s.addRange(r);
        return; // selected instead: ⌘C still works
      }
      b.textContent = b.dataset.done; b.classList.add("ok");
      setTimeout(() => { b.textContent = label; b.classList.remove("ok"); }, 1600);
    });
  });

  /* ---------- only Macs get the zip ---------- */
  if (!/Mac/i.test(navigator.platform || navigator.userAgent) || /iPhone|iPad/i.test(navigator.userAgent)) {
    $$(".btn-dl[data-other]").forEach((a) => {
      a.href = "https://github.com/AGIHunt/blurt/releases/latest";
      $("span", a).textContent = a.dataset.other;
      const s = $("small", a); if (s) s.remove();
    });
  }

  /* ---------- GitHub stars: show nothing rather than a wrong number ---------- */
  const stars = $$(".stars");
  const show = (n) => stars.forEach((el) => { el.textContent = n >= 1000 ? (n / 1000).toFixed(1).replace(/\.0$/, "") + "k" : String(n); el.hidden = false; });
  try {
    const cached = sessionStorage.getItem("blurt-stars");
    if (cached) show(+cached);
    else fetch("https://api.github.com/repos/AGIHunt/blurt").then((r) => (r.ok ? r.json() : null)).then((d) => {
      if (d && Number.isFinite(d.stargazers_count)) { sessionStorage.setItem("blurt-stars", d.stargazers_count); show(d.stargazers_count); }
    }).catch(() => {});
  } catch {}

  addEventListener("load", layout);
})();
