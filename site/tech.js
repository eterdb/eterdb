/* eterDB, /tech animated illustrations.
   Dependency-free, hand-built canvas figures in the spirit of an explorable
   explanation. Every figure is SELF-DRIVING (issue #162): a timed loop tells
   the story on its own, with no buttons, toggles, steppers or sliders. Hover
   remains as an optional detail layer on a couple of figures.

   Each figure mounts into <figure class="fig" data-fig="NAME"> containing a
   <canvas class="fig-canvas">. Figures render as a pure function of loop time,
   animate only while on screen, and respect prefers-reduced-motion: a static,
   fully-informative end-state is rendered and auto-play loops are skipped. */

(() => {
  "use strict";

  const reduce = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  /* ── Palette (mirrors the CSS tokens; canvas can't read CSS vars cheaply) ── */
  const P = {
    ink: "#0a0a0a", ink2: "#2a2a28", mut: "#5d5d58", faint: "#94948e",
    line: "#e7e7e3", line2: "#d8d8d2", soft: "#f4f4f1", softer: "#fafaf8", card: "#ffffff",
    ok: "#2f9e5e", okBg: "#eef7f0", okLn: "#cfe9d8",
    bad: "#d64545", badBg: "#fdecec", badLn: "#f0c4c4",
    warn: "#b07d18", warnBg: "#fff6e6", warnLn: "#f0dcae",
    past: "#4663c9", pastBg: "#eef2ff", pastLn: "#d6def8",
    mono: '"JetBrains Mono", ui-monospace, SFMono-Regular, Menlo, monospace',
    sans: '"Inter", -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif',
  };

  /* ── Math + drawing helpers ── */
  const clamp = (v, a, b) => (v < a ? a : v > b ? b : v);
  const lerp = (a, b, t) => a + (b - a) * t;
  const easeOut = (t) => 1 - Math.pow(1 - t, 3);
  // Seconds since the figure first scrolled into view (t0 is stamped by
  // loopWhenVisible), so every self-driving story starts at its first scene.
  const now = (S) => Math.max(0, S.t - (S.t0 || 0)) / 1000;

  function rr(ctx, x, y, w, h, r) {
    if (w <= 0 || h <= 0) { ctx.beginPath(); return; }
    r = 0; /* square corners everywhere, the site has no rounded corners */
    ctx.beginPath();
    if (ctx.roundRect) { ctx.roundRect(x, y, w, h, r); return; }
    ctx.moveTo(x + r, y);
    ctx.arcTo(x + w, y, x + w, y + h, r);
    ctx.arcTo(x + w, y + h, x, y + h, r);
    ctx.arcTo(x, y + h, x, y, r);
    ctx.arcTo(x, y, x + w, y, r);
    ctx.closePath();
  }
  function box(ctx, x, y, w, h, r, fill, stroke, lw) {
    rr(ctx, x, y, w, h, r);
    if (fill) { ctx.fillStyle = fill; ctx.fill(); }
    if (stroke) { ctx.strokeStyle = stroke; ctx.lineWidth = lw || 1; ctx.stroke(); }
  }
  function txt(ctx, s, x, y, o) {
    o = o || {};
    const size = o.size || 12;
    ctx.font = (o.weight ? o.weight + " " : "") + size + "px " + (o.mono ? P.mono : P.sans);
    ctx.fillStyle = o.color || P.ink;
    ctx.textAlign = o.align || "left";
    ctx.textBaseline = o.baseline || "alphabetic";
    ctx.fillText(s, x, y);
  }
  function pill(ctx, s, x, y, fg, bg, ln) {
    ctx.font = "600 10px " + P.mono;
    const w = ctx.measureText(s).width + 16;
    box(ctx, x, y, w, 18, 9, bg, ln, 1);
    txt(ctx, s, x + w / 2, y + 9, { size: 10, weight: "600", mono: true, color: fg, align: "center", baseline: "middle" });
    return w;
  }
  function arrow(ctx, x1, y1, x2, y2, color, lw, dash) {
    ctx.save();
    ctx.strokeStyle = color; ctx.lineWidth = lw || 1.5; ctx.lineCap = "round";
    ctx.setLineDash(dash || []);
    ctx.beginPath(); ctx.moveTo(x1, y1); ctx.lineTo(x2, y2); ctx.stroke();
    ctx.setLineDash([]);
    const a = Math.atan2(y2 - y1, x2 - x1), s = 6;
    ctx.beginPath();
    ctx.moveTo(x2, y2);
    ctx.lineTo(x2 - s * Math.cos(a - 0.5), y2 - s * Math.sin(a - 0.5));
    ctx.lineTo(x2 - s * Math.cos(a + 0.5), y2 - s * Math.sin(a + 0.5));
    ctx.closePath(); ctx.fillStyle = color; ctx.fill();
    ctx.restore();
  }

  /* ── Tiny spring/tween bag: smooth current→target motion per figure ── */
  function springs() {
    const m = new Map();
    return {
      to(k, v) { if (!m.has(k)) m.set(k, { c: v, t: v }); else m.get(k).t = v; },
      set(k, v) { m.set(k, { c: v, t: v }); },
      v(k) { return m.has(k) ? m.get(k).c : 0; },
      step(speed) {
        speed = speed || 0.2; let moving = false;
        for (const o of m.values()) {
          const d = o.t - o.c;
          if (Math.abs(d) > 0.0008) { o.c += d * speed; moving = true; } else o.c = o.t;
        }
        return moving;
      },
    };
  }

  /* ── Canvas stage: hi-dpi, responsive width, fixed logical height ── */
  function stage(root, height, render) {
    const canvas = root.querySelector(".fig-canvas");
    const ctx = canvas.getContext("2d");
    const S = { w: 0, h: height, t: 0, mx: -1, my: -1, down: false, hot: null };
    function resize() {
      const minw = S.minW || 640;
      const frame = canvas.parentElement;
      const avail = (frame ? frame.clientWidth : 0) || root.clientWidth;
      // Below the design width (phones) we don't force a horizontal scroll; we keep
      // drawing at the design width and shrink the whole figure to fit the frame, so
      // both panes stay visible. The logical coordinate space is unchanged, so every
      // figure's render math keeps working; only the on-screen size scales.
      const logicalW = Math.max(avail, minw);
      const scale = avail < minw ? avail / minw : 1;
      const dpr = Math.min(window.devicePixelRatio || 1, 2);
      S.w = logicalW;
      S.scale = scale;
      canvas.style.width = (logicalW * scale) + "px";
      canvas.style.height = (height * scale) + "px";
      canvas.width = Math.round(logicalW * dpr);
      canvas.height = Math.round(height * dpr);
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      draw();
    }
    let raf = 0, running = false;
    function loop(ts) {
      S.t = ts || 0;
      if (S.w <= 0) { running = false; return; } // not sized yet, wait for resize()
      const moving = S.sp ? S.sp.step(S.speed || 0.2) : false;
      render(ctx, S);
      if (moving || (S.always && S.vis !== false)) raf = requestAnimationFrame(loop);
      else running = false;
    }
    function draw() {
      if (S.w <= 0) return; // controls can sync before the first resize; skip until sized
      ctx.clearRect(0, 0, S.w, S.h);
      render(ctx, S);
    }
    function kick() { if (!running) { running = true; raf = requestAnimationFrame(loop); } }
    function pos(e) {
      const r = canvas.getBoundingClientRect();
      const p = e.touches ? e.touches[0] : e;
      // Map CSS px back into the (possibly scaled-down) logical coordinate space.
      const sc = S.scale || 1;
      S.mx = (p.clientX - r.left) / sc; S.my = (p.clientY - r.top) / sc;
    }
    canvas.addEventListener("pointermove", (e) => { pos(e); if (S.onmove) S.onmove(S); if (!running) draw(); });
    canvas.addEventListener("pointerdown", (e) => { pos(e); S.down = true; canvas.setPointerCapture && canvas.setPointerCapture(e.pointerId); if (S.ondown) S.ondown(S); kick(); });
    window.addEventListener("pointerup", () => { S.down = false; if (S.onup) S.onup(S); });
    canvas.addEventListener("pointerleave", () => { S.mx = -1; S.my = -1; if (S.onleave) S.onleave(S); if (!running) draw(); });
    window.addEventListener("resize", resize);
    S.draw = draw; S.kick = kick; S.canvas = canvas; S.resize = resize;
    return S;
  }

  /* ── Readout + display-only chip row (replaces the old control widgets) ── */
  // A row of small labelled chips with one highlighted: shows WHERE the
  // self-driving loop currently is (which mode, which view) without being a
  // control. Returns the row's total width.
  function chips(ctx, x, y, items, activeIdx) {
    let cx = x;
    items.forEach((s, i) => {
      const on = i === activeIdx;
      ctx.font = "600 10px " + P.mono;
      const w = ctx.measureText(s).width + 16;
      box(ctx, cx, y, w, 18, 9, on ? P.warnBg : P.softer, on ? P.warnLn : P.line, 1);
      txt(ctx, s, cx + w / 2, y + 9, { size: 10, weight: "600", mono: true, color: on ? P.warn : P.faint, align: "center", baseline: "middle" });
      cx += w + 6;
    });
    return cx - x - 6;
  }
  function note(root, html) {
    let n = root.querySelector(".fig-readout");
    if (!n) { n = document.createElement("p"); n.className = "fig-readout"; root.appendChild(n); }
    if (n._h !== html) { n.innerHTML = html; n._h = html; } // skip identical repaints
  }

  /* Start a figure's auto behaviour only when scrolled into view. */
  function onView(el, cb) {
    if (reduce || !("IntersectionObserver" in window)) { cb(); return; }
    let done = false;
    const io = new IntersectionObserver((es) => {
      es.forEach((e) => { if (e.isIntersecting && !done) { done = true; cb(); io.disconnect(); } });
    }, { threshold: 0.2 });
    io.observe(el);
  }

  /* Drive a continuously-looping figure ONLY while it's on screen, entering
     resumes the rAF loop, leaving lets it settle (no seven idle loops on a long
     scroll). Reduced-motion renders a single informative static frame. */
  function loopWhenVisible(el, S) {
    if (reduce) { S.always = false; S.vis = false; S.draw(); return; }
    if (!("IntersectionObserver" in window)) { S.always = true; S.vis = true; S.kick(); return; }
    const io = new IntersectionObserver((es) => {
      es.forEach((e) => {
        S.vis = e.isIntersecting;
        if (e.isIntersecting) {
          if (S.t0 === undefined) S.t0 = performance.now(); // the story starts now
          else if (S.tLeft !== undefined) { S.t0 += performance.now() - S.tLeft; S.tLeft = undefined; } // …and pauses while off-screen
          S.always = true; S.kick();
        } else if (S.t0 !== undefined) {
          S.tLeft = performance.now();
        }
      });
    }, { threshold: 0.12 });
    io.observe(el);
  }

  /* ════════════════════════════════════════════════════════════════════
     FIGURE 0, First principles, two-pane + auto-loop. LEFT: a transaction
     (a money transfer) is staged statement by statement, then COMMITs or,
     on alternating loops, ROLLBACKs. RIGHT: the two tables it touches, one
     row each, flipping to the new value together on commit or not at all
     on rollback. The point, and the only point: a transaction is the
     all-or-nothing unit, which is why it is the thing eterDB reverses.
     Deliberately says nothing about heap pages or row versions. Those are
     introduced where they are needed, in §3 and §4 of tech.html; teaching
     them here would front-load storage internals the section never uses.
     ════════════════════════════════════════════════════════════════════ */
  function figBasics(root) {
    const S = stage(root, 272, render);
    S.sp = springs(); S.minW = 620;

    const A0 = "$500", A1 = "$450", L0 = "$200", L1 = "$250";

    function render(ctx, S) {
      ctx.clearRect(0, 0, S.w, S.h);
      const LOOP = 9.0;
      let e, loopN;
      if (reduce) { e = LOOP; loopN = 0; }
      else { const tg = now(S); loopN = Math.floor(tg / LOOP); e = tg % LOOP; }
      const commitScene = (loopN % 2 === 0);

      const lines = e < 1.0 ? 1 : e < 2.2 ? 2 : e < 3.4 ? 3 : 4; // statements revealed
      const resolving = e >= 3.4;   // COMMIT / ROLLBACK keyword shown
      const resolved = e >= 4.4;    // committed / discarded
      const flash = (e >= 4.4 && e < 4.95) ? 1 - (e - 4.4) / 0.55 : 0;
      const applied = resolved && commitScene;

      const pad = 18, splitX = Math.round(S.w * 0.44), gap = 18;

      /* ── LEFT pane: the transaction ── */
      txt(ctx, "one transaction", pad, 24, { size: 12.5, weight: "700", color: P.ink });
      txt(ctx, "all of it, or none of it", pad, 40, { size: 10.5, color: P.mut });

      const tcX = pad, tcY = 56, tcW = splitX - pad - gap / 2, tcH = 200;
      box(ctx, tcX, tcY, tcW, tcH, 10, P.softer, P.line2, 1);
      const stmts = [
        { kw: "BEGIN;", c: P.mut },
        { kw: "UPDATE accounts SET bal = " + A1, c: P.ink2, sub: "-- debit  (" + A0 + " → " + A1 + ")" },
        { kw: "UPDATE ledger   SET bal = " + L1, c: P.ink2, sub: "-- credit (" + L0 + " → " + L1 + ")" },
        { kw: commitScene ? "COMMIT;" : "ROLLBACK;", c: commitScene ? P.ok : P.bad },
      ];
      let ly = tcY + 26;
      for (let i = 0; i < stmts.length; i++) {
        ctx.globalAlpha = i < lines ? 1 : 0.13;
        const s = stmts[i];
        txt(ctx, s.kw, tcX + 14, ly, { size: 11, mono: true, weight: i === 3 ? "700" : "600", color: s.c });
        if (s.sub) { txt(ctx, s.sub, tcX + 22, ly + 14, { size: 9.5, mono: true, color: P.faint }); ly += 14; }
        ly += 28;
      }
      ctx.globalAlpha = 1;

      let pTxt, pfg, pbg, pln;
      if (!resolved) { pTxt = "PENDING"; pfg = P.warn; pbg = P.warnBg; pln = P.warnLn; }
      else if (commitScene) { pTxt = "COMMITTED, DURABLE"; pfg = P.ok; pbg = P.okBg; pln = P.okLn; }
      else { pTxt = "ROLLED BACK, DISCARDED"; pfg = P.bad; pbg = P.badBg; pln = P.badLn; }
      pill(ctx, pTxt, tcX + 14, tcY + tcH - 26, pfg, pbg, pln);

      /* ── divider ── */
      ctx.strokeStyle = P.line; ctx.lineWidth = 1;
      ctx.beginPath(); ctx.moveTo(splitX, 52); ctx.lineTo(splitX, S.h - 16); ctx.stroke();

      /* ── RIGHT pane: the two tables, one touched row each ── */
      const rX = splitX + gap, rW = S.w - pad - rX;
      txt(ctx, "two tables, one row each", rX, 24, { size: 12.5, weight: "700", color: P.ink });
      txt(ctx, "the transaction touches one row in each", rX, 40, { size: 10.5, color: P.mut });

      const tables = [{ name: "accounts", hot: 1, v0: A0, v1: A1 }, { name: "ledger", hot: 0, v0: L0, v1: L1 }];
      const pg2 = 14, pw = (rW - pg2) / tables.length, py = 58, ph = 158;
      tables.forEach((t, i) => {
        const x = rX + i * (pw + pg2);
        box(ctx, x, py, pw, ph, 8, P.card, P.line2, 1);
        txt(ctx, t.name, x + 8, py + 15, { size: 9, mono: true, color: P.faint });
        for (let r = 0; r < 3; r++) {
          const sy = py + 28 + r * 40;
          if (r === t.hot) {
            const val = applied ? t.v1 : t.v0;
            const fill = applied ? P.okBg : (!resolved ? P.warnBg : P.soft);
            const ln = applied ? P.okLn : (!resolved ? P.warnLn : P.line2);
            box(ctx, x + 6, sy, pw - 12, 30, 6, fill, ln, flash > 0.3 ? 2.4 : 1.2);
            txt(ctx, "bal", x + 13, sy + 11, { size: 8.5, mono: true, color: P.mut });
            txt(ctx, val, x + pw - 13, sy + 19, { size: 12, mono: true, weight: "700", align: "right", color: applied ? P.ok : (!resolved ? P.warn : P.ink2) });
          } else {
            box(ctx, x + 6, sy, pw - 12, 30, 6, P.softer, P.line, 1);
            txt(ctx, "· · · · ·", x + 13, sy + 17, { size: 9, mono: true, color: P.faint, baseline: "middle" });
          }
        }
      });

      note(root, !resolved
        ? "A transaction groups changes into one unit. Until <code>COMMIT</code> nothing is final. The debit and the credit are staged together, and neither is visible to anyone else yet."
        : commitScene
          ? "<code>COMMIT</code> makes both writes durable at once. The rows now hold the new values and will survive a crash. <b>Both were written, or neither would have been.</b> That all-or-nothing unit is what eterDB reverses."
          : "<code>ROLLBACK</code>, or any failure before commit, discards the <b>whole</b> unit. Both rows still hold their old values and the half-finished transfer never happened. Those boundaries are what make a change cleanly reversible.");
    }
    S.resize();
    loopWhenVisible(root, S);
  }

  /* ════════════════════════════════════════════════════════════════════
     FIGURE 1, MVCC: one logical row, many physical versions on a timeline.
     Self-driving loop: two UPDATEs each append a version and stamp the
     previous one dead, the reader then travels back in time and sees the
     original value again (MVCC visibility), and finally VACUUM reclaims the
     dead versions, which is exactly the before-image eterDB needs.
     ════════════════════════════════════════════════════════════════════ */
  function figMvcc(root) {
    const S = stage(root, 300, render);
    const LOOP = 15;

    function render(ctx, S) {
      ctx.clearRect(0, 0, S.w, S.h);
      // Reduced motion: hold the richest pre-vacuum frame (three versions,
      // reader at "now") so the whole story is legible at a glance.
      const e = reduce ? 6 : now(S) % LOOP;

      // the heap at time e: UPDATEs land at 2.5s (tx 104) and 5s (tx 107)
      const versions = [{ xmin: 100, xmax: e >= 2.5 ? 104 : null, bal: "$500" }];
      if (e >= 2.5) versions.push({ xmin: 104, xmax: e >= 5 ? 107 : null, bal: "$420" });
      if (e >= 5) versions.push({ xmin: 107, xmax: null, bal: "$0.00" });

      // the reader follows "now", travels back to txid 101, returns, then VACUUM
      const vac = e >= 11.4;
      let reader;
      if (e < 2.5) reader = 101;
      else if (e < 5) reader = 106;
      else if (e < 7.5) reader = 110;
      else if (e < 9.6) reader = Math.round(lerp(110, 101, easeOut(clamp((e - 7.5) / 1.4, 0, 1))));
      else if (e < 11.4) reader = Math.round(lerp(101, 110, easeOut(clamp((e - 9.6) / 1.4, 0, 1))));
      else reader = 110;
      const travelling = e >= 7.5 && e < 11.4;

      const pad = 18, top = 52;
      txt(ctx, "accounts, id = 42", pad, 26, { size: 13, weight: "700", color: P.ink });
      txt(ctx, "one row, as Postgres actually stores it: a chain of versions", pad, 42, { size: 11.5, color: P.mut });

      // event banner, top right: what the loop just did
      if (!reduce) {
        let ev = null, evc = P.warn, evb = P.warnBg, evl = P.warnLn;
        if ((e >= 2.5 && e < 3.6) || (e >= 5 && e < 6.1)) ev = "UPDATE";
        else if (travelling) { ev = "reader travels back in time"; evc = P.past; evb = P.pastBg; evl = P.pastLn; }
        else if (vac && e < 12.8) { ev = "VACUUM"; evc = P.bad; evb = P.badBg; evl = P.badLn; }
        if (ev) {
          ctx.font = "600 10px " + P.mono;
          pill(ctx, ev, S.w - pad - (ctx.measureText(ev).width + 16), 14, evc, evb, evl);
        }
      }

      // visibility: xmin <= reader and (xmax is null or xmax > reader)
      let vis = -1;
      for (let i = versions.length - 1; i >= 0; i--) {
        const v = versions[i];
        if (v.xmin <= reader && (v.xmax === null || v.xmax > reader)) { vis = i; break; }
      }

      const cardW = Math.min(150, (S.w - pad * 2 - (versions.length - 1) * 14) / versions.length);
      const gap = 14;
      let x = pad;
      const cy = top + 70;
      versions.forEach((v, i) => {
        const dead = v.xmax !== null && v.xmax <= reader;
        const gone = vac && v.xmax !== null; // reclaimed by vacuum
        const seen = i === vis;
        const h = 96;
        if (gone) {
          ctx.save(); ctx.setLineDash([4, 5]); ctx.strokeStyle = P.line2; ctx.lineWidth = 1;
          ctx.strokeRect(x, cy, cardW, h); ctx.restore();
          txt(ctx, "v" + (i + 1), x + 12, cy + 22, { size: 12, weight: "700", mono: true, color: P.faint });
          txt(ctx, "reclaimed", x + cardW / 2, cy + h / 2 + 4, { size: 10, mono: true, align: "center", color: P.faint });
          txt(ctx, "by VACUUM", x + cardW / 2, cy + h / 2 + 18, { size: 10, mono: true, align: "center", color: P.faint });
        } else {
          const fill = dead ? P.badBg : seen ? P.okBg : P.card;
          const ln = dead ? P.badLn : seen ? P.okLn : P.line2;
          box(ctx, x, cy, cardW, h, 12, fill, ln, seen ? 2 : 1);
          txt(ctx, "v" + (i + 1), x + 12, cy + 22, { size: 12, weight: "700", mono: true, color: dead ? P.bad : P.ink });
          txt(ctx, v.bal, x + cardW - 12, cy + 22, { size: 15, weight: "700", mono: true, align: "right", color: dead ? P.bad : P.ink });
          txt(ctx, "xmin " + v.xmin, x + 12, cy + 48, { size: 10.5, mono: true, color: P.mut });
          txt(ctx, "xmax " + (v.xmax === null ? "∞" : v.xmax), x + 12, cy + 64, { size: 10.5, mono: true, color: v.xmax === null ? P.ok : P.bad });
          if (dead) pill(ctx, "DEAD", x + 12, cy + 74, P.bad, P.badBg, P.badLn);
          else if (seen) pill(ctx, "VISIBLE", x + cardW - 70, cy + 74, P.ok, P.okBg, P.okLn);
          else if (v.xmax === null) pill(ctx, "LIVE", x + cardW - 52, cy + 74, P.ok, P.okBg, P.okLn);
        }
        if (i < versions.length - 1) arrow(ctx, x + cardW, cy + h / 2, x + cardW + gap, cy + h / 2, P.line2, 1.5);
        x += cardW + gap;
      });

      // where the reader stands
      pill(ctx, "reader began @ txid " + reader, pad, cy + 96 + 14, travelling ? P.past : P.ink2, travelling ? P.pastBg : P.soft, travelling ? P.pastLn : P.line2);

      const seenV = versions[vis];
      note(root,
        e < 2.5
          ? "One logical row, one physical version. A reader that began at <b>txid 101</b> sees <b>$500</b>, the only version there is."
        : e < 5
          ? "An <code>UPDATE</code> doesn't overwrite. It appended <b>v2</b> and stamped v1 with <code>xmax&nbsp;104</code>. Dead v1 is the row as it was before the change: a ready-made before-image."
        : e < 7.5
          ? "A second <code>UPDATE</code> appends <b>v3</b>. Every retired version is still on the page, each one the before-image of the change that killed it."
        : !vac
          ? "The reader travels back: one that began at <b>txid " + reader + "</b> sees <b>" + (seenV ? seenV.bal : "") + "</b>. Visibility is decided per reader from <code>xmin</code>/<code>xmax</code>, so readers and writers never block each other. That's MVCC."
          : "<code>VACUUM</code> reclaimed the dead versions. The old values have <b>left the heap</b> for good. eterDB can't count on them, so it copies the before-image out of the way at commit time.");
    }
    S.resize();
    loopWhenVisible(root, S);
  }

  /* ════════════════════════════════════════════════════════════════════
     FIGURE 2, Heap page, line pointers, and a lying address (ctid).
     Self-driving walk-through: a row at (0,2) → UPDATE moves it → VACUUM
     frees the slot → a different row reuses (0,2). The address that meant
     "our row" now points at someone else's. This is the false-clean bug,
     made visible. Each step holds a few seconds, then the loop restarts.
     ════════════════════════════════════════════════════════════════════ */
  function figCtid(root) {
    const SLOTS = 6;
    // each slot: {ptr: tupleIndex|null}; tuples drawn in the body
    const STEPS = [
      { ptrs: [null, null, "R", null, null, null], live: { R: "(0,2)" }, who: { 2: "R" },
        cap: "Row <b>R</b>, a config value, is in slot 2 of heap page 0. Its <b>ctid</b>, its physical address, is <code>(0,2)</code>. A reader that touches R remembers this address." },
      { ptrs: [null, null, "Rd", null, null, "R"], live: { R: "(0,5)" }, who: { 2: "Rd", 5: "R" },
        cap: "An <code>UPDATE</code> on R writes a <b>new version</b> in slot 5 and marks slot 2 dead. R's ctid is now <code>(0,5)</code>. The old address still points at the dead tuple, for now." },
      { ptrs: [null, null, null, null, null, "R"], live: { R: "(0,5)" }, who: { 5: "R" },
        cap: "<code>VACUUM</code>, or HOT-pruning, reclaims the dead tuple and <b>frees line pointer 2</b>. Slot 2 is empty and available for reuse. Nothing remembers it once meant R." },
      { ptrs: [null, null, "S", null, null, "R"], live: { R: "(0,5)", S: "(0,2)" }, who: { 2: "S", 5: "R" },
        cap: "A new row <b>S</b> is inserted and <b>reuses slot 2</b>. The address <code>(0,2)</code> is alive again, but it points at <b>S</b>. A different row." },
    ];
    const STEP_T = 3.8;                       // seconds per step
    const LOOP = STEPS.length * STEP_T + 1.8; // linger on the trap before restarting
    const S = stage(root, 340, render);

    function render(ctx, S) {
      ctx.clearRect(0, 0, S.w, S.h);
      // Reduced motion: hold the final step, the reused slot IS the story.
      const e = reduce ? LOOP - 0.01 : now(S) % LOOP;
      const step = Math.min(STEPS.length - 1, Math.floor(e / STEP_T));
      const st = STEPS[step];
      const pad = 18;
      txt(ctx, "heap page 0", pad, 26, { size: 13, weight: "700" });
      txt(ctx, "step " + (step + 1) + " / " + STEPS.length, S.w - pad, 26, { size: 11, mono: true, color: P.faint, align: "right" });
      // step progress ticks under the counter
      for (let i = 0; i < STEPS.length; i++) {
        box(ctx, S.w - pad - (STEPS.length - i) * 14 + 2, 32, 10, 3, 0, i <= step ? P.ink2 : P.line2, null);
      }

      // line pointer array (the page header's array of slots)
      const top = 48, lpW = (S.w - pad * 2) / SLOTS;
      txt(ctx, "line pointers", pad, top - 4, { size: 10.5, color: P.faint, weight: "600" });
      for (let i = 0; i < SLOTS; i++) {
        const x = pad + i * lpW, occupied = st.ptrs[i] !== null;
        box(ctx, x + 3, top, lpW - 6, 30, 7, occupied ? P.soft : P.softer, occupied ? P.line2 : P.line, 1);
        txt(ctx, "(0," + i + ")", x + lpW / 2, top + 15, { size: 10.5, mono: true, align: "center", baseline: "middle", color: occupied ? P.ink2 : P.faint });
      }

      // tuple bodies
      const tTop = top + 70;
      txt(ctx, "tuples (row versions)", pad, tTop - 10, { size: 10.5, color: P.faint, weight: "600" });
      for (let i = 0; i < SLOTS; i++) {
        const x = pad + i * lpW, who = st.ptrs[i];
        const yy = tTop, hh = 92;
        if (who === null) {
          box(ctx, x + 3, yy, lpW - 6, hh, 9, P.softer, P.line, 1);
          ctx.save(); ctx.setLineDash([3, 4]); ctx.strokeStyle = P.line2;
          ctx.strokeRect(x + 9, yy + 8, lpW - 18, hh - 16); ctx.restore();
          txt(ctx, "free", x + lpW / 2, yy + hh / 2, { size: 10.5, mono: true, align: "center", baseline: "middle", color: P.faint });
        } else {
          const dead = who === "Rd";
          const name = dead ? "R" : who;
          const isR = name === "R";
          const fill = dead ? P.badBg : isR ? P.okBg : P.pastBg;
          const ln = dead ? P.badLn : isR ? P.okLn : P.pastLn;
          const fg = dead ? P.bad : isR ? P.ok : P.past;
          box(ctx, x + 3, yy, lpW - 6, hh, 9, fill, ln, dead ? 1 : 2);
          txt(ctx, name, x + lpW / 2, yy + 30, { size: 20, weight: "800", align: "center", color: fg });
          txt(ctx, isR ? "config" : "other row", x + lpW / 2, yy + 52, { size: 10, mono: true, align: "center", color: P.mut });
          if (dead) pill(ctx, "DEAD", x + lpW / 2 - 18, yy + 64, P.bad, P.card, P.badLn);
          else pill(ctx, name === "R" ? "ctid " + st.live.R : "ctid " + st.live.S, x + 8, yy + 64, fg, P.card, ln);
        }
        // connector from line pointer to tuple
        if (who !== null) arrow(ctx, x + lpW / 2, top + 30, x + lpW / 2, tTop, P.line2, 1.4);
      }

      note(root, st.cap + (step === STEPS.length - 1
        ? " <b style='color:" + P.bad + "'>The trap:</b> resolve R's key later by reading <code>(0,2)</code> and you get S. The read-edge to R is lost. eterDB resolves the key at <em>read</em> time, before vacuum can move anything."
        : ""));
    }
    S.resize();
    loopWhenVisible(root, S);
  }

  /* ════════════════════════════════════════════════════════════════════
     FIGURE 3, Writes: before/after from the WAL, and the cost of FULL.
     A WAL record streams into the capture sidecar, which emits a history
     row. Self-driving: the loop alternates REPLICA IDENTITY FULL with the
     default identity each pass, with it on the old row is in the WAL and
     undo is possible; off, only the key is, no before-image.
     ════════════════════════════════════════════════════════════════════ */
  function figWal(root) {
    const S = stage(root, 300, render);
    const LOOP = 7;

    function render(ctx, S) {
      ctx.clearRect(0, 0, S.w, S.h);
      let e, loopN;
      // Reduced motion: FULL identity, record delivered, the reversible case.
      if (reduce) { e = LOOP; loopN = 0; }
      else { const tg = now(S); loopN = Math.floor(tg / LOOP); e = tg % LOOP; }
      const full = loopN % 2 === 0; // alternate the identity each pass
      const phase = clamp(e / 2.8, 0, 1); // one WAL record per pass (eased at draw)

      const pad = 18;
      txt(ctx, "UPDATE inventory SET cost = '$0.00' WHERE sku = 'VB-01'", pad, 24, { size: 12, mono: true, weight: "600", color: P.ink2 });
      chips(ctx, pad, 36, ["REPLICA IDENTITY FULL", "default (key only)"], full ? 0 : 1);

      const beltY = 92, beltX0 = pad, beltX1 = S.w - pad;
      // lanes
      txt(ctx, "WAL stream", pad, beltY - 22, { size: 10.5, weight: "600", color: P.faint });
      box(ctx, beltX0, beltY - 8, beltX1 - beltX0, 56, 10, P.soft, P.line, 1);

      // a moving WAL record card
      const recW = 196;
      const rx = lerp(beltX0 + 6, beltX1 - recW - 6 - 150, easeOut(phase));
      box(ctx, rx, beltY, recW, 40, 8, P.card, P.line2, 1);
      txt(ctx, "UPDATE inventory", rx + 10, beltY + 16, { size: 10.5, mono: true, weight: "600", color: P.ink });
      txt(ctx, full ? "old: {VB-01, '$2.40M'}" : "old: {sku: VB-01}", rx + 10, beltY + 31,
        { size: 10, mono: true, color: full ? P.ok : P.bad });

      // sidecar box on the right
      const scX = beltX1 - 150, scY = beltY - 8;
      box(ctx, scX, scY, 150, 56, 10, P.pastBg, P.pastLn, 1.5);
      txt(ctx, "capture sidecar", scX + 75, scY + 20, { size: 11, weight: "700", align: "center", color: P.past });
      txt(ctx, "logical decoding", scX + 75, scY + 38, { size: 9.5, mono: true, align: "center", color: P.mut });

      // emitted history row
      const hy = 188;
      txt(ctx, "eter.history (append-only)", pad, hy - 10, { size: 10.5, weight: "600", color: P.faint });
      box(ctx, pad, hy, S.w - pad * 2, 56, 10, full ? P.okBg : P.badBg, full ? P.okLn : P.badLn, 1.5);
      txt(ctx, "txid 8842, inventory, pk VB-01", pad + 14, hy + 22, { size: 11.5, mono: true, weight: "600", color: P.ink2 });
      txt(ctx, full ? "before  $2.40M   →   after  $0.00" : "before  ??????   →   after  $0.00",
        pad + 14, hy + 41, { size: 12, mono: true, weight: "700", color: full ? P.ok : P.bad });
      const tag = full ? "REVERSIBLE" : "CANNOT UNDO";
      ctx.font = "600 10px " + P.mono;
      const tw = ctx.measureText(tag).width + 16;
      pill(ctx, tag, S.w - pad - tw - 14, hy + 19, full ? P.ok : P.bad, P.card, full ? P.okLn : P.badLn);

      // write-amplification meter
      const my = 268;
      txt(ctx, "WAL write volume", pad, my, { size: 10.5, color: P.faint, weight: "600", baseline: "middle" });
      const mx = pad + 130, mw = S.w - pad - mx;
      box(ctx, mx, my - 6, mw, 12, 6, P.soft, P.line, 1);
      box(ctx, mx, my - 6, mw * (full ? 1 : 0.34), 12, 6, full ? P.warn : P.ok, null);

      note(root, full
        ? "With <code>REPLICA IDENTITY FULL</code>, every <code>UPDATE</code> logs the <b>full old row</b> to the WAL. The sidecar reconstructs the before/after pair, so undo works. The cost is write amplification (the meter). Opt-in per table."
        : "With the default replica identity, only the <b>primary key</b> is logged. The sidecar sees what the row changed to, but not <b>from</b>, so there's no before-image and no row-level undo. A table you never need to undo keeps the default and skips the cost.");
    }
    S.resize();
    loopWhenVisible(root, S);
  }

  /* ════════════════════════════════════════════════════════════════════
     FIGURE 4, The shape of the system, as an auto-looping flow. A vertical
     boundary splits "inside the engine" (left, small) from "out of process"
     (right, everything). Capture streams run continuously: writes (blue) leave
     via logical decoding after commit, the read-set (amber) is captured inside
     the engine, the one piece that must be, and both land in the store. The
     revert path (green) pulses periodically: rare, on-demand, flowing back in.
     Hover any box for detail. ════════════════════════════════════════════ */
  function figArch(root) {
    const S = stage(root, 430, render);
    S.sp = springs(); S.minW = 720;
    let hot = null;

    const R = (x, y, w, h) => ({ x, y, w, h, cx: x + w / 2, cy: y + h / 2, r: x + w, b: y + h });

    function layout(S) {
      const pad = 20;
      const boundary = clamp(S.w * 0.46, 340, 480);
      const pgX = pad + 8, pgR = boundary - 24, pgW = pgR - pgX, pgY = 116, pgH = 182;
      const N = {};
      N.app = R(0, 0, 196, 40); N.app.x = (pgX + pgR) / 2 - 98; N.app.y = 46; N.app.cx = (pgX + pgR) / 2; N.app.r = N.app.x + 196; N.app.b = 86; N.app.cy = 66;
      N.pg = R(pgX, pgY, pgW, pgH);
      N.tables = R(pgX + 12, pgY + 36, pgW - 24, 44);   // your tables + write history
      N.amber = R(pgX + 12, pgY + 92, pgW - 24, 50);    // read capture (in-engine)
      N.cli = R(pgX, 330, pgW, 42);
      const rX = boundary + 18, rW = S.w - pad - rX;
      N.cap = R(rX, 72, rW, 48);
      N.store = R(rX, 168, rW, 66);
      N.sto = R(rX, 282, rW, 48);
      return { pad, boundary, N };
    }

    S.onmove = (S) => {
      const { N } = layout(S);
      hot = null;
      for (const k of ["app", "cap", "store", "sto", "cli", "amber", "pg"]) {
        const a = N[k];
        if (S.mx >= a.x && S.mx <= a.r && S.my >= a.y && S.my <= a.b) { hot = (k === "amber" ? "pg" : k); break; }
      }
      S.canvas.style.cursor = hot ? "pointer" : "default";
    };

    function dots(ctx, ax, ay, bx, by, col, n, speed, tt, on) {
      if (!on) return;
      for (let k = 0; k < n; k++) {
        const ph = ((tt * speed) + k / n) % 1;
        ctx.beginPath(); ctx.arc(lerp(ax, bx, ph), lerp(ay, by, ph), 3, 0, Math.PI * 2);
        ctx.fillStyle = col; ctx.fill();
      }
    }

    function render(ctx, S) {
      ctx.clearRect(0, 0, S.w, S.h);
      const { pad, boundary, N } = layout(S);
      const tt = reduce ? 0 : now(S);
      const revertOn = !reduce && (tt % 9) > 5.2;  // revert pulses ~3.8s of every 9s

      // boundary divider
      ctx.save();
      ctx.strokeStyle = P.line2; ctx.lineWidth = 1; ctx.setLineDash([4, 5]);
      ctx.beginPath(); ctx.moveTo(boundary, 40); ctx.lineTo(boundary, S.h - 18); ctx.stroke();
      ctx.restore();
      txt(ctx, "INSIDE THE ENGINE", boundary - 12, 30, { size: 9.5, weight: "700", mono: true, align: "right", color: P.faint });
      txt(ctx, "OUT OF PROCESS", boundary + 12, 30, { size: 9.5, weight: "700", mono: true, color: P.faint });

      // ── edges (lines + flow dots), drawn under the nodes ──
      const blue = P.past, amber = P.warn, green = P.ok;
      const hl = (a, b) => hot && (hot === a || hot === b);
      // app → pg (SQL/commit)
      arrow(ctx, N.app.cx, N.app.b, N.pg.cx, N.pg.y, hl("app", "pg") ? P.ink : P.line2, hl("app", "pg") ? 2 : 1.3, [5, 5]);
      dots(ctx, N.app.cx, N.app.b, N.pg.cx, N.pg.y, P.ink2, 2, 0.32, tt, !revertOn);
      // pg.tables → cap → store (writes, blue, after commit)
      arrow(ctx, N.tables.r, N.tables.cy, N.cap.x, N.cap.cy, blue, hl("pg", "cap") ? 2.2 : 1.4, [5, 5]);
      arrow(ctx, N.cap.cx, N.cap.b, N.store.cx, N.store.y, blue, hl("cap", "store") ? 2.2 : 1.4, [5, 5]);
      dots(ctx, N.tables.r, N.tables.cy, N.cap.x, N.cap.cy, blue, 2, 0.4, tt, !revertOn);
      dots(ctx, N.cap.cx, N.cap.b, N.store.cx, N.store.y, blue, 2, 0.5, tt + 0.4, !revertOn);
      // pg.amber → store (read-set, amber, in-engine capture crossing the boundary)
      arrow(ctx, N.amber.r, N.amber.cy, N.store.x, N.store.cy, amber, hl("pg", "store") ? 2.4 : 1.6, [5, 5]);
      dots(ctx, N.amber.r, N.amber.cy, N.store.x, N.store.cy, amber, 3, 0.42, tt, !revertOn);
      // pg → storage sidecar (WAL + snapshots)
      arrow(ctx, N.pg.r, N.pg.b - 24, N.sto.x, N.sto.cy, hl("pg", "sto") ? P.ink : P.line2, hl("pg", "sto") ? 2 : 1.3, [5, 5]);
      dots(ctx, N.pg.r, N.pg.b - 24, N.sto.x, N.sto.cy, P.faint, 1, 0.3, tt, !revertOn);
      // sto → store (snapshot metadata, faint)
      arrow(ctx, N.sto.cx, N.sto.y, N.store.cx, N.store.b, P.line2, 1.2, [4, 5]);
      // revert path (green): cli → store (derive) and cli → pg (compensating DML)
      arrow(ctx, N.cli.r - 24, N.cli.y, N.store.x, N.store.b, revertOn ? green : P.line2, revertOn ? 2.2 : 1, [5, 5]);
      arrow(ctx, N.cli.cx, N.cli.y, N.pg.cx, N.pg.b, revertOn ? green : P.line2, revertOn ? 2.2 : 1, [5, 5]);
      dots(ctx, N.store.x, N.store.b, N.cli.r - 24, N.cli.y, green, 2, 0.5, tt, revertOn);
      dots(ctx, N.cli.cx, N.cli.y, N.pg.cx, N.pg.b, green, 2, 0.5, tt + 0.3, revertOn);

      // ── nodes ──
      // engine container
      box(ctx, N.pg.x, N.pg.y, N.pg.w, N.pg.h, 12, hot === "pg" ? "#fbfaf6" : "#fcfcfb", hot === "pg" ? amber : P.line2, hot === "pg" ? 2 : 1.5);
      txt(ctx, "Main Postgres", N.pg.x + 14, N.pg.y + 22, { size: 12, weight: "700", color: P.ink });
      txt(ctx, "near-stock + patch", N.pg.r - 12, N.pg.y + 22, { size: 9, mono: true, align: "right", color: P.faint });
      box(ctx, N.tables.x, N.tables.y, N.tables.w, N.tables.h, 8, P.softer, P.line2, 1);
      txt(ctx, "your tables", N.tables.x + 12, N.tables.cy - 6, { size: 11, weight: "700", baseline: "middle", color: P.ink2 });
      txt(ctx, "rows + the writes to undo", N.tables.x + 12, N.tables.cy + 9, { size: 9, mono: true, baseline: "middle", color: P.mut });
      box(ctx, N.amber.x, N.amber.y, N.amber.w, N.amber.h, 8, P.warnBg, P.warnLn, 1.6);
      txt(ctx, "read capture", N.amber.x + 12, N.amber.cy - 7, { size: 11, weight: "700", baseline: "middle", color: P.warn });
      txt(ctx, "what each query read, the one in-engine piece", N.amber.x + 12, N.amber.cy + 9, { size: 9, mono: true, baseline: "middle", color: P.warn });

      function node(n, label, sub, key, accent) {
        const on = hot === key;
        box(ctx, n.x, n.y, n.w, n.h, 9, on ? P.pastBg : P.card, on ? P.past : (accent || P.line2), on ? 2 : 1.2);
        txt(ctx, label, n.cx, n.cy - 7, { size: 11, weight: "700", align: "center", baseline: "middle", color: on ? P.past : P.ink });
        txt(ctx, sub, n.cx, n.cy + 9, { size: 9, mono: true, align: "center", baseline: "middle", color: on ? P.past : P.mut });
      }
      node(N.app, "App / agent", "any driver, READ COMMITTED", "app");
      node(N.cap, "capture sidecar", "logical decoding, post-commit", "cap", P.pastLn);
      node(N.store, "metadata store", "history, read-set, graph, ddl", "store", P.pastLn);
      node(N.sto, "storage sidecar", "base backups, WAL archive", "sto");
      node(N.cli, "eter CLI / orchestrator", "preview, undo (on demand)", "cli", revertOn ? P.okLn : P.line2);

      note(root, hot
        ? "<b>" + ({ app: "App / agent", pg: "Main Postgres", cap: "capture sidecar", store: "metadata store", sto: "storage sidecar", cli: "eter CLI / orchestrator" })[hot] + "</b>, " + ({
            app: "your app or agent connects over the normal Postgres wire protocol, any driver, at READ COMMITTED. It runs SQL and never talks to eterDB directly.",
            pg: "near-stock Postgres with a small patch. Read capture (amber) is the only eterDB piece that must live <em>inside</em> it, because a read leaves no trace anywhere else.",
            cap: "reads the replication slot out of process and turns the WAL into before/after history. After each commit, never on the commit path.",
            store: "a per-tenant Postgres holding write history, the forwarded read-set, the DDL log and backup metadata. The dependency graph is derived here on demand, only when you preview or undo.",
            sto: "takes pg_basebackup base backups and archives WAL. Recovery replays a copy in a throwaway Postgres: schema recovery and point-in-time reads, no privileged storage anywhere.",
            cli: "what you or the agent drive, at one URL. On a revert it reads the graph from the store and applies compensating DML back into your tables (the green path), only when you ask. Minutes-long recoveries run as managed background jobs.",
          })[hot]
        : "Almost everything runs <em>out of process</em>, because reverts are rare and don't need to be fast. Writes (<b style='color:" + blue + "'>blue</b>) stream out via logical decoding after commit. The read-set (<b style='color:" + amber + "'>amber</b>) is captured <b>inside</b> the engine, the one piece that has to be. The revert path (<b style='color:" + green + "'>green</b>) runs on demand. Hover any box for detail.");
    }
    S.resize();
    loopWhenVisible(root, S);
  }

  /* ════════════════════════════════════════════════════════════════════
     FIGURE 5, The dependency a backup can't see (the centerpiece).
     Two transactions over time: A writes a config, B reads it then writes a
     derived invoice. Self-driving, four scenes: a backup's view (writes
     only, the read is invisible), undo A there, silently wrong; then
     eterDB's view (the predicate read is captured as an rw-edge), undo A,
     and B is flagged. Then the loop restarts.
     ════════════════════════════════════════════════════════════════════ */
  function figReads(root) {
    const S = stage(root, 340, render);
    const SCENE = 4.5, LOOP = SCENE * 4;

    function render(ctx, S) {
      ctx.clearRect(0, 0, S.w, S.h);
      // Reduced motion: the final scene, eterDB's view with A undone and B flagged.
      const e = reduce ? LOOP - 1 : now(S) % LOOP;
      const scene = Math.min(3, Math.floor(e / SCENE));
      const view = scene < 2 ? "backup" : "eter";
      const undone = scene % 2 === 1;
      const u = undone ? easeOut(clamp((e - scene * SCENE) / 0.9, 0, 1)) : 0;

      const pad = 22;
      chips(ctx, pad, 12, ["what a backup sees", "what eterDB sees"], view === "eter" ? 1 : 0);
      if (undone) {
        ctx.font = "600 10px " + P.mono;
        const s = "eter undo A --apply";
        pill(ctx, s, S.w - pad - (ctx.measureText(s).width + 16), 12, P.ink2, P.soft, P.line2);
      }
      // time axis
      const axY = 250, x0 = pad + 40, x1 = S.w - pad;
      ctx.strokeStyle = P.line2; ctx.lineWidth = 1;
      ctx.beginPath(); ctx.moveTo(x0, axY); ctx.lineTo(x1, axY); ctx.stroke();
      txt(ctx, "time →", x1, axY + 16, { size: 10, color: P.faint, align: "right" });
      const tx = (f) => lerp(x0, x1 - 40, f);

      // lane labels
      const laneA = 78, laneB = 168;
      txt(ctx, "txn A", pad, laneA, { size: 12, weight: "700", mono: true, color: P.ink, baseline: "middle" });
      txt(ctx, "txn B", pad, laneB, { size: 12, weight: "700", mono: true, color: P.ink, baseline: "middle" });

      const seesRead = view === "eter";

      // A: writes config 100 -> 0 at t=0.18
      const aF = 0.18;
      const aReverted = u > 0.5;
      const aFill = aReverted ? P.okBg : P.badBg, aLn = aReverted ? P.okLn : P.badLn, aFg = aReverted ? P.ok : P.bad;
      const ew = 168;
      box(ctx, tx(aF), laneA - 22, ew, 44, 9, aFill, aLn, 1.4);
      txt(ctx, "WRITE app_config", tx(aF) + 12, laneA - 4, { size: 10.5, mono: true, weight: "600", color: aFg });
      txt(ctx, aReverted ? "max_qty 0 → 100  (reverted)" : "max_qty 100 → 0", tx(aF) + 12, laneA + 12, { size: 10.5, mono: true, color: aFg });
      // tick to axis
      ctx.setLineDash([3, 4]); ctx.strokeStyle = P.line2; ctx.beginPath(); ctx.moveTo(tx(aF) + ew / 2, laneA + 22); ctx.lineTo(tx(aF) + ew / 2, axY); ctx.stroke(); ctx.setLineDash([]);

      // B: reads config at t=0.46, writes invoice at t=0.66
      const rF = 0.46, wF = 0.7;
      // read marker
      const readDim = !seesRead;
      const rCol = readDim ? P.faint : P.past;
      ctx.globalAlpha = readDim ? 0.4 : 1;
      box(ctx, tx(rF), laneB - 22, 150, 44, 9, readDim ? P.softer : P.pastBg, readDim ? P.line : P.pastLn, 1.4);
      txt(ctx, "READ app_config", tx(rF) + 12, laneB - 4, { size: 10.5, mono: true, weight: "600", color: rCol });
      txt(ctx, readDim ? "(leaves no trace)" : "sees max_qty = 0", tx(rF) + 12, laneB + 12, { size: 10.5, mono: true, color: rCol });
      ctx.globalAlpha = 1;

      // B write invoice
      const bWrong = u > 0.5;
      const bFill = bWrong ? P.badBg : P.card, bLn = bWrong ? P.badLn : P.line2, bFg = bWrong ? P.bad : P.ink2;
      box(ctx, tx(wF), laneB - 22, 150, 44, 9, bFill, bLn, bWrong ? 1.6 : 1.2);
      txt(ctx, "WRITE invoice", tx(wF) + 12, laneB - 4, { size: 10.5, mono: true, weight: "600", color: bFg });
      txt(ctx, "computed off max_qty", tx(wF) + 12, laneB + 12, { size: 10, mono: true, color: bWrong ? P.bad : P.mut });

      // the rw dependency edge B.read -> A.write
      if (seesRead) {
        const x1e = tx(rF) + 75, y1e = laneB - 22, x2e = tx(aF) + ew / 2, y2e = laneA + 22;
        ctx.save();
        ctx.strokeStyle = P.warn; ctx.lineWidth = 2; ctx.setLineDash([5, 4]);
        ctx.beginPath();
        ctx.moveTo(x1e, y1e);
        ctx.bezierCurveTo(x1e, (y1e + y2e) / 2, x2e, (y1e + y2e) / 2, x2e, y2e);
        ctx.stroke(); ctx.restore();
        const mxL = (x1e + x2e) / 2;
        pill(ctx, "rw-edge: B read what A wrote", mxL - 80, (y1e + y2e) / 2 - 9, P.warn, P.warnBg, P.warnLn);
      }

      // verdict band
      const vy = 290;
      let v, vc, vb, vl;
      if (u < 0.5) {
        v = seesRead ? "eterDB captured B's read as a dependency on A." : "A backup logged both writes, but not the read that ties them together.";
        vc = P.mut; vb = P.soft; vl = P.line;
      } else if (seesRead) {
        v = "Undo A: eterDB flags B as dependent and surfaces it.";
        vc = P.ok; vb = P.okBg; vl = P.okLn;
      } else {
        v = "Undo A: B still holds an invoice computed from a value that no longer exists. Nothing flags it.";
        vc = P.bad; vb = P.badBg; vl = P.badLn;
      }
      box(ctx, pad, vy, S.w - pad * 2, 34, 9, vb, vl, 1);
      txt(ctx, v, pad + 14, vy + 17, { size: 11.5, weight: "600", color: vc, baseline: "middle" });

      note(root, [
        "A read leaves <b>nothing behind</b>. No row, no log entry. Triggers and CDC streams never see it, so a backup logs both writes but not the read that ties them together.",
        "Undo A from the backup's view: the config reverts, but B's invoice still holds a value computed from data that <b>no longer exists</b>. Nothing flags it. Silently wrong.",
        "The same history through eterDB's eyes. Postgres already tracks who-read-what to enforce <code>SERIALIZABLE</code>. The patch reads that tracking in <b>observe mode</b>, with no extra aborts and no change to results, and records the <b>rw-edge</b> from B to A.",
        "Undo A from eterDB's view: the rw-edge is in the graph, so B is flagged <b>dependent</b> and surfaced. Undo it too, or know exactly what diverges.",
      ][scene]);
    }
    S.resize();
    loopWhenVisible(root, S);
  }

  /* ════════════════════════════════════════════════════════════════════
     FIGURE 6, Computing an undo: the dependency graph and the dependent set.
     The bad write plus dependents and unrelated transactions. Self-driving:
     the loop cycles the three modes (clean_only / cascade / targeted) and
     shows which transactions get reverted, skipped, or left untouched.
     ════════════════════════════════════════════════════════════════════ */
  function figGraph(root) {
    const MODES = ["clean_only", "cascade", "targeted"];
    const MODE_T = 4.5, LOOP = MODES.length * MODE_T;
    const S = stage(root, 360, render);
    // nodes
    const nodes = {
      t41: { x: 0.5, y: 70, label: "tx41", sub: "bad write" },
      t43: { x: 0.26, y: 190, label: "tx43", sub: "invoice, read" },
      t45: { x: 0.5, y: 210, label: "tx45", sub: "invoice, read" },
      t49: { x: 0.74, y: 190, label: "tx49", sub: "audit, seq-scan", over: true },
      t44: { x: 0.16, y: 310, label: "tx44", sub: "unrelated" },
      t46: { x: 0.84, y: 310, label: "tx46", sub: "unrelated" },
    };
    const edges = [["t43", "t41", "rw exact"], ["t45", "t41", "rw exact"], ["t49", "t41", "rw over-approx"]];

    // status per node given mode
    function status(k, mode) {
      const dependents = ["t43", "t45", "t49"];
      if (k === "t41") {
        if (mode === "clean_only") return "blocked";
        return "revert";
      }
      if (dependents.includes(k)) {
        if (mode === "cascade") return "revert";
        if (mode === "targeted") return "diverge";
        return "skip"; // clean_only
      }
      return "untouched";
    }

    function render(ctx, S) {
      ctx.clearRect(0, 0, S.w, S.h);
      // Reduced motion: clean_only, the default and the safety story.
      const e = reduce ? 0.1 : now(S) % LOOP;
      const mode = MODES[Math.min(MODES.length - 1, Math.floor(e / MODE_T))];
      txt(ctx, "undo mode", 18, 21, { size: 10, weight: "600", color: P.faint, baseline: "middle" });
      chips(ctx, 84, 12, MODES, MODES.indexOf(mode));
      // edges first
      edges.forEach(([a, b, lbl]) => {
        const na = nodes[a], nb = nodes[b];
        const ax = na.x * S.w, ay = na.y, bx = nb.x * S.w, by = nb.y + 26;
        const over = na.over;
        arrow(ctx, ax, ay - 26, bx, by, over ? P.faint : P.warn, over ? 1.4 : 2, over ? [5, 4] : []);
        const mx = (ax + bx) / 2, my = (ay + by) / 2;
        pill(ctx, lbl, mx - 34, my - 9, over ? P.faint : P.warn, P.card, over ? P.line2 : P.warnLn);
      });
      // nodes
      for (const k of Object.keys(nodes)) {
        const n = nodes[k], cx = n.x * S.w, cy = n.y, r = 30;
        const st = status(k, mode);
        let fill = P.card, ln = P.line2, fg = P.ink2, tag = "";
        if (k === "t41" && st === "blocked") { fill = P.badBg; ln = P.bad; fg = P.bad; tag = "BLOCKED"; }
        else if (st === "revert") { fill = P.okBg; ln = P.ok; fg = P.ok; tag = "REVERTED"; }
        else if (st === "skip") { fill = P.warnBg; ln = P.warn; fg = P.warn; tag = "SKIPPED"; }
        else if (st === "diverge") { fill = P.badBg; ln = P.badLn; fg = P.bad; tag = "DIVERGED"; }
        else { fill = P.softer; ln = P.line2; fg = P.mut; tag = ""; }
        ctx.beginPath(); ctx.arc(cx, cy, r, 0, Math.PI * 2); ctx.fillStyle = fill; ctx.fill();
        ctx.lineWidth = (st === "untouched") ? 1 : 2; ctx.strokeStyle = ln; ctx.stroke();
        txt(ctx, n.label, cx, cy - 3, { size: 12, weight: "700", mono: true, align: "center", baseline: "middle", color: fg });
        txt(ctx, n.sub, cx, cy + 44, { size: 9.5, mono: true, align: "center", baseline: "middle", color: P.mut });
        if (tag) pill(ctx, tag, cx - 34, cy + 10, fg, P.card, ln);
      }
      // legend / readout handled by note
      const txt2 = {
        clean_only: "<b>clean_only</b>, the default: tx41 has live dependents, so eterDB <b>refuses and reports</b>. It returns the exact dependents (tx43, tx45) plus the over-approx candidate (tx49), and touches nothing.",
        cascade: "<b>cascade</b>: reverse tx41 <b>and</b> everything that read it, newest-first. The two invoices that consumed the bad value are reverted alongside it. Unrelated tx44/tx46 stay live.",
        targeted: "<b>targeted</b>: reverse tx41 only and <b>leave</b> the dependents, which then diverge from a value that no longer exists. Your call, made explicitly.",
      }[mode];
      note(root, txt2 + " The dashed grey edge to tx49 is <b>over-approximate</b>. It only looks dependent because a writer seq-scanned the table. An index makes it tuple-precise.");
    }
    S.resize();
    loopWhenVisible(root, S);
  }

  /* ════════════════════════════════════════════════════════════════════
     FIGURE 7, Base backups + WAL replay (PITR) recovery and as-of reads.
     A timeline of base backups with WAL archived continuously between them.
     Self-driving script: the 2 PM deploy ships and a DROP runs (its WAL
     position recorded), the read head scrubs back for an as-of 1:55 PM read,
     then recovery runs, copy the newest base backup from before the drop
     into a throwaway Postgres, replay archived WAL to one instant before
     the drop, extract the table back into live. Then the loop restarts.
     ════════════════════════════════════════════════════════════════════ */
  function figPitr(root) {
    const LOOP = 22;
    const S = stage(root, 344, render);

    function render(ctx, S) {
      ctx.clearRect(0, 0, S.w, S.h);
      // t: 0 = reading as-of 1:55 PM, 1 = reading live · r: recovery progress
      let deployed, r, t;
      if (reduce) { deployed = true; r = 1; t = 1; } // static end-state: recovered
      else {
        const e = now(S) % LOOP;
        if (e < 3) { deployed = false; r = 0; t = 1; }        // backups on a cadence
        else if (e < 6) { deployed = true; r = 0; t = 1; }    // the DROP runs
        else if (e < 12) {                                    // as-of read of the past
          deployed = true; r = 0;
          if (e < 7.4) t = 1 - easeOut((e - 6) / 1.4);
          else if (e < 10.6) t = 0;
          else t = easeOut((e - 10.6) / 1.4);
        } else { deployed = true; t = 1; r = clamp((e - 12) / 4.6, 0, 1); } // recover, hold
      }
      const pad = 22, asOf = t < 0.5;
      const recovering = r > 0.02, recovered = r > 0.95;
      txt(ctx, "parts_cost, base backups + archived WAL", pad, 24, { size: 13, weight: "700" });

      // ── live database box (top right) ──
      const db = { w: 208, h: 82 };
      db.x = S.w - pad - db.w; db.y = 38;
      box(ctx, db.x, db.y, db.w, db.h, 9, P.card, P.line2, 1.4);
      txt(ctx, "live database", db.x + 12, db.y + 18, { size: 11, weight: "700", color: P.ink });
      txt(ctx, "vendors", db.x + 12, db.y + 36, { size: 10, mono: true, color: P.ink2 });
      txt(ctx, "purchase_orders", db.x + 12, db.y + 51, { size: 10, mono: true, color: P.ink2 });
      const gone = deployed && !recovered;
      txt(ctx, "parts_cost", db.x + 12, db.y + 66, { size: 10, mono: true, color: gone ? P.bad : (recovered && deployed ? P.ok : P.ink2) });
      if (gone) {
        const w = ctx.measureText("parts_cost").width;
        ctx.strokeStyle = P.bad; ctx.lineWidth = 1.2;
        ctx.beginPath(); ctx.moveTo(db.x + 12, db.y + 62.5); ctx.lineTo(db.x + 12 + w, db.y + 62.5); ctx.stroke();
        pill(ctx, "DROPPED", db.x + db.w - 76, db.y + 56, P.bad, P.badBg, P.badLn);
      } else if (deployed && recovered) {
        pill(ctx, "RECOVERED", db.x + db.w - 90, db.y + 56, P.ok, P.okBg, P.okLn);
      }

      // ── timeline: 1:00 PM … now (2:05 PM) ──
      const A = 172;                                   // axis y
      const x0 = pad + 8, x1 = S.w - pad - 14;        // axis extent
      const xAt = (min) => x0 + (min / 65) * (x1 - x0);
      const xB1 = xAt(0), xB2 = xAt(40), xDrop = xAt(60), xAsOf = xAt(55);
      arrow(ctx, x0 - 6, A, x1 + 12, A, P.line2, 1.4);
      txt(ctx, "now", x1 + 12, A - 10, { size: 9.5, mono: true, align: "right", color: P.faint });

      // WAL segments along the axis (archived continuously)
      const segW = 14, segGap = 6;
      for (let x = x0 + 30; x + segW < x1 - 4; x += segW + segGap) {
        const inReplay = x + segW / 2 >= xB2 && x + segW / 2 <= xB2 + Math.max(0, Math.min(1, (r - 0.3) / 0.5)) * (xDrop - xB2) && recovering;
        const inAsOf = asOf && !recovering && x + segW / 2 >= xB2 && x + segW / 2 <= xAsOf;
        box(ctx, x, A - 6, segW, 12, 3,
          inReplay || inAsOf ? P.pastBg : P.soft,
          inReplay || inAsOf ? P.past : P.line2, inReplay || inAsOf ? 1.4 : 1);
      }
      txt(ctx, "WAL, archived continuously", x0 + 30, A + 24, { size: 9.5, mono: true, color: P.faint });

      // base-backup markers
      function base(x, label, dim) {
        box(ctx, x - 27, A - 50, 54, 32, 6, dim ? P.softer : P.pastBg, dim ? P.line2 : P.pastLn, dim ? 1 : 1.5);
        txt(ctx, "base", x, A - 34, { size: 10, weight: "700", mono: true, align: "center", color: dim ? P.mut : P.past });
        txt(ctx, label, x, A + 24, { size: 9.5, mono: true, align: "center", color: dim ? P.faint : P.mut });
        ctx.strokeStyle = dim ? P.line2 : P.pastLn; ctx.lineWidth = 1;
        ctx.beginPath(); ctx.moveTo(x, A - 18); ctx.lineTo(x, A - 7); ctx.stroke();
      }
      base(xB1, "1:00 PM", true);
      base(xB2, "1:40 PM", false);

      // the DROP tick
      if (deployed) {
        ctx.strokeStyle = P.bad; ctx.lineWidth = 2;
        ctx.beginPath(); ctx.moveTo(xDrop, A - 22); ctx.lineTo(xDrop, A + 10); ctx.stroke();
        txt(ctx, "2:00 PM DROP", xDrop, A + 24, { size: 9.5, mono: true, weight: "600", align: "center", color: P.bad });
        if (!(asOf && !recovering)) { // the as-of scrub marker uses this spot
          pill(ctx, "position → eter.ddl_log", xDrop - 74, A - 44, P.bad, P.badBg, P.badLn);
        }
      }
      // as-of scrub marker
      if (asOf && !recovering) {
        ctx.strokeStyle = P.past; ctx.lineWidth = 1.6; ctx.setLineDash([4, 4]);
        ctx.beginPath(); ctx.moveTo(xAsOf, A - 22); ctx.lineTo(xAsOf, A + 10); ctx.stroke();
        ctx.setLineDash([]);
        txt(ctx, "1:55 PM", xAsOf, A - 28, { size: 9.5, mono: true, weight: "600", align: "center", color: P.past });
      }

      // ── the throwaway copy (recovery lane, or the as-of read) ──
      const T = 232, tw = 236, th = 56;
      const tx = Math.min(xB2 - 27, S.w - pad - tw);
      const showThrow = recovering || (asOf && deployed);
      if (showThrow) {
        const alpha = recovering ? Math.min(1, r / 0.25) : 1;
        ctx.save(); ctx.globalAlpha = alpha;
        // copy-down arrow from the anchoring base backup
        arrow(ctx, xB2, A - 14, tx + 60, T - 4, P.past, 1.6, [4, 4]);
        txt(ctx, "copy the base backup", xB2 + 34, (A + T) / 2 + 2, { size: 9.5, mono: true, color: P.past });
        box(ctx, tx, T, tw, th, 8, P.pastBg, P.pastLn, 1.5);
        txt(ctx, "throwaway Postgres", tx + 12, T + 20, { size: 11, weight: "700", color: P.past });
        const p = recovering ? Math.max(0, Math.min(1, (r - 0.3) / 0.5)) : 1;
        const target = recovering ? "replay WAL → just before the DROP" : "replay WAL → 1:55 PM";
        txt(ctx, recovering && p < 1 ? "replaying WAL…" : target, tx + 12, T + 38, { size: 9.5, mono: true, color: P.past });
        ctx.restore();
      }
      // extraction back into live
      if (r > 0.8) {
        ctx.save(); ctx.globalAlpha = Math.min(1, (r - 0.8) / 0.15);
        arrow(ctx, tx + tw, T + th / 2, db.x + db.w / 2, db.y + db.h + 6, P.ok, 1.8);
        txt(ctx, "extract → restore into live", tx + tw - 2, T - 8, { size: 9.5, mono: true, weight: "600", align: "right", color: P.ok });
        ctx.restore();
      }

      // ── read head ──
      const rhY = 306;
      box(ctx, pad, rhY, S.w - pad * 2, 28, 8, asOf ? P.pastBg : P.soft, asOf ? P.pastLn : P.line, 1);
      txt(ctx, asOf ? "SELECT * FROM parts_cost   (as of 1:55 PM, answered by the throwaway copy)" : "SELECT * FROM parts_cost   (live)",
        pad + 12, rhY + 14, { size: 11, mono: true, weight: "600", baseline: "middle", color: asOf ? P.past : P.ink2 });

      note(root, !deployed
        ? "The sidecar takes <b>pg_basebackup base backups</b> on a cadence while the engine archives WAL continuously. Plain directories, no special filesystem. At 2:00 PM a deploy is about to <code>DROP</code> a table."
        : recovering && !recovered
        ? "Recovery never touches the live database. Copy the newest base backup from <em>before</em> the drop (1:40 PM), stand a throwaway Postgres on it, and <b>replay archived WAL</b> forward to one instant before the drop's recorded position."
        : recovered
        ? "<b>parts_cost is back</b>, extracted from the throwaway copy and restored into live, <em>including writes made after the 1:40 backup</em>. The backup is only a base and WAL replay covers the rest. Then the copy is torn down. Minutes, not milliseconds: the price of running unprivileged, anywhere."
        : asOf
        ? "First, a look at the past. Reading <b>as-of 1:55 PM</b> materializes the newest backup at or before that moment and replays WAL up to it. A running Postgres frozen at 1:55, queried, then thrown away. The live database is never restored over."
        : "The 2 PM deploy dropped <code>parts_cost</code>. The heap is gone and no row image covers a <code>DROP</code>. But the archive holds every write, and <code>eter.ddl_log</code> recorded the drop's exact WAL position, so eterDB knows how far to replay.");
    }
    S.resize();
    loopWhenVisible(root, S);
  }

  /* ════════════════════════════════════════════════════════════════════
     FIGURE 8, Read overhead vs concurrency: first pass vs backend-local.
     A static line chart of observe-mode marginal read overhead (vs the same
     patched binary with observe off) as client concurrency climbs. The first
     pass (muted, dashed) reused a shared SERIALIZABLEXACT and rose 27%→53%,
     the cost was the commit-time teardown on one global lock, not the reads
     (profiling: lock acquisition 0.2%). Backend-local capture (amber) drops
     the shared transaction entirely and is flat ~2-3%. Measured confound-free
     (test/observe-read-scaling.sh: one warm cluster, interleaved on/off
     PGOPTIONS toggle + reversed-order control), M1 Pro / PG18.4 / -O2.
     ════════════════════════════════════════════════════════════════════ */
  function figScaling(root) {
    const S = stage(root, 320, render);
    S.minW = 660; S.hotIdx = -1;
    const clients = [16, 32, 64, 100];
    const readsOld = [27, 36, 48, 53];     // first pass: shared SERIALIZABLEXACT, commit-teardown-bound, rises
    const readsNew = [2.2, 1.7, 3.5, 3.3]; // backend-local capture (issue #154), flat; test/observe-read-scaling.sh
    const YMAX = 60;

    S.onmove = (s) => {
      // nearest client column to the cursor
      let best = -1, bd = 1e9;
      for (let i = 0; i < clients.length; i++) {
        const dx = Math.abs(s.mx - s._x[i]);
        if (dx < bd) { bd = dx; best = i; }
      }
      s.hotIdx = bd < 60 ? best : -1;
    };
    S.onleave = (s) => { s.hotIdx = -1; };

    function render(ctx, S) {
      ctx.clearRect(0, 0, S.w, S.h);
      const padL = 30, padR = 140, padT = 30, padB = 48;
      const plotW = S.w - padL - padR, plotH = S.h - padT - padB;
      const X = (i) => padL + plotW * (i / (clients.length - 1));
      const Y = (v) => padT + plotH * (1 - v / YMAX);
      S._x = clients.map((_, i) => X(i));

      // recessive y-grid + labels (0/20/40/60%)
      for (let g = 0; g <= YMAX; g += 20) {
        const y = Y(g);
        box(ctx, padL, y, plotW, 0, 0, null, g === 0 ? P.line2 : P.line, 1);
        txt(ctx, g + (g === YMAX ? "%" : ""), padL - 8, y, { size: 9.5, mono: true, align: "right", baseline: "middle", color: P.faint });
      }
      // hovered column highlight
      if (S.hotIdx >= 0) {
        const hx = X(S.hotIdx);
        box(ctx, hx - 0.5, padT, 0, plotH, 0, null, P.line2, 1);
      }
      // x ticks + axis title
      clients.forEach((c, i) => {
        txt(ctx, String(c), X(i), padT + plotH + 16, { size: 10, mono: true, align: "center", baseline: "middle", color: S.hotIdx === i ? P.ink : P.mut });
      });
      txt(ctx, "concurrent clients →", padL + plotW / 2, padT + plotH + 36, { size: 9.5, align: "center", baseline: "middle", color: P.faint });
      txt(ctx, "marginal overhead vs stock", padL, padT - 14, { size: 9.5, weight: "600", baseline: "middle", color: P.faint });

      // series line + markers
      function series(vals, color, dashed) {
        ctx.save();
        ctx.strokeStyle = color; ctx.lineWidth = 2; ctx.lineJoin = "round";
        if (dashed) ctx.setLineDash([2, 4]);
        ctx.beginPath();
        let started = false;
        vals.forEach((v, i) => { if (v == null) return; const x = X(i), y = Y(v); if (!started) { ctx.moveTo(x, y); started = true; } else ctx.lineTo(x, y); });
        ctx.stroke(); ctx.restore();
        vals.forEach((v, i) => {
          if (v == null) return;
          const x = X(i), y = Y(v), r = S.hotIdx === i ? 6 : 4.5;
          ctx.beginPath(); ctx.arc(x, y, r + 1.5, 0, Math.PI * 2); ctx.fillStyle = P.card; ctx.fill();
          ctx.beginPath(); ctx.arc(x, y, r, 0, Math.PI * 2); ctx.fillStyle = color; ctx.fill();
        });
      }
      series(readsOld, P.mut, true);   // first pass: rising, dashed + recessive (the "before")
      series(readsNew, P.warn, false); // backend-local: flat, the emphasis line (the "after")

      // direct end-labels (identity is carried by the line's own color)
      txt(ctx, "first pass", X(3) + 12, Y(readsOld[3]), { size: 11, weight: "700", baseline: "middle", color: P.mut });
      txt(ctx, "shared-SSI teardown", X(3) + 12, Y(readsOld[3]) + 14, { size: 8.5, mono: true, baseline: "middle", color: P.faint });
      txt(ctx, "backend-local", X(3) + 12, Y(readsNew[3]) - 7, { size: 11, weight: "700", baseline: "middle", color: P.warn });
      txt(ctx, "flat ~2-3%", X(3) + 12, Y(readsNew[3]) + 8, { size: 8.5, mono: true, baseline: "middle", color: P.faint });

      if (S.hotIdx >= 0) {
        const i = S.hotIdx;
        note(root, "<b>At " + clients[i] + " clients:</b> first pass <b style='color:" + P.mut + "'>" + readsOld[i] + "%</b> → backend-local <b style='color:" + P.warn + "'>" + readsNew[i] + "%</b>. The first design registered a shared serializable transaction and paid a commit-time teardown on one global lock, which contends harder as concurrency rises. Backend-local capture removes the shared transaction, so there's nothing left to contend on.");
      } else {
        note(root, "Observe-mode read overhead vs the same binary with observe off, as concurrency rises. The <b style='color:" + P.mut + "'>first pass</b> reused Postgres SSI, a shared serializable transaction per query, and climbed 27% → 53%. The cost was the commit-time teardown on one global lock, not the reads themselves: profiling put lock acquisition at 0.2%. <b style='color:" + P.warn + "'>Backend-local</b> capture drops the shared transaction and stays flat at ~2-3%. Measured confound-free, with an interleaved on/off toggle on one warm cluster and a reversed-order control. Hover a client count for exact figures.");
      }
    }
    S.resize();
    onView(root, () => S.draw());
  }

  /* ── Mount ── */
  const FIGS = { basics: figBasics, mvcc: figMvcc, ctid: figCtid, wal: figWal, arch: figArch, reads: figReads, graph: figGraph, pitr: figPitr, scaling: figScaling };
  document.querySelectorAll(".fig").forEach((root) => {
    const f = FIGS[root.dataset.fig];
    if (f) { try { f(root); } catch (e) { /* a broken figure must never take the page down */ console.error("fig", root.dataset.fig, e); } }
  });

  /* ── Footer year + active-section nav highlight ── */
  const yr = document.getElementById("year");
  if (yr) yr.textContent = new Date().getFullYear();

  const links = Array.from(document.querySelectorAll(".docnav-links a"));
  const map = new Map(links.map((a) => [a.getAttribute("href").slice(1), a]));
  if ("IntersectionObserver" in window && links.length) {
    const spy = new IntersectionObserver((es) => {
      es.forEach((e) => {
        const a = map.get(e.target.id);
        if (a && e.isIntersecting) { links.forEach((l) => l.classList.remove("active")); a.classList.add("active"); }
      });
    }, { rootMargin: "-40% 0px -55% 0px" });
    document.querySelectorAll(".doc-section[id]").forEach((s) => spy.observe(s));
  }
})();
