// blurt.agihunt.info — the recording bar (with 📸, live captions and the nest of live drafts), the visitor's pen, the review demo,
// the playable snap-mode desk, copy, stars. No dependencies.
(() => {
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => [...r.querySelectorAll(s)];
  const html = document.documentElement;
  const NS = "http://www.w3.org/2000/svg";
  const zh = html.lang.startsWith("zh");
  const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const fine = matchMedia("(pointer: fine)").matches;
  const ink = $(".ink-layer");
  const EGG = (k, cls = "") => `<svg class="egg ${cls}" viewBox="0 0 16 16" aria-hidden="true"><use href="#egg-${k}"/></svg>`;
  const esc = (t) => t.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
  const bump = (el) => { el.classList.remove("bump"); void el.offsetWidth; el.classList.add("bump"); };
  let deskOwns = () => false; // the snap desk's review takes A/X/J/K/Z while it's on screen
  let snapKey = () => {};

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
    if (t !== shown) { shown = t; clock.textContent = fmt(t); layEggs(t); }
  }
  // live captions under the bar, and an egg in the nest each time a draft item takes shape (times match the sheet below)
  const cap = $(".cap", frame), nest = $(".nest", frame), nestEggs = $(".eggs", nest), nestN = $("b", nest);
  // @fonts:system-ui-start (strings below render in the system UI font, not the self-hosted subsets)
  const CAPS = zh ? [[150, "这里不对……"], [1050, "……这个按钮抽……"], [2050, "……不对，是那个"]]
    : [[150, "this bit's off…"], [1050, "…this butter looks weird…"], [2050, "…no, not that one"]];
  // @fonts:system-ui-end
  let capT = 0;
  function say(text, ms) { cap.textContent = text; cap.classList.add("on"); clearTimeout(capT); capT = setTimeout(() => cap.classList.remove("on"), ms); }
  const DRAFTS = [[3, "issue"], [72, "idea"], [80, "task"], [167, "issue"], [196, "idea"], [262, "note"], [318, "task"], [392, "issue"], [446, "idea"]];
  let laid = 0;
  function layEggs(t) {
    const n = DRAFTS.filter(([at]) => at <= t).length;
    if (n <= laid) return;
    DRAFTS.slice(laid, n).forEach(([, k]) => {
      nestEggs.insertAdjacentHTML("beforeend", EGG(k, reduce ? "" : "drop"));
      while (nestEggs.children.length > 3) nestEggs.firstElementChild.remove();
    });
    laid = n; nest.hidden = false; nestN.textContent = n; bump(nestN);
    nest.setAttribute("aria-label", (zh ? "实时草稿：" : "Live drafts: ") + n);
  }
  function play() {
    timers.forEach(clearTimeout); timers = [];
    take.classList.remove("play"); void take.offsetWidth;
    take.classList.add("play");
    intro = 0; shown = -1; laid = 0; nestEggs.innerHTML = ""; nest.hidden = true; tick();
    CAPS.forEach(([ms, text], i) => later(ms, () => say(text, i === CAPS.length - 1 ? 2600 : 1400)));
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
    snaps = 0; badge.hidden = true;
    paused = false; frame.dataset.state = "rec"; html.classList.remove("paused");
    btn("pause").setAttribute("aria-pressed", "false");
    if (scrollY > 40) scrollTo({ top: 0, behavior: reduce ? "auto" : "smooth" });
    play(); drawScreen();
  }
  btn("redo").addEventListener("click", redo);
  // the real shortcut works here too: the keycaps go down and the take starts over
  const caps = $$(".keys kbd");
  addEventListener("keydown", (e) => {
    if (e.altKey && e.shiftKey && e.code === "KeyA") { e.preventDefault(); return snapKey(); }
    if (!(e.altKey && e.shiftKey && e.code === "KeyR")) return;
    e.preventDefault();
    caps.forEach((k) => k.classList.add("down"));
    setTimeout(() => caps.forEach((k) => k.classList.remove("down")), 220);
    redo();
  });
  btn("pen").addEventListener("click", () => setPen(!penOn));
  // 📸 while recording: no pause, no popup; the frame's border flashes (the border itself is never recorded)
  const badge = $(".badge", btn("snap"));
  let snaps = 0;
  function heroSnap() {
    snaps += 1; badge.hidden = false; badge.textContent = snaps; bump(badge);
    frame.classList.remove("snapped"); void frame.offsetWidth; frame.classList.add("snapped");
    if (!reduce && frame.getBoundingClientRect().bottom > 0) {
      const f = document.createElement("i"); f.className = "shutter"; frame.appendChild(f);
      f.addEventListener("animationend", () => f.remove());
    }
  // @fonts:system-ui-start (strings below render in the system UI font, not the self-hosted subsets)
    if (!cbar.classList.contains("docked")) say(zh ? "📸 截下这一刻，录制没停" : "📸 snapped, still recording", 1600);
  // @fonts:system-ui-end
  }
  btn("snap").addEventListener("click", heroSnap);
  snapKey = heroSnap;
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
  once($(".after"), () => $(".after").classList.add("play"), 0.6);
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
  // like the real page now: the transcript is ready, so the items come first and show up one by one
  function sheetBusy() {
    sheet.dataset.state = "busy"; sheet.classList.remove("fill");
    setTimeout(() => { sheet.dataset.state = "idle"; sheet.classList.add("fill"); sheet.focus({ preventScroll: true }); }, reduce ? 0 : 1000);
  }
  $$(".sheet-f button", sheet).forEach((b) => b.addEventListener("click", () => act(b.dataset.k)));
  let sheetSeen = false;
  if ("IntersectionObserver" in window) new IntersectionObserver((es) => es.forEach((e) => { sheetSeen = e.isIntersecting; }), { threshold: 0.45 }).observe(sheet);
  addEventListener("keydown", (e) => {
    if (e.metaKey || e.ctrlKey || e.altKey || /input|textarea/i.test(e.target.tagName)) return;
    const k = e.key.toLowerCase();
    if (!"axjkz".includes(k) || k.length !== 1) return;
    if ((!sheetSeen && document.activeElement !== sheet) || deskOwns()) return;
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
  const blocked = (t) => t.closest && t.closest("a, button, .cmd, .sheet, .desk, video, kbd");
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

  // @fonts:system-ui-start (strings below render in the system UI font, not the self-hosted subsets)
  /* ---------- snap mode, playable: ⌥⇧A → drag → flash → onto the perch → one sentence → 🐔 sort → eggs → A/X ---------- */
  const desk = $(".desk");
  if (desk) (() => {
    const app = $(".app", desk), mb = $(".mb", desk), hang = $(".hang", desk), hatchB = $(".hatch", desk), hatchN = $("b", hatchB);
    const snapBtn = $(".snap-btn", desk), sel = $(".sel", desk), box = $(".sel-box", sel), boxN = $("b", box), win = $(".sel-win", sel);
    const note = $(".note", desk), inp = $("input", note), hint = $("small", note);
    const rv = $(".rv", desk), list = $(".rv-list", rv), st = $(".rv-st", rv), stT = $(":scope > span", st), fin = $(".rv-done", rv), rvF = $(".rv-f", rv);
    const coach = $(".coach", desk), small = () => matchMedia("(max-width: 760px)").matches;
    const L = zh ? {
      lines: [
        { kind: "issue", said: "这个按钮点了没反应", title: "Export CSV 点了没反应" },
        { kind: "idea", said: "这里空着，放个本周用量趋势就好了", title: "用量卡片里放一张本周趋势图" },
        { kind: "task", said: "记一下，发票要能下载 PDF", title: "发票列表加「下载 PDF」" },
        { kind: "note", said: "套餐名这么长，客户看得懂吗", title: "套餐名称偏长，待确认" },
      ],
      kinds: { issue: "问题", idea: "想法", note: "笔记", task: "待办" },
      coach: [
        fine ? "按 ⌥⇧A，或者点这里截图。" : "点这里截图。",
        fine ? "拖出一块，松手就截好了。点一下 = 整个窗口，Esc 取消。" : "手指拖出一块，松手就截好了。点一下 = 整个窗口。",
        "截完直接说，停一下就收好。这里替你说了一句；想自己写，点气泡打字。",
        fine ? "挂上鸡舍了。再按 ⌥⇧A 截一张，或者点「🐔 整理」交给 agent。" : "挂上鸡舍了。再截一张，或者点「🐔 整理」交给 agent。",
        fine ? "一条一颗蛋。A 保留 · X 丢弃 · J 下一条。" : "一条一颗蛋。点「保留」或「丢弃」。",
      ],
      full: "鸡舍挂满了，点「🐔 整理」吧。",
      hint: fine ? "Enter 保存 · Esc 丢弃 · ⌥⇧A 下一张" : "回车保存 · 点别处也行",
      saved: "✓ 已保存", skipped: "没写备注，也挂上了", copied: "✓ 已复制", bare: "一张没写备注的截图", noNote: "（没有备注）",
      card: (n, t) => `第 ${n} 张截图${t ? "：" + t : ""}。单击复制，双击改备注`, del: "扔掉这张",
      q: (t) => `「${t}」`,
      st: (n, k, m) => `整理中… 已出 ${n} 条，截图补充中 ${k}/${m}`, done: "✓ 整理完了",
      end: (k, d) => `审完了：保留 ${k} 条，丢弃 ${d} 条。接下来导出到飞书、GitHub，或者直接说「帮我改掉」。`,
      rules: [[/记一下|记得|待办|todo|要找|找.{1,6}要/i, "task"], [/没反应|不对|错|bug|崩|卡住|丑|坏|不了|没用|看不清/i, "issue"], [/要|应该|放个|加个|可以|想|最好|如果/, "idea"]],
    } : {
      lines: [
        { kind: "issue", said: "I click this button and nothing happens", title: "Export CSV does nothing on click" },
        { kind: "idea", said: "this is empty, a weekly usage trend would be nice", title: "Show a weekly trend in the usage card" },
        { kind: "task", said: "note to self: invoices need a PDF download", title: "Add “Download PDF” to invoices" },
        { kind: "note", said: "that plan name is long, will customers get it?", title: "Plan name may be too long" },
      ],
      kinds: { issue: "issue", idea: "idea", note: "note", task: "task" },
      coach: [
        fine ? "Press ⌥⇧A, or click here to snap." : "Tap here to snap.",
        fine ? "Drag an area and let go, that's the shot. A click takes the whole window, Esc cancels." : "Drag an area with your finger and let go. A tap takes the whole window.",
        "Then just say it, and pause. We said a line for you here; to write your own, click the bubble and type.",
        fine ? "It's on the perch. Press ⌥⇧A for another, or hit “🐔 Sort” to hand them to your agent." : "It's on the perch. Snap another, or tap “🐔 Sort” to hand them to your agent.",
        fine ? "One item, one egg. A keeps · X drops · J moves on." : "One item, one egg. Tap Keep or Drop.",
      ],
      full: "The perch is full. Hit “🐔 Sort”.",
      hint: fine ? "Enter saves · Esc discards · ⌥⇧A next shot" : "Return saves · or tap elsewhere",
      saved: "✓ saved", skipped: "no note, hung up anyway", copied: "✓ copied", bare: "A screenshot without a note", noNote: "(no note)",
      card: (n, t) => `Screenshot ${n}${t ? ": " + t : ""}. Click to copy, double-click to edit the note`, del: "Toss this one",
      q: (t) => `“${t}”`,
      st: (n, k, m) => `Sorting… ${n} items so far, frames ${k}/${m}`, done: "✓ all sorted",
      end: (k, d) => `Done: ${k} kept, ${d} dropped. Next, export to Lark or GitHub, or just say “fix these”.`,
      rules: [[/\b(todo|to-do|remember|note to self|ask|need to)\b/i, "task"], [/nothing happens|broken|bug|wrong|doesn'?t|does not|crash|ugly|can'?t|unreadable/i, "issue"], [/should|would be nice|could|idea|maybe|let'?s|want|how about/i, "idea"]],
    };
    const classify = (t) => (L.rules.find(([r]) => r.test(t)) || [, "note"])[1];
    const MAX = () => (small() ? 3 : 6);
    let state = "idle", shots = [], batch = [], cur = 0, seq = 0, curNote = null, typing = false, typeT = 0, gen = 0, coachOff = false, coachAt = null;
    const set = (s) => { state = s; desk.dataset.state = s; hatchB.disabled = !shots.length || s === "hatch" || s === "review"; };
    // geometry in the desk's own coordinates
    const R = (el) => {
      const d = desk.getBoundingClientRect(), r = el.getBoundingClientRect();
      return { x: r.left - d.left - desk.clientLeft, y: r.top - d.top - desk.clientTop, w: r.width, h: r.height };
    };
    const local = (e) => { const d = desk.getBoundingClientRect(); return [e.clientX - d.left - desk.clientLeft, e.clientY - d.top - desk.clientTop]; };
    const inter = (a, b) => {
      const x = Math.max(a.x, b.x), y = Math.max(a.y, b.y), w = Math.min(a.x + a.w, b.x + b.w) - x, h = Math.min(a.y + a.h, b.y + b.h) - y;
      return w > 0 && h > 0 ? { x, y, w, h } : null;
    };
    const norm = ([x0, y0], [x1, y1]) => {
      const W = desk.clientWidth, H = desk.clientHeight;
      x1 = Math.max(0, Math.min(W, x1)); y1 = Math.max(0, Math.min(H, y1));
      return { x: Math.min(x0, x1), y: Math.min(y0, y1), w: Math.abs(x1 - x0), h: Math.abs(y1 - y0) };
    };
    const put = (el, r) => Object.assign(el.style, { left: r.x + "px", top: r.y + "px", width: r.w + "px", height: r.h + "px" });
    const hhmm = () => new Date().toTimeString().slice(0, 5);
    mb.querySelector(".mb-r").lastChild.textContent = hhmm();
    if (!fine) { $("kbd", snapBtn).remove(); $("span", snapBtn).textContent = snapBtn.dataset.touch; $(".sel-hint", sel).textContent = $(".sel-hint", sel).dataset.touch; }
    inp.setAttribute("enterkeyhint", "done");

    /* coach marks: one step at a time, pointing at the thing to touch */
    function tip(n, el, dir, text) {
      coachAt = [el, dir];
      if (coachOff || !el) return (coach.hidden = true);
      $(".c-n", coach).textContent = n ? `${n} / 5` : "";
      $(".c-t", coach).textContent = text || L.coach[n - 1];
      coach.hidden = false; placeCoach();
    }
    function placeCoach() {
      if (!coachAt || coach.hidden) return;
      const [el, dir] = coachAt, r = R(el), W = desk.clientWidth, cw = coach.offsetWidth, ch = coach.offsetHeight;
      const x = Math.max(8, Math.min(W - cw - 8, r.x + r.w / 2 - cw / 2));
      const y = dir === "above" ? r.y - ch - 12 : r.y + r.h + 12;
      Object.assign(coach.style, { left: x + "px", top: Math.max(30, Math.min(desk.clientHeight - ch - 6, y)) + "px" });
      coach.style.setProperty("--ax", Math.max(14, Math.min(cw - 14, r.x + r.w / 2 - x)) + "px");
      coach.dataset.dir = dir;
    }
    const untip = () => { coach.hidden = true; coachAt = null; };
    $(".c-x", coach).addEventListener("click", () => { coachOff = true; untip(); });

    /* the perch: a twine rope between two pegs, simulated as a damped string (the app's Rope.swift model and numbers).
       Every shot hangs its weight on it, so the rope sags with the cards and stiffens as the load grows; a shot hangs
       at the rope's height, tilts with its slope and swings as a pendulum around that tilt. Hanging one dips the rope,
       tossing one (or sorting, 80 ms apart) drops the load and it springs up past rest, hovering one lifts its weight off,
       and now and then a breeze passes. */
    const perch = $(".perch", desk), rope = $(".rope", perch);
    const ropeLine = (c) => $(`.rope-${c}`, rope), twist = ropeLine("twist"), ends = $$(".rope-end", rope);
    const ropeLines = ["sh", "edge", "body", "shine"].map(ropeLine);
    const RN = 48, RY0 = 9, RX = 16, PERIOD = 0.62, REST = 10, CARD = 5, GAMMA = 4, BETA = 0.0018;
    // discrete string, unit node spacing: fundamental ω = 2√T·sin(π/2N) → T = (π/PERIOD / sin(π/2N))²;
    // rest sag W·N²/8T = REST; a load P at the middle sags P·N/4T = CARD
    const T0 = (Math.PI / PERIOD / Math.sin(Math.PI / (2 * RN))) ** 2, W0 = REST * 8 * T0 / (RN * RN), P0 = CARD * 4 * T0 / RN;
    // the tension stiffens with the total load: sag 10 / 15 / 18.4 / 23.8 / 27.9 px for 0 / 1 / 2 / 4 / 8 cards at the middle
    const STIFF = [[0, 1], [1, 1], [2, 20 / 18.4], [4, 30 / 23.8], [8, 50 / 27.9]];
    const stiff = (w) => { for (let i = 1; i < STIFF.length; i++) { const [a, ta] = STIFF[i - 1], [b, tb] = STIFF[i]; if (w <= b) return ta + (tb - ta) * Math.max(0, w - a) / (b - a); } return STIFF[STIFF.length - 1][1] + (w - 8) * 0.03; };
    const ry = new Float64Array(RN + 1), rvel = new Float64Array(RN + 1), load = new Float64Array(RN + 1), racc = new Float64Array(RN + 1);
    let rx0 = RX, rx1 = 300, rq = 0, rlast = 0, rliveUntil = 0, tau = 1;
    const cardX = (s) => s.el.offsetLeft + s.el.offsetWidth / 2;
    const gap = () => (rx1 - rx0) / RN;
    const node = (x) => Math.max(0, Math.min(RN, (x - rx0) / gap()));
    const ropeAt = (x) => { const u = node(x), i = Math.min(RN - 1, Math.floor(u)), f = u - i; return ry[i] + (ry[i + 1] - ry[i]) * f; };
    const slopeDeg = (x) => { const u = node(x), i = Math.max(1, Math.min(RN - 1, Math.round(u))); return Math.atan((ry[i + 1] - ry[i - 1]) / (2 * gap())) * 180 / Math.PI; };
    function loads() {
      let w = 0;
      load.fill(0);
      shots.forEach((s) => {
        if (!s.onRope) return;
        s.cx = cardX(s);
        const k = s.hold ? 0 : 1; // a hovered card is lifted: it weighs nothing
        w += k;
        const u = node(s.cx), i = Math.min(RN - 1, Math.floor(u)), f = u - i;
        load[i] += P0 * k * (1 - f); load[i + 1] += P0 * k * f;
      });
      tau = stiff(w);
    }
    function stepRope(dt) {
      const n = Math.max(1, Math.ceil(dt / 0.0025)), h = dt / n, T = T0 * tau;
      for (let k = 0; k < n; k++) {
        for (let i = 1; i < RN; i++) {
          const lap = ry[i - 1] - 2 * ry[i] + ry[i + 1], lapv = rvel[i - 1] - 2 * rvel[i] + rvel[i + 1];
          racc[i] = T * (lap + BETA * lapv) + W0 + load[i] - GAMMA * rvel[i];
        }
        for (let i = 1; i < RN; i++) { rvel[i] += racc[i] * h; ry[i] += rvel[i] * h; }
      }
    }
    function restRope() { // reduced motion: straight to where the rope comes to rest
      rvel.fill(0);
      const T = T0 * tau;
      for (let it = 0; it < 4000; it++) for (let i = 1; i < RN; i++) ry[i] = (ry[i - 1] + ry[i + 1] + (W0 + load[i]) / T) / 2;
    }
    // tug: v += amp·exp(-(d/spread)²) px/s along the rope (+ is down)
    function tug(x, amp, spread) {
      if (reduce || x == null) return;
      for (let i = 1; i < RN; i++) { const d = rx0 + i * gap() - x; rvel[i] += amp * Math.exp(-((d / spread) ** 2)); }
    }
    function drawRope() {
      const g = gap(), P = [];
      for (let i = 0; i <= RN; i++) P.push([rx0 + i * g, RY0 + ry[i]]);
      const f = (v) => v.toFixed(2);
      let d = `M${f(P[0][0])} ${f(P[0][1])}`;
      for (let i = 0; i < RN; i++) {
        const a = P[i - 1] || P[i], p = P[i], c = P[i + 1], e = P[i + 2] || c;
        d += `C${f(p[0] + (c[0] - a[0]) / 6)} ${f(p[1] + (c[1] - a[1]) / 6)} ${f(c[0] - (e[0] - p[0]) / 6)} ${f(c[1] - (e[1] - p[1]) / 6)} ${f(c[0])} ${f(c[1])}`;
      }
      ropeLines.forEach((l) => l.setAttribute("d", d));
      // the twist: short slanted strokes across the cord every 3.2 px along it
      let t = "", next = 1.6, run = 0;
      for (let i = 0; i < RN; i++) {
        const [x0, y0] = P[i], [x1, y1] = P[i + 1], L = Math.hypot(x1 - x0, y1 - y0), tx = (x1 - x0) / L, ty = (y1 - y0) / L;
        for (; next < run + L; next += 3.2) {
          const s = next - run, x = x0 + tx * s, y = y0 + ty * s;
          t += `M${f(x - ty * 1.2 - tx * 0.9)} ${f(y + tx * 1.2 - ty * 0.9)}L${f(x + ty * 1.2 + tx * 0.9)} ${f(y - tx * 1.2 + ty * 0.9)}`;
        }
        run += L;
      }
      twist.setAttribute("d", t);
    }
    function placeCards(dt) {
      shots.forEach((s) => {
        if (!s.sw) return;
        if (s.tilt0 == null) s.tilt0 = (Math.random() * 2 - 1) * 2.5;
        const x = s.cx ?? cardX(s), dy = ropeAt(x), target = 0.85 * slopeDeg(x);
        if (s.th == null || !dt) { if (s.th == null || reduce) { s.th = target; s.v = 0; } }
        else { s.v += (-46 * (s.th - target) - (s.hold ? 16 : 3.4) * s.v) * dt; s.th += s.v * dt; }
        s.sw.style.transform = `translateY(${dy.toFixed(2)}px) rotate(${(s.th + s.tilt0).toFixed(2)}deg)`;
      });
    }
    function sizeRope() {
      const W = perch.clientWidth, H = perch.clientHeight;
      rx0 = RX; rx1 = Math.max(rx0 + 40, W - RX);
      rope.setAttribute("width", W); rope.setAttribute("height", H); rope.setAttribute("viewBox", `0 0 ${W} ${H}`);
      ends.forEach((e, i) => e.setAttribute("transform", `translate(${i ? rx1 : rx0} ${RY0})${i ? " scale(-1 1)" : ""}`));
      wake();
    }
    function wake() {
      if (reduce) { loads(); restRope(); placeCards(0); return drawRope(); }
      rliveUntil = performance.now() + 400;
      if (!rq) { rlast = performance.now(); rq = requestAnimationFrame(tick); }
    }
    function kick(s, v) { if (!reduce && s.sw) s.v = (s.v || 0) + v; wake(); }
    function tick(now) {
      const dt = Math.min(0.034, (now - rlast) / 1000); rlast = now;
      loads(); stepRope(dt); placeCards(dt); drawRope();
      let live = now < rliveUntil;
      for (let i = 1; i < RN && !live; i++) if (Math.abs(rvel[i]) > 1.5) live = true;
      shots.forEach((s) => { if (Math.abs(s.v || 0) > 0.05) live = true; });
      rq = live ? requestAnimationFrame(tick) : 0;
    }
    // a breeze every 7–16 s while the perch is out: ±45 px/s somewhere in the middle half
    (function breeze() {
      setTimeout(() => {
        if (!reduce && shots.length && document.visibilityState === "visible") {
          const W = rx1 - rx0; tug(rx0 + W * (0.25 + Math.random() * 0.5), (Math.random() < 0.5 ? -1 : 1) * 45, 0.2 * W); wake();
        }
        breeze();
      }, 7000 + Math.random() * 9000);
    })();
    sizeRope(); loads(); restRope(); drawRope();
    const cardW = () => { const w = desk.clientWidth; return Math.round(small() ? Math.max(52, Math.min(72, w * 0.17)) : Math.max(56, Math.min(112, w * 0.125))); };
    // the shot is a scaled clone of the app (pure DOM, sized in em), cropped to what was selected
    function shoot(r, W, H) {
      const a = R(app), c = app.cloneNode(true);
      const s = Math.max(W / r.w, H / r.h), ox = r.x - a.x - (W / s - r.w) / 2, oy = r.y - a.y - (H / s - r.h) / 2;
      c.className = "app clone"; c.querySelectorAll("[data-say]").forEach((el) => el.removeAttribute("data-say"));
      Object.assign(c.style, { width: a.w + "px", height: a.h + "px", fontSize: getComputedStyle(app).fontSize, left: "0", top: "0", right: "auto", bottom: "auto", borderRadius: "0", boxShadow: "none",
        transform: `scale(${s.toFixed(4)}) translate(${(-ox).toFixed(1)}px, ${(-oy).toFixed(1)}px)` });
      return c;
    }
    function pick(r) {
      let best = -1, score = 0;
      $$("[data-say]", app).forEach((el) => {
        const i = +el.dataset.say, b = R(el), o = inter(r, b), f = o ? (o.w * o.h) / (b.w * b.h) : 0;
        const v = f + (shots.some((s) => s.say === i) || batchSaid.has(i) ? 0 : 1.5) * (f > 0);
        if (v > score) { score = v; best = i; }
      });
      if (best >= 0) return best;
      const free = [0, 1, 2, 3].find((i) => !shots.some((s) => s.say === i));
      return free ?? 0;
    }
    const batchSaid = new Set();
    function capture(r) {
      endSelect(); untip();
      snapBtn.focus({ preventScroll: true }); // the overlay that had focus is gone; keep keyboard users inside the desk
      const a = R(app);
      let c = inter(r, a);
      if (!c || c.w < 10 || c.h < 10) c = a;
      const say = pick(c);
      if (!reduce) { const f = document.createElement("i"); f.className = "flash"; put(f, r); desk.appendChild(f); f.addEventListener("animationend", () => f.remove()); }
      const shot = { n: ++seq, r: c, say, line: L.lines[say], text: "", a: 0, v: 0 };
      shots.push(shot); batchSaid.add(say);
      hangUp(shot, r);
      desk.classList.add("has-shots"); count();
      setTimeout(() => startNote(shot), reduce ? 60 : 640);
    }
    function hangUp(s, from) {
      const W = cardW(), H = Math.round(W * Math.max(0.56, Math.min(1, s.r.h / s.r.w)));
      const li = document.createElement("li");
      li.className = "card";
      li.innerHTML = `<div class="sw"><svg class="claw" viewBox="0 0 14 20" aria-hidden="true"><use href="#claw"/></svg><button type="button" class="pol"><span class="ph" style="--w:${W}px;--h:${H}px"></span><span class="ts"><span>${hhmm()}</span><i></i></span><span class="stamp">${L.copied}</span></button><button type="button" class="x" aria-label="${L.del}">×</button><span class="tip"></span></div>`;
      const ph = $(".ph", li), pol = $(".pol", li);
      ph.appendChild(shoot(s.r, W, H));
      pol.setAttribute("aria-label", L.card(s.n, ""));
      hang.appendChild(li);
      Object.assign(s, { el: li, sw: $(".sw", li), ph, W, H });
      placeCards(0); // its slot sits on the rope as it hangs right now
      // fly from the selection to the slot (FLIP), then clip onto the rope: its weight pulls the rope down and it swings in
      if (!shots.some((o) => o !== s)) tug((rx0 + rx1) / 2, -30, 0.6 * (rx1 - rx0)); // the strip slides down: the rope lags a little
      if (reduce) { s.onRope = true; wake(); }
      else {
        const to = R(pol), o = R(li), dx = from.x - to.x, dy = from.y - to.y;
        li.style.transformOrigin = `${to.x - o.x}px ${to.y - o.y}px`;
        li.style.transform = `translate(${dx}px, ${dy}px) scale(${from.w / to.w}, ${from.h / to.h})`;
        $(".claw", li).style.opacity = "0";
        void li.offsetWidth;
        li.style.transition = "transform .6s cubic-bezier(.2,.8,.25,1)";
        li.style.transform = "";
        const land = () => {
          li.style.transition = ""; li.style.transformOrigin = ""; $(".claw", li).style.opacity = "";
          s.onRope = true; tug(cardX(s), 300, 120); wake();
          kick(s, Math.max(-120, Math.min(120, dx * 0.5)) + (dx >= 0 ? 45 : -45));
          shots.forEach((o2) => { if (o2 !== s) kick(o2, (Math.random() - 0.5) * 40); });
        };
        li.addEventListener("transitionend", land, { once: true });
      }
      li.addEventListener("pointerenter", () => { s.hold = true; wake(); });
      li.addEventListener("pointerleave", () => { s.hold = false; wake(); });
      let clickT = 0;
      pol.addEventListener("click", (e) => {
        clearTimeout(clickT);
        if (e.detail > 1) return;
        clickT = setTimeout(() => { li.classList.add("copied"); setTimeout(() => li.classList.remove("copied"), 900); }, e.detail ? 230 : 0);
      });
      pol.addEventListener("dblclick", () => { clearTimeout(clickT); if (state === "idle" || state === "note") { if (curNote && curNote !== s) save(); startNote(s, true); } });
      $(".x", li).addEventListener("click", () => toss(s));
    }
    function toss(s) {
      if (state === "hatch" || state === "review") return;
      if (curNote === s) { curNote = null; clearTimeout(typeT); hideNote(true); set("idle"); }
      s.el.classList.add("fall");
      const x = s.cx ?? cardX(s); s.onRope = false;
      shots = shots.filter((o) => o !== s); batchSaid.delete(s.say);
      count(); tug(x, -70, 90); wake(); // the load is gone: the rope springs up and overshoots
      setTimeout(() => { s.el.remove(); wake(); }, reduce ? 400 : 760);
      if (!shots.length) { desk.classList.remove("has-shots"); tip(1, snapBtn, "above"); }
    }
    const count = () => { hatchN.textContent = shots.length; set(state); };

    /* selecting: dim the screen, drag a box, a plain click takes the window under it */
    function beginSelect() {
      if (state === "hatch" || state === "review" || state === "select") return;
      if (curNote) save();
      if (shots.length >= MAX()) return tip(0, hatchB, "below", L.full);
      set("select"); sel.hidden = false; sel.classList.remove("dragging", "over-win");
      sel.focus({ preventScroll: true });
      tip(2, mb, "below");
    }
    function endSelect() { sel.hidden = true; p0 = null; sel.classList.remove("dragging", "over-win"); if (state === "select") set("idle"); }
    let p0 = null;
    sel.addEventListener("pointerdown", (e) => {
      if (e.button) return;
      e.preventDefault(); sel.setPointerCapture(e.pointerId); p0 = local(e);
    });
    sel.addEventListener("pointermove", (e) => {
      const q = local(e);
      if (!p0) {
        const a = R(app), over = q[0] >= a.x && q[0] <= a.x + a.w && q[1] >= a.y && q[1] <= a.y + a.h;
        sel.classList.toggle("over-win", over); if (over) put(win, a);
        return;
      }
      const r = norm(p0, q);
      if (r.w > 4 || r.h > 4) sel.classList.add("dragging");
      put(box, r); boxN.textContent = `${Math.round(r.w * 2)} × ${Math.round(r.h * 2)}`;
    });
    sel.addEventListener("pointerup", (e) => {
      if (!p0) return;
      const r = norm(p0, local(e)); p0 = null;
      capture(r.w < 14 || r.h < 14 ? R(app) : r);
    });
    sel.addEventListener("pointercancel", () => { p0 = null; sel.classList.remove("dragging"); });
    sel.addEventListener("keydown", (e) => {
      if (e.key === "Escape") { e.preventDefault(); e.stopPropagation(); endSelect(); tip(shots.length ? 4 : 1, shots.length ? hatchB : snapBtn, shots.length ? "below" : "above"); snapBtn.focus({ preventScroll: true }); }
      else if (e.key === "Enter" || e.key === "f" || e.key === "F") { e.preventDefault(); capture(R(app)); }
    });
    snapBtn.addEventListener("click", beginSelect);

    /* the note: "listening…", then the sentence streams in; typing first switches to text, like the app */
    function placeNote(s) {
      note.hidden = false;
      const c = R($(".pol", s.el)), W = desk.clientWidth, nw = note.offsetWidth;
      const x = Math.max(8, Math.min(W - nw - 8, c.x + c.w / 2 - nw / 2));
      Object.assign(note.style, { left: x + "px", top: c.y + c.h + 14 + "px" });
      note.style.setProperty("--ax", Math.max(16, Math.min(nw - 16, c.x + c.w / 2 - x)) + "px");
    }
    function startNote(s, edit = false) {
      if (!s.el.isConnected || state === "hatch" || state === "review") return;
      curNote = s; typing = edit; gen += 1; set("note");
      note.classList.remove("saved", "out"); note.classList.toggle("typing", edit);
      inp.value = edit ? s.text : ""; inp.placeholder = edit ? inp.dataset.typing : inp.dataset.listen;
      hint.textContent = L.hint;
      placeNote(s);
      clearTimeout(typeT);
      if (edit) { untip(); return inp.focus({ preventScroll: true }); }
      tip(3, note, "below");
      const text = s.line.said, g = gen;
      let i = 0;
      const step = () => {
        if (typing || g !== gen) return;
        inp.value = text.slice(0, ++i);
        typeT = setTimeout(i < text.length ? step : save, i < text.length ? (zh ? 95 : 36) : 1200);
      };
      typeT = setTimeout(step, reduce ? 250 : 950);
    }
    inp.dataset.listen = inp.placeholder;
    const takeOver = () => {
      if (typing || !curNote) return;
      typing = true; clearTimeout(typeT); inp.value = ""; inp.placeholder = inp.dataset.typing; note.classList.add("typing");
    };
    inp.addEventListener("pointerdown", takeOver);
    inp.addEventListener("keydown", (e) => {
      if (e.key === "Enter") { e.preventDefault(); return save(); }
      if (e.key === "Escape") { e.preventDefault(); e.stopPropagation(); return save(true); }
      if (e.altKey && e.shiftKey && e.code === "KeyA") return;
      if (!e.metaKey && !e.ctrlKey && (e.key.length === 1 || e.key === "Backspace" || e.key === "Process")) takeOver();
    });
    function hideNote(now) {
      const g = gen;
      if (now) { note.hidden = true; return; }
      setTimeout(() => { if (g !== gen || curNote) return; note.classList.add("out"); setTimeout(() => { if (g === gen && !curNote) note.hidden = true; }, 260); }, reduce ? 400 : 800);
    }
    function save(skip = false) {
      const s = curNote;
      if (!s) return;
      clearTimeout(typeT); curNote = null;
      if (typing) { const t = skip ? "" : inp.value.trim(); s.text = t; s.kind = t ? classify(t) : "note"; s.title = t || L.bare; }
      else if (skip) { s.text = ""; s.kind = "note"; s.title = L.bare; }
      else { s.text = s.line.said; s.kind = s.line.kind; s.title = s.line.title; inp.value = s.text; }
      s.el.classList.toggle("noted", !!s.text);
      $(".tip", s.el).textContent = s.text;
      $(".pol", s.el).setAttribute("aria-label", L.card(s.n, s.text));
      note.classList.add("saved"); note.classList.remove("typing"); hint.textContent = s.text ? L.saved : L.skipped;
      if (document.activeElement === inp) snapBtn.focus({ preventScroll: true });
      hideNote();
      set("idle");
      tip(4, hatchB, "below");
    }
    // a tap anywhere else on the desk saves what's typed, like clicking away from the bubble
    desk.addEventListener("pointerdown", (e) => { if (curNote && typing && !note.contains(e.target)) save(); }, true);

    /* 🐔 sort: the eggs wobble on the perch, the shots drop, the review page opens text-first and the frames stream in */
    hatchB.addEventListener("click", () => {
      if (!shots.length || state === "hatch" || state === "review") return;
      if (curNote) save();
      endSelect(); untip(); set("hatch");
      shots.forEach((s, i) => setTimeout(() => $(".pol", s.el).insertAdjacentHTML("beforeend", EGG(s.kind, "hatch-egg")), reduce ? 0 : i * 130));
      setTimeout(() => {
        shots.forEach((s, i) => setTimeout(() => { s.el.classList.add("fall"); s.onRope = false; tug(s.cx, -70, 90); wake(); }, reduce ? 0 : i * 80)); // the rope ripples as they go
        setTimeout(openReview, reduce ? 150 : 520);
      }, reduce ? 300 : 1500);
    });
    function openReview() {
      batch = shots; shots = []; batchSaid.clear(); cur = 0;
      hang.innerHTML = ""; desk.classList.remove("has-shots"); wake();
      set("review"); rv.hidden = false; fin.hidden = true; list.innerHTML = ""; list.scrollTop = 0;
      st.classList.remove("fin", "out");
      const m = batch.length, gap = reduce ? 0 : 230;
      let k = 0;
      const status = () => { stT.textContent = k >= m ? L.done : L.st(list.children.length, k, m); st.classList.toggle("fin", k >= m); };
      status();
      batch.forEach((s, i) => setTimeout(() => {
        if (state !== "review") return;
        const li = document.createElement("li");
        li.innerHTML = `${EGG(s.kind)}<span class="t"><span class="kk">${L.kinds[s.kind]}</span>${esc(s.title)}</span><span class="q">${s.text ? esc(L.q(s.text)) : L.noNote}</span><span class="th shim"></span>`;
        li.addEventListener("click", () => { cur = i; render(); });
        list.appendChild(li); s.li = li; render(); status();
      }, 200 + i * gap));
      batch.forEach((s, i) => setTimeout(() => {
        if (state !== "review" || !s.li) return;
        const th = $(".th", s.li), tw = th.clientWidth, tH = th.clientHeight, c = s.ph.cloneNode(true), sc = Math.max(tw / s.W, tH / s.H);
        c.style.transform = `translate(${((tw - s.W * sc) / 2).toFixed(1)}px, ${((tH - s.H * sc) / 2).toFixed(1)}px) scale(${sc.toFixed(4)})`;
        th.classList.remove("shim"); th.appendChild(c);
        k += 1; status();
        if (k === m) setTimeout(() => st.classList.add("out"), 1800);
      }, (reduce ? 0 : 900) + m * gap + i * (reduce ? 0 : 560)));
      setTimeout(() => { if (state !== "review") return; list.focus({ preventScroll: true }); tip(5, rvF, "above"); }, 300 + m * gap);
    }
    function render() {
      batch.forEach((b, i) => b.li && b.li.classList.toggle("cur", i === cur));
      const li = batch[cur] && batch[cur].li;
      if (!li) return;
      if (li.offsetTop < list.scrollTop) list.scrollTop = li.offsetTop;
      else if (li.offsetTop + li.offsetHeight > list.scrollTop + list.clientHeight) list.scrollTop = li.offsetTop + li.offsetHeight - list.clientHeight;
    }
    function act(k) {
      const s = batch[cur];
      if (!s || !s.li || !fin.hidden) return;
      if (k === "a" || k === "x") {
        s.li.classList.remove("keep", "drop"); s.li.classList.add(k === "a" ? "keep" : "drop"); s.res = k;
        const next = batch.findIndex((b, i) => i > cur && !b.res && b.li);
        if (next >= 0) cur = next;
        else { const any = batch.findIndex((b) => !b.res && b.li); if (any >= 0) cur = any; }
      } else if (k === "j") cur = Math.min(batch.filter((b) => b.li).length - 1, cur + 1);
      else if (k === "k") cur = Math.max(0, cur - 1);
      else if (k === "z") { s.li.classList.remove("keep", "drop"); s.res = null; }
      render();
      if (batch.every((b) => b.res)) {
        const kept = batch.filter((b) => b.res === "a").length;
        $("p", fin).textContent = L.end(kept, batch.length - kept);
        fin.hidden = false; untip();
        $(".again", fin).focus({ preventScroll: true });
      }
    }
    $$("button[data-k]", rvF).forEach((b) => b.addEventListener("click", () => act(b.dataset.k)));
    $(".again", fin).addEventListener("click", () => {
      rv.hidden = true; batch = []; set("idle");
      tip(1, snapBtn, "above"); snapBtn.focus({ preventScroll: true });
    });

    /* keys: ⌥⇧A snaps here while the desk is on screen; A/X/J/K/Z drive its review */
    let seen = false;
    if ("IntersectionObserver" in window) new IntersectionObserver((es) => es.forEach((e) => {
      seen = e.isIntersecting;
      if (seen && state === "idle" && !shots.length && !coachAt) tip(1, snapBtn, "above");
    }), { threshold: 0.4 }).observe(desk);
    const mine = () => seen || desk.contains(document.activeElement);
    const heroSnapKey = snapKey;
    snapKey = () => (seen ? (state === "review" ? null : beginSelect()) : heroSnapKey());
    deskOwns = () => state === "review" && mine();
    addEventListener("keydown", (e) => {
      if (e.key === "Escape" && state === "select") return endSelect();
      if (state !== "review" || !mine() || e.metaKey || e.ctrlKey || e.altKey || /input|textarea/i.test(e.target.tagName)) return;
      const k = e.key.toLowerCase();
      if (k.length !== 1 || !"axjkz".includes(k)) return;
      e.preventDefault(); act(k);
    });
    addEventListener("resize", () => { placeCoach(); if (curNote) placeNote(curNote); sizeRope(); });
  })();
  // @fonts:system-ui-end


  /* ---------- copy the install command (several lines paste as several commands) ---------- */
  $$(".cmd").forEach((box) => {
    const b = $(".copy", box), lines = $$(".cmd-t", box), label = b.textContent;
    b.addEventListener("click", async () => {
      try { await navigator.clipboard.writeText(lines.map((c) => c.textContent.trim()).join("\n")); }
      catch {
        const r = document.createRange(); r.selectNodeContents($(".cmd-lines", box));
        const s = getSelection(); s.removeAllRanges(); s.addRange(r);
        return; // selected instead: ⌘C still works
      }
      b.textContent = b.dataset.done; b.classList.add("ok");
      setTimeout(() => { b.textContent = label; b.classList.remove("ok"); }, 1600);
    });
  });

  /* ---------- which computer: ?os= (for testing and sharing) > the visitor's pick > a guess from the browser ---------- */
  // The guess only picks a default; the radio group next to it is the real control (and works without JS).
  const gets = $$(".get");
  if (gets.length) (() => {
    const NAME = { mac: "macOS", win: "Windows", linux: "Linux" };
    const norm = (v) => ({ mac: "mac", macos: "mac", osx: "mac", win: "win", windows: "win", linux: "linux", ios: "ios", ipados: "ios", android: "android", chromeos: "cros", cros: "cros" })[String(v || "").toLowerCase()] || "";
    function guess() {
      const ua = navigator.userAgent || "", hint = (navigator.userAgentData && navigator.userAgentData.platform) || "", plat = hint || navigator.platform || "";
      if (/android/i.test(plat) || /Android/.test(ua)) return "android";
      // iPadOS asks for desktop sites and says "Macintosh"; a real Mac has no touch points
      if (/^iOS$|iPhone|iPad|iPod/i.test(plat) || /iPhone|iPad|iPod/.test(ua) || (/Mac/i.test(plat + ua) && navigator.maxTouchPoints > 1)) return "ios";
      if (/^mac/i.test(plat) || /Macintosh|Mac OS X/.test(ua)) return "mac";
      if (/^win/i.test(plat) || /Windows/.test(ua)) return "win";
      if (/chrome ?os|CrOS/i.test(plat + " " + ua)) return "cros";
      if (/linux|bsd|x11/i.test(plat) || /Linux|X11|BSD/.test(ua)) return "linux"; // Ubuntu, Fedora, Arch… all say Linux
      return "";
    }
    const store = { get() { try { return norm(localStorage.getItem("blurt-os")); } catch { return ""; } }, set(v) { try { localStorage.setItem("blurt-os", v); } catch {} } };
    const real = (v) => (NAME[v] ? v : "");
    const fromLink = norm(new URLSearchParams(location.search).get("os"));
    const seen = fromLink || guess(), mine = real(store.get());
    const S = zh ? {
      found: (n) => `已识别：<b>${n}</b> · 不对就切换`, mine: (n) => `已选：<b>${n}</b>`, link: (n) => `按链接显示：<b>${n}</b>`,
      phone: "在手机上？口喷鸡装在电脑上用，选你电脑的系统", cros: "ChromeOS 暂不支持，选你要装的那台电脑", none: "没认出你的系统，选一个",
    } : {
      found: (n) => `Detected <b>${n}</b> · switch if that's wrong`, mine: (n) => `Your pick: <b>${n}</b>`, link: (n) => `Showing <b>${n}</b> (from the link)`,
      phone: "On a phone? blurt runs on your computer. Pick its system", cros: "ChromeOS isn't supported yet. Pick the computer you'll use", none: "Couldn't tell your system. Pick one",
    };
    const linked = real(fromLink);
    const os = linked || mine || real(seen) || (seen === "android" ? "win" : "mac");
    let said = linked ? S.link(NAME[os]) : seen === "ios" || seen === "android" ? S.phone : mine ? S.mine(NAME[os]) : real(seen) ? S.found(NAME[os]) : seen === "cros" ? S.cros : S.none;
    function show(v) {
      gets.forEach((g) => {
        g.dataset.os = v;
        const r = $(`input[value="${v}"]`, g); if (r) r.checked = true;
        $(".os-said", g).innerHTML = said;
      });
    }
    gets.forEach((g) => $$("input", g).forEach((r) => r.addEventListener("change", () => {
      if (!r.checked) return;
      store.set(r.value); said = S.mine(NAME[r.value]); show(r.value);
    })));
    show(os);
  })();

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
