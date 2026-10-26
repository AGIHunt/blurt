/* blurt.agihunt.info
   1. the hero: one dictation at measured timings, in tap mode: tap, talk a 3 s sentence, then a double tap in place of
      the second tap: the text is at the cursor 0.29 s later, Return goes, Claude Code starts reading
   2. the dictation line: words arrive grey and settle to ink, like the live text under the notch
   3. the loops: play while on screen; Snap's steps and the hand-off's caption line follow the time
   4. the film: loads on click, chapters seek
   5. copy the install command; the line chick's sound arcs while it is on screen
   Every part leaves the page complete without JS: the hero rests on the sent state, the line is all ink,
   the loops have native controls, every caption is listed. */
(() => {
  const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const phone = matchMedia("(max-width: 720px)");
  const seen = (el, fn, threshold = 0.5) => new IntersectionObserver((es) => fn(es[0].isIntersecting), { threshold }).observe(el);

  /* ---------------------------------------------------------------- 1. hero */
  const stage = document.querySelector("[data-hero]");
  if (stage) {
    const lt = stage.querySelector(".lt");
    const finalText = lt.textContent;
    const tokens = (stage.dataset.heard || "").split(" ").filter(Boolean);
    const spaced = document.documentElement.lang === "en";
    const head = stage.parentElement.querySelector(".track .head");
    const track = stage.parentElement.querySelector(".track");
    const timer = stage.querySelector(".timer");
    const replay = stage.parentElement.querySelector("[data-replay]");
    // ms on the axis: talk 3 s, double-tap at 3 s, text at 3.29 s, Return as soon as the text is in; the axis spans 4.4 s.
    // style.css places the marks at TALK / TOTAL (68.2 %) and the lag bar over PASTE - TALK (6.6 %): keep them in step.
    const TOTAL = 4400, TALK = 3000, PASTE = 3290, SEND = 3450, LAG = 650, FIRM = 1500;
    const STATES = ["s-idle", "s-listen", "s-stop", "s-pasted", "s-sent"];
    let raf = 0, t0 = 0, spans = [], playing = false, loops = 0, visible = false;

    const setState = (s) => { stage.classList.remove(...STATES); if (s) stage.classList.add(s); };
    const build = () => {
      lt.textContent = "";
      spans = tokens.map((w, i) => {
        const s = document.createElement("span");
        s.className = "w h";
        s.textContent = w + (spaced && i < tokens.length - 1 ? " " : "");
        lt.appendChild(s);
        return s;
      });
    };
    const frame = (now) => {
      const t = now - t0;
      head.style.transform = `translateX(${(Math.min(t, TOTAL) / TOTAL) * track.clientWidth}px)`;
      if (t < PASTE) {
        const step = TALK / tokens.length;
        spans.forEach((s, i) => {
          const said = i * step;
          const shown = t >= said + LAG || (t >= TALK && t >= TALK + (i - tokens.length) * 20 + 160);
          const firm = t >= said + FIRM || t >= TALK + 200;
          s.classList.toggle("h", !shown);
          s.classList.toggle("i", shown && !firm);
        });
        timer.textContent = `0:0${Math.floor(Math.min(t, TALK) / 1000)}`;
      }
      if (t >= TALK && stage.classList.contains("s-listen")) setState("s-stop");
      if (t >= PASTE && stage.classList.contains("s-stop")) { lt.textContent = finalText; setState("s-pasted"); }
      if (t >= SEND && stage.classList.contains("s-pasted")) setState("s-sent");
      if (t < TOTAL + 3200) { raf = requestAnimationFrame(frame); return; }
      playing = false; loops += 1;
      if (loops < 3 && visible) start(); else { setState("s-sent"); replay.hidden = false; }
    };
    const start = () => {
      cancelAnimationFrame(raf);
      playing = true; replay.hidden = true;
      build(); setState("s-idle");
      head.style.transform = "translateX(0)";
      setTimeout(() => { setState("s-listen"); t0 = performance.now(); raf = requestAnimationFrame(frame); }, 900);
    };
    if (!reduce) {
      seen(stage, (v) => { visible = v; if (v && !playing && loops === 0) start(); }, 0.4);
      replay.addEventListener("click", () => { loops = 0; start(); });
    } else {
      head.style.transform = `translateX(${track.clientWidth * (SEND / TOTAL)}px)`;
    }
  }

  /* ---------------------------------------------------------------- 2. the dictation line */
  const say = document.querySelector("[data-say]");
  if (say && !reduce) {
    const ws = [...say.querySelectorAll(".w")];
    let done = false;
    const run = () => {
      done = true;
      const STEP = 420, LAG = 600, FIRM = 1300;
      const t0 = performance.now();
      const tick = (now) => {
        const t = now - t0;
        const end = (ws.length - 1) * STEP + FIRM;
        ws.forEach((w, i) => {
          const at = i * STEP;
          w.classList.toggle("h", t < at + LAG);
          w.classList.toggle("i", t >= at + LAG && t < at + FIRM);
        });
        if (t < end + 50) requestAnimationFrame(tick);
      };
      requestAnimationFrame(tick);
    };
    seen(say, (v) => { if (v && !done) run(); }, 0.9);
  }

  /* ---------------------------------------------------------------- 3. loops */
  document.querySelectorAll("[data-clip]").forEach((fig) => {
    const v = fig.querySelector("video");
    const bar = fig.querySelector(".loop-bar i");
    const toggle = fig.querySelector("[data-toggle]");
    const items = [...fig.querySelectorAll(".steps li, .caps li")];
    const marks = items.map((li) => parseFloat(li.dataset.t));
    let userPaused = false, raf = 0;

    v.removeAttribute("controls");
    toggle.hidden = false;
    items.forEach((li) => { const b = li.querySelector("button"); if (b) b.removeAttribute("tabindex"); });
    if (phone.matches && v.dataset.posterM) v.poster = v.dataset.posterM;

    const paint = () => {
      const d = v.duration || 1, t = v.currentTime;
      bar.style.width = `${(t / d) * 100}%`;
      let k = 0;
      marks.forEach((m, i) => { if (t + 0.05 >= m) k = i; });
      items.forEach((li, i) => li.classList.toggle("on", i === k));
      if (!v.paused) raf = requestAnimationFrame(paint);
    };
    const play = () => { const p = v.play(); if (p) p.catch(() => {}); };
    const label = (k) => { toggle.querySelector(".sr").textContent = toggle.dataset[k]; };
    v.addEventListener("play", () => { toggle.classList.add("is-playing"); label("pause"); cancelAnimationFrame(raf); raf = requestAnimationFrame(paint); });
    v.addEventListener("pause", () => { toggle.classList.remove("is-playing"); label("play"); paint(); });
    v.addEventListener("seeked", paint);
    toggle.addEventListener("click", () => {
      if (v.paused) { userPaused = false; play(); } else { userPaused = true; v.pause(); }
    });
    items.forEach((li, i) => {
      const b = li.querySelector("button");
      if (b) b.addEventListener("click", () => { v.currentTime = marks[i]; userPaused = false; play(); paint(); });
    });
    if (!reduce) seen(v, (on) => { if (on && !userPaused) play(); else if (!on) v.pause(); }, 0.45);
    if (items[0]) items[0].classList.add("on");
  });

  /* ---------------------------------------------------------------- 4. the film */
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
      const go = () => { if (at) v.currentTime = at; const p = v.play(); if (p) p.catch(() => {}); };
      if (v.readyState >= 1) go(); else v.addEventListener("loadedmetadata", go, { once: true });
      v.focus();
    };
    film.querySelector("[data-play]").addEventListener("click", (e) => { e.preventDefault(); open(0); });
    document.querySelectorAll(".chap [data-at]").forEach((a) => a.addEventListener("click", (e) => {
      e.preventDefault(); open(parseFloat(a.dataset.at)); film.scrollIntoView({ block: "center", behavior: reduce ? "auto" : "smooth" });
    }));
  }

  /* ---------------------------------------------------------------- 5. copy, the chick */
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
  const lc = document.querySelector(".lchick");
  if (lc && !reduce) seen(lc, (v) => lc.classList.toggle("on", v), 0.6);
})();
