// blurt.agihunt.info — copy the install command, GitHub stars, the film, and the pen loops. No dependencies.
(() => {
  const root = document.documentElement;
  root.classList.remove("no-js");
  const t = (el, key) => el.dataset[key] || "";

  // install command: click anywhere on the block to copy
  document.querySelectorAll(".cmd").forEach((box) => {
    const btn = box.querySelector("button");
    const text = box.querySelector("code").textContent.trim();
    box.addEventListener("click", async () => {
      try {
        await navigator.clipboard.writeText(text);
      } catch {
        const r = document.createRange();
        r.selectNodeContents(box.querySelector("code"));
        const s = getSelection();
        s.removeAllRanges();
        s.addRange(r);
        return; // selected instead: ⌘C still works
      }
      const label = btn.textContent;
      btn.textContent = t(btn, "done");
      btn.classList.add("ok");
      setTimeout(() => { btn.textContent = label; btn.classList.remove("ok"); }, 1500);
    });
  });

  // download button: only Macs get the zip
  if (!/Mac/i.test(navigator.platform || navigator.userAgent) || /iPhone|iPad/i.test(navigator.userAgent)) {
    document.querySelectorAll(".btn[data-other]").forEach((a) => {
      a.href = "https://github.com/AGIHunt/blurt/releases/latest";
      a.querySelector("span").textContent = t(a, "other");
      a.removeAttribute("download");
    });
  }

  // GitHub stars: show nothing rather than a wrong number
  const stars = document.querySelectorAll(".stars");
  const show = (n) => stars.forEach((el) => { el.textContent = n >= 1000 ? (n / 1000).toFixed(1).replace(/\.0$/, "") + "k" : String(n); });
  try {
    const cached = sessionStorage.getItem("blurt-stars");
    if (cached) show(+cached);
    else {
      fetch("https://api.github.com/repos/AGIHunt/blurt")
        .then((r) => (r.ok ? r.json() : null))
        .then((d) => {
          if (d && Number.isFinite(d.stargazers_count)) {
            sessionStorage.setItem("blurt-stars", d.stargazers_count);
            show(d.stargazers_count);
          }
        })
        .catch(() => {});
    }
  } catch {}

  // film: muted autoplay when visible (browsers allow nothing else); one click for sound from the start
  const video = document.querySelector(".film video");
  const sound = document.querySelector(".sound");
  if (video) {
    const still = matchMedia("(prefers-reduced-motion: reduce)").matches;
    let inView = false;
    const sync = () => {
      if (inView && !document.hidden) video.play().catch(() => {});   // refused (hidden tab, data saver): the poster stays
      else video.pause();
    };
    if (still) video.controls = true;
    else {
      new IntersectionObserver((entries) => { inView = entries[0].isIntersecting; sync(); }, { threshold: 0.35 }).observe(video);
      document.addEventListener("visibilitychange", sync);
    }
    if (sound) {
      sound.hidden = false;
      sound.addEventListener("click", () => {
        video.muted = false;
        video.loop = false;
        video.controls = true;
        video.currentTime = 0;
        video.play().catch(() => {});
        sound.hidden = true;
      });
    }
  }

  // pen loops draw themselves when they scroll into view
  const loops = document.querySelectorAll(".circled");
  if ("IntersectionObserver" in window) {
    const io = new IntersectionObserver((entries) => {
      entries.forEach((e) => { if (e.isIntersecting) { e.target.classList.add("drawn"); io.unobserve(e.target); } });
    }, { threshold: 0.6 });
    loops.forEach((el) => io.observe(el));
  } else loops.forEach((el) => el.classList.add("drawn"));
})();
