/* blurt.work, round 7 (round 6's scroll machinery); round 9: Peep (peep.js) lives in the notch all the way
   down. This file tells it the active scene, step and notch mode every frame, and the beats (Blurt's bar stops, the
   52 items stream out).
   1. scenes: each [data-scene] is a tall section with a sticky stage. Scroll progress p (0–1 while pinned) picks the
      step (data-steps thresholds); steps are cumulative classes on1…onN, the CSS does the rest with transitions.
      --p, --d (distance from pinned, in viewports; + below, − above) and --de drive the parallax layers.
   2. the notch (#isl): fixed at the top centre; the active scene sets its mode and the live text under it. In the
      snap the words go into the note bubble beside the selection instead, as in the app.
   3. scrubbed values: the words as you talk, the speed clock and bars, the recording timer and transcript, the count.
   4. the film: loads on click, chapters seek. 5. copy the install command. 6. the GitHub star count in the nav.
   Without JS or under reduced motion nothing here runs: the HTML has every step on, so each scene rests on its end
   state and every caption is listed. */
(() => {
  const root = document.documentElement;
  const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const isl = document.getElementById("isl");
  const lt = isl && isl.querySelector(".lt");
  const tm = isl && isl.querySelector(".tm");
  const clamp = (x, a = 0, b = 1) => Math.min(b, Math.max(a, x));
  const span = (p, a, b) => clamp((p - a) / (b - a));
  const mmss = (s) => `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, "0")}`;
  const PP = window.Peep || { scene() {}, once() {}, count() {} };

  /* ---------------------------------------------------------------- 4. film, 5. copy (no motion needed) */
  const film = document.querySelector("[data-film]");
  if (film) {
    let v = null;
    const open = (at) => {
      if (!v) {
        v = document.createElement("video");
        v.src = film.dataset.src; v.controls = true; v.playsInline = true; v.preload = "auto";
        v.setAttribute("aria-label", film.querySelector("img").alt);
        film.appendChild(v); film.classList.add("playing");
      }
      const go = () => { if (at) v.currentTime = at; const pr = v.play(); if (pr) pr.catch(() => {}); };
      if (v.readyState >= 1) go(); else v.addEventListener("loadedmetadata", go, { once: true });
      v.focus();
    };
    film.querySelector("[data-play]").addEventListener("click", (e) => { e.preventDefault(); open(0); });
    document.querySelectorAll(".chap [data-at]").forEach((a) => a.addEventListener("click", (e) => {
      e.preventDefault(); open(parseFloat(a.dataset.at)); film.scrollIntoView({ block: "center", behavior: reduce ? "auto" : "smooth" });
    }));
  }
  document.querySelectorAll("[data-copy]").forEach((b) => {
    const text0 = b.textContent;
    b.addEventListener("click", async () => {
      const el = document.getElementById(b.dataset.copy);
      const text = el.textContent.replace(/^\$/, "").trim();
      try { await navigator.clipboard.writeText(text); }
      catch {
        const r = document.createRange(); r.selectNodeContents(el);
        const s = getSelection(); s.removeAllRanges(); s.addRange(r);
        try { document.execCommand("copy"); } catch {}
      }
      b.textContent = b.dataset.done; b.classList.add("done");
      setTimeout(() => { b.textContent = text0; b.classList.remove("done"); }, 1800);
    });
  });

  /* ---------------------------------------------------------------- 6. GitHub stars next to the nav link
     From the public API, kept in localStorage for an hour. Any failure (offline, rate limit, storage blocked) leaves
     the plain "GitHub" link: show nothing rather than a wrong number. */
  const stars = document.querySelectorAll(".gh .stars");
  if (stars.length) {
    const KEY = "blurt-stars", HOUR = 36e5;
    const fmt = (n) => (n >= 1000 ? (n / 1000).toFixed(1).replace(/\.0$/, "") + "k" : String(n));
    const show = (n) => stars.forEach((el) => {
      el.textContent = fmt(n); el.hidden = false;
      el.parentElement.setAttribute("aria-label", root.lang === "en" ? `GitHub, ${fmt(n)} stars` : `GitHub，${fmt(n)} 个星标`);
    });
    let cached = null;
    try {
      const c = JSON.parse(localStorage.getItem(KEY) || "null");
      if (c && Number.isFinite(c.n) && Date.now() - c.t < HOUR) cached = c.n;
    } catch {}
    if (cached !== null) show(cached);
    else {
      try {
        fetch("https://api.github.com/repos/AGIHunt/blurt").then((r) => (r.ok ? r.json() : null)).then((d) => {
          if (!d || !Number.isFinite(d.stargazers_count) || d.stargazers_count < 0) return;
          try { localStorage.setItem(KEY, JSON.stringify({ n: d.stargazers_count, t: Date.now() })); } catch {}
          show(d.stargazers_count);
        }).catch(() => {});
      } catch {}
    }
  }

  if (reduce || !isl) return;
  root.classList.add("motion");

  /* ---------------------------------------------------------------- 2. the notch and its live text */
  const spaced = root.lang === "en";
  let liveOwner = null, liveSpans = [];
  const setLive = (owner, words, f) => {
    if (!owner) { isl.classList.remove("live-on", "note"); return; }
    isl.classList.remove("note");
    if (liveOwner !== owner) {
      liveOwner = owner; lt.textContent = "";
      const sp = spaced && !owner.cjk;       // a Chinese take on the English page: no spaces between the words
      liveSpans = words.map((w, i) => {
        const s = document.createElement("span");
        s.className = "w h"; s.textContent = w + (sp && i < words.length - 1 ? " " : "");
        lt.appendChild(s); return s;
      });
    }
    const shown = Math.round(f * liveSpans.length);
    liveSpans.forEach((s, i) => {
      s.classList.toggle("h", i >= shown);
      s.classList.toggle("i", i < shown && i >= shown - 2 && f < 1);
    });
    isl.classList.add("live-on");
  };
  const mode = (m) => { if (isl.dataset.mode !== m) isl.dataset.mode = m; };
  // round 10: a whole text in the live panel at once (⌥T's translation), and the right ear's label
  const cp = isl.querySelector(".cp");
  const L10 = root.lang === "en" ? { copied: "Copied", translating: "Translating…" } : { copied: "已复制", translating: "正在翻译…" };
  const label = (x) => { if (cp && cp.textContent !== x) cp.textContent = x; };
  const note = (owner, text) => {
    if (liveOwner !== owner) { liveOwner = owner; lt.textContent = text; liveSpans = []; }
    isl.classList.add("live-on", "note");
  };

  // the words leave the live panel and land in the field (transform and opacity only)
  const fly = (to) => {
    if (!to || !isl.classList.contains("live-on")) return;
    const from = isl.querySelector(".live");
    const a = from.getBoundingClientRect(), b = to.getBoundingClientRect();
    const f = document.createElement("div");
    f.className = "flyer"; f.textContent = lt.textContent;
    Object.assign(f.style, { left: a.left + "px", top: a.top + "px", width: a.width + "px" });
    document.body.appendChild(f);
    const s = clamp(b.width / a.width, .4, 1.2);
    f.animate([{ transform: "none", opacity: 1 }, { transform: `translate(${b.left - a.left}px, ${b.top - a.top}px) scale(${s})`, opacity: .15 }],
      { duration: 620, easing: "cubic-bezier(.4,0,.2,1)" }).onfinish = () => f.remove();
  };

  // while the hero is on screen the notch takes one dictation by itself, then waits and starts again
  let heroT = 0, heroOn = false;
  const heroTake = (s) => {
    // below 1000 px the island and its live panel would cover the header's links: it waits for the scenes
    if (heroOn || innerWidth < 1000) { if (!heroOn) mode("idle"); return; }
    heroOn = true; mode("listen");
    const t0 = performance.now() + 1200, n = s.say.length, STEP = 330, HOLD = 2600;
    const tick = (now) => {
      if (!heroOn) return;
      if (now < t0) { mode("idle"); setLive(null); heroT = requestAnimationFrame(tick); return; }
      const t = (now - t0) % (n * STEP + HOLD);
      const f = Math.min(1, t / (n * STEP));
      setLive(s, s.say, f); tm.textContent = mmss(Math.min(t, n * STEP) / 1000);
      mode(f < 1 ? "listen" : "done");
      heroT = requestAnimationFrame(tick);
    };
    heroT = requestAnimationFrame(tick);
  };
  const heroStop = () => { if (heroOn) { heroOn = false; cancelAnimationFrame(heroT); } };

  // the words in the note bubble: what is heard so far, the last two words still provisional (lighter)
  const bubble = (s, f) => {
    if (!s.bub) return;
    const n = Math.round(f * s.say.length);
    if (n === s.bubN) return;
    s.bubN = n;
    const sep = spaced ? " " : "";
    const firm = s.say.slice(0, Math.max(0, n - 2)).join(sep), pend = s.say.slice(Math.max(0, n - 2), n).join(sep);
    s.bub.textContent = firm;
    if (pend) { const sp = document.createElement("span"); sp.className = "p"; sp.textContent = (firm && spaced ? " " : "") + pend; s.bub.appendChild(sp); }
  };

  /* ---------------------------------------------------------------- 1 + 3. scenes */
  const words = (el) => (el.dataset.say || "").split(" ").filter(Boolean);
  const hooks = {
    dict(s, p, k) {
      // step 3: the words leave Peep's beak and land at the cursor (peep.js)
      if (p < .08) { heroTake(s); return; }
      heroStop();
      if (k >= 1 && k < 3) {
        mode("listen");
        const f = span(p, s.th[1], s.th[2] - .03);
        setLive(s, s.say, f); tm.textContent = mmss(f * 3);
      } else { setLive(null); mode(k === 3 ? (PP.typing ? "type" : "done") : p < .08 ? "idle" : "hello"); }
    },
    speed(s, p) {
      const MAX = parseFloat(s.el.dataset.clock);
      const t = span(p, s.th[0], .62) * 3.1;
      s.clock.textContent = t.toFixed(2);
      s.el.style.setProperty("--tf", (t / MAX).toFixed(4));
      s.el.classList.toggle("done", t >= 3.05);
      s.lanes.forEach((ln) => {
        const at = parseFloat(ln.dataset.at);
        ln.style.setProperty("--f", (Math.min(t, at) / MAX).toFixed(4));
        // the moment Blurt's bar stops, Peep hops
        if (ln.classList.contains("us") && t >= at && !ln.classList.contains("got") && s.k > 0 && t < at + .4) PP.once("done");
        ln.classList.toggle("got", t >= at);
      });
    },
    struct(s, p, k, prev) {
      if (prev === 1 && k === 2) fly(s.el.querySelector(".ch-me"));
      if (k === 1) {
        mode("listen");
        const f = span(p, s.th[0] + .02, s.th[1] - .04);
        setLive(s, s.say, f); tm.textContent = mmss(f * 9);
      } else if (k >= 4) {
        mode("list"); setLive(null); tm.textContent = "0:04";
      } else { setLive(null); mode(k >= 2 ? "done" : "hello"); }
    },
    snap(s, p, k) {
      // the note bubble listens from the moment it opens (k 3) until the pause saves it (k 9); the words are its own
      setLive(null);
      mode(k >= 10 ? "hello" : "idle");
      // ⌥A: the crosshair drags the selection out with the scroll, from the screen going dim (k 1) to the bubble (k 3)
      s.el.style.setProperty("--sel", span(p, s.th[0] + .006, s.th[2] - .012).toFixed(3));
      const f = k >= 9 ? 1 : k < 3 ? 0 : span(p, s.th[2] + .01, s.th[7] + .03);
      bubble(s, f);
      let cur = null;
      s.draw.forEach((li) => { if (k <= 8 && +li.dataset.k <= k) cur = li; });
      s.draw.forEach((li) => li.classList.toggle("now", li === cur));
    },
    rec(s, p, k) {
      setLive(null);
      const sec = span(p, s.th[0], s.th[3]) * 300;
      if (k >= 1 && k < 4) { mode("rec"); tm.textContent = mmss(sec); }
      else mode(k === 4 ? "done" : k >= 5 ? "hello" : "idle");
      if (s.tick) s.tick.style.setProperty("--n", [6, 72, 160, 276].filter((x) => sec >= x).length);
      if (s.count) { const n = Math.round(span(p, s.th[4] + .01, s.th[4] + .1) * 52); s.count.textContent = n; PP.count(k === 5 ? n : 0); }
    },
    text(s, p, k) {
      // the drag grows with the scroll (k 1–2), again for ⌥T (k 6); let go: Copied; ⌥T: Translating…, then the text
      const th = s.th;
      const sel = k >= 6 ? span(p, th[5], th[5] + .05) : span(p, th[1], th[2] - .03);
      s.el.style.setProperty("--sel", sel.toFixed(3));
      s.el.classList.toggle("drag", k >= 6 ? sel < 1 : k >= 1 && k < 3);
      if (k === 3) { setLive(null); label(L10.copied); mode("copied"); }
      else if (k >= 6 && sel >= 1) {
        if (p < th[5] + .1) { setLive(null); label(L10.translating); mode("think"); }
        else { note(s, s.trans); mode("done"); }
      } else { setLive(null); mode(k >= 4 && k < 6 ? "hello" : "idle"); }
    },
    tr(s, p, k, prev) {
      // Chinese under the notch while you talk; ⌘ adds the translate mark; after you stop, about a second, then English
      const th = s.th;
      if (k >= 1 && k < 3) {
        mode(k >= 2 ? "trl" : "listen");
        const f = span(p, th[0] + .02, th[2] - .04);
        setLive(s, s.say, f); tm.textContent = mmss(f * 7);
      } else if (k === 3) {
        setLive(s, s.say, 1); label((span(p, th[2] + .01, th[3] - .01) * 1.0).toFixed(1) + " s"); mode("think");
      } else {
        if (k === 4 && prev === 3) fly(s.el.querySelector("[data-target]"));
        setLive(null); mode(k === 4 ? "done" : k >= 5 ? "hello" : "idle");
      }
    },
    first(s, p, k, prev) {
      const th = s.th;
      if (k === 3) {
        mode("listen");
        const f = span(p, th[2] + .01, th[3] - .03);
        setLive(s, s.say, f); tm.textContent = mmss(f * 3);
      } else {
        if (k === 4 && prev === 3) fly(s.el.querySelector("[data-target]"));
        setLive(null); mode(k === 4 ? "done" : k >= 1 ? "hello" : "idle");
      }
    },
    hand(s, p, k) {
      setLive(null);
      mode(k === 4 || k === 5 ? "verify" : "hello");
    },
  };
  const scenes = [...document.querySelectorAll("[data-scene]")].map((el) => {
    const th = el.dataset.steps.trim().split(/\s+/).map(Number);
    for (let i = 1; i <= th.length; i++) el.classList.remove(`on${i}`);
    return {
      el, th, k: -1, name: el.dataset.scene, say: words(el),
      caps: [...el.querySelectorAll(".steps li")],
      clock: el.querySelector("[data-clock-out]"), lanes: [...el.querySelectorAll(".ln")],
      tick: el.querySelector(".tick"), count: el.querySelector("[data-count-out]"),
      bub: el.querySelector("[data-bub]"), bubN: -1, draw: [...el.querySelectorAll(".draw li")],
      cjk: el.hasAttribute("data-cjk"), trans: el.dataset.trans || "",
    };
  });
  const depthEls = [...document.querySelectorAll("[data-depth]")];

  // the first scene's window starts below the hero's last line, however short the screen (it rises as the hero goes)
  const hero = document.querySelector(".hero"), dictEl = document.querySelector(".sc-dict");
  const fit = () => {
    if (!hero || !dictEl) return;
    const hb = hero.offsetTop + hero.offsetHeight;
    const phone = innerWidth <= 720;
    // where the window rests (its top in px): 9.5 desk ems on a desktop, 7.6 camera ems (3% of the width) on a phone
    const top = phone ? 7.6 * innerWidth * .03 : 9.5 * Math.min(innerWidth, innerHeight * 1.6) / 100;
    const want = Math.max(phone ? 0 : innerHeight * .54, hb + (phone ? 72 : 32) - top);   // phones: room for perched Peep over the window
    dictEl.style.setProperty("--rise0", Math.round(want) + "px");
  };
  fit();
  if (document.fonts) document.fonts.ready.then(() => { fit(); queue(); });   // the serif can arrive after this runs

  let queued = false;
  const frame = () => {
    queued = false;
    const vh = innerHeight;
    let active = null, onStage = scrollY < 40;
    root.style.setProperty("--sy0", Math.min(scrollY, 1200).toFixed(0));
    for (const s of scenes) {
      const r = s.el.getBoundingClientRect();
      const len = Math.max(1, r.height - vh);
      const p = clamp(-r.top / len);
      const d = r.top > 0 ? Math.min(r.top / vh, 1.2) : r.bottom < vh ? Math.max((r.bottom - vh) / vh, -1.2) : 0;
      if (r.bottom > -vh && r.top < vh * 2) {
        s.el.style.setProperty("--p", p.toFixed(4));
        s.el.style.setProperty("--d", d.toFixed(4));
        s.el.style.setProperty("--de", Math.max(0, d).toFixed(4));
      }
      const k = r.top >= vh * .35 ? 0 : s.th.filter((x) => p >= x).length;
      if (k !== s.k) {
        for (let i = 1; i <= s.th.length; i++) s.el.classList.toggle(`on${i}`, i <= k);
        let cur = s.caps[0];
        s.caps.forEach((li) => { if (+li.dataset.k <= k) cur = li; });
        s.caps.forEach((li) => li.classList.toggle("now", li === cur));
      }
      if (r.top <= vh * .5 && r.bottom >= vh * .5) active = { s, p, k, prev: s.k };
      if (r.top <= 1 && r.bottom >= 48) onStage = true;
      s.k = k;
      s.p = p;
    }
    for (const s of scenes) if (s.name === "speed") hooks.speed(s, s.p, s.k);
    if (!active || active.s.name !== "dict") heroStop();
    if (active && active.s.name !== "speed") hooks[active.s.name](active.s, active.p, active.k, active.prev);
    else { setLive(null); mode(onStage ? "idle" : "off"); }
    // between the scenes (the table, privacy, the film, install) the notch stays, small, with Peep in it; it goes up
    // out of the way when Peep peeks up at the bottom of the page
    if (!onStage) { setLive(null); mode("idle"); }
    if (PP.footer) mode("off");
    PP.scene(active && onStage ? active.s.name : "", active && onStage ? active.k : 0, 0, isl.dataset.mode);
    depthEls.forEach((el) => {
      const r = el.getBoundingClientRect();
      if (r.bottom < -200 || r.top > vh + 200) return;
      el.style.setProperty("--py", (((r.top + r.height / 2) - vh / 2) * parseFloat(el.dataset.depth)).toFixed(1));
    });
  };
  const queue = () => { if (!queued) { queued = true; requestAnimationFrame(frame); } };
  addEventListener("scroll", queue, { passive: true });
  addEventListener("resize", () => { fit(); queue(); });
  frame();
})();
