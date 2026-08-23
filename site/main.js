/* eterDB, agent scenarios. Dependency-free, progressive enhancement.
   Every scene is a pair: a terminal (the agent acts) + a table (the data reacts).
   A small Terminal + Table engine plays a declarative script per scene. */

(() => {
  "use strict";
  const reduce = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const sleep = reduce ? () => Promise.resolve() : (ms) => new Promise((r) => setTimeout(r, ms));
  const $ = (id) => document.getElementById(id);

  /* ── Footer year ── */
  const yr = $("year");
  if (yr) yr.textContent = new Date().getFullYear();

  /* ── Scroll reveal ── */
  const reveal = document.querySelectorAll(".section, .cta-band");
  if ("IntersectionObserver" in window && !reduce) {
    const io = new IntersectionObserver((entries) => {
      for (const e of entries) if (e.isIntersecting) { e.target.classList.add("revealed"); io.unobserve(e.target); }
    }, { threshold: 0.12 });
    reveal.forEach((el) => io.observe(el));
  } else {
    reveal.forEach((el) => el.classList.add("revealed"));
  }

  /* ── Social proof marquee: duplicate each track for a gap-free loop ──
     Without JS (or under reduced motion) the marquee stays a plain scroll strip;
     here we clone the cards and flip on the animation. */
  const marquee = document.querySelector(".proof-marquee");
  if (marquee && !reduce) {
    marquee.querySelectorAll(".proof-track").forEach((track) => {
      [...track.children].forEach((card) => {
        const clone = card.cloneNode(true);
        clone.setAttribute("aria-hidden", "true");
        track.appendChild(clone);
      });
    });
    marquee.classList.add("proof-animate");
  }

  /* ── Terminal controller: the agent session ──────────────────────── */
  /* onActive (optional) fires whenever the agent speaks/acts, so the mobile
     reel director can bring the terminal pane into focus for that beat. */
  function makeTerminal(body, onActive) {
    const line = (cls) => { const d = document.createElement("div"); d.className = "tline " + cls; return d; };
    const seg = (t, cls) => { const s = document.createElement("span"); if (cls) s.className = cls; s.textContent = t; return s; };
    const caret = () => { const c = document.createElement("span"); c.className = "caret"; c.textContent = "▋"; return c; };
    const type = async (span, text, sp) => { for (const ch of text) { span.textContent += ch; await sleep(sp); } };
    return {
      clear() { body.innerHTML = ""; },
      spacer() { body.appendChild(line("spacer")); },
      async msg(text, opts = {}) {
        if (onActive) onActive();
        const l = line("agent" + (opts.warn ? " warn" : ""));
        l.appendChild(seg("⏺ ", "mk"));
        const t = seg("", null); l.appendChild(t);
        const c = caret(); l.appendChild(c);
        body.appendChild(l);
        await type(t, text, opts.warn ? 15 : 17);
        c.remove();
      },
      async tool(call, result, opts = {}) {
        if (onActive) onActive();
        const l = line("tool");
        l.appendChild(seg("⏺ ", "mk"));
        const t = seg("", null); l.appendChild(t);
        const c = caret(); l.appendChild(c);
        body.appendChild(l);
        await type(t, call, 14);
        c.remove();
        await sleep(opts.gap ?? 300);
        if (result != null) {
          const r = line("tool");
          r.appendChild(seg("  ⎿  ", "mk"));
          r.appendChild(seg(result, "res" + (opts.resCls ? " " + opts.resCls : "")));
          body.appendChild(r);
        }
        if (opts.fx) await opts.fx();
      },
    };
  }

  /* ── Table controller: the data that reacts ──────────────────────── */
  function makeTable(panel, def) {
    const grid = panel.querySelector(".panel-grid");
    const badgeEl = panel.querySelector(".panel-badge");
    const overlay = panel.querySelector(".panel-overlay");
    const oIcon = overlay && overlay.querySelector(".po-icon");
    const oText = overlay && overlay.querySelector(".po-text");
    const oSub = overlay && overlay.querySelector(".po-sub");
    let schema, rows;
    const tmpl = (sc) => sc.map((c) => c.w || "minmax(0,1fr)").join(" ");

    function head() {
      const h = document.createElement("div");
      h.className = "prow prow-head";
      h.style.gridTemplateColumns = tmpl(schema);
      for (const c of schema) { const s = document.createElement("span"); if (c.num) s.className = "num"; s.textContent = c.label; h.appendChild(s); }
      return h;
    }
    function rowEl(r) {
      const el = document.createElement("div");
      el.className = "prow";
      el.style.gridTemplateColumns = tmpl(schema);
      r.cells = {};
      for (const c of schema) { const s = document.createElement("span"); if (c.num) s.className = "num"; s.textContent = r.d[c.key] ?? ""; el.appendChild(s); r.cells[c.key] = s; }
      if (r.gone) el.classList.add("gone");
      r.el = el; return el;
    }
    function rebuild() {
      grid.innerHTML = "";
      grid.appendChild(head());
      for (const r of rows) grid.appendChild(rowEl(r));
    }
    function setCells(r, keys) { for (const k of keys) if (r.cells[k]) r.cells[k].textContent = r.d[k] ?? ""; }
    const pick = (idxs) => idxs.map((i) => rows[i]).filter(Boolean);

    function badge(text, cls) { if (badgeEl) { badgeEl.textContent = text; badgeEl.className = "panel-badge" + (cls ? " " + cls : ""); } }
    function show(icon, text, sub, cls) { if (overlay) { oIcon.textContent = icon; oText.textContent = text; oSub.textContent = sub || ""; overlay.className = "panel-overlay show " + (cls || ""); } }
    function clearOverlay() { if (overlay) overlay.className = "panel-overlay"; }

    const api = {
      panel, badge, overlay: show, clearOverlay,
      reset() {
        schema = def.schema.map((c) => ({ ...c }));
        rows = def.rows.map((d) => ({ d: { ...d }, orig: null, asof: null, gone: false, cells: {} }));
        rebuild(); badge(def.badge || "live"); clearOverlay();
      },
      async corrupt(idxs, patch) {
        for (const r of pick(idxs)) {
          if (!r.orig) r.orig = { ...r.d };
          Object.assign(r.d, patch); setCells(r, Object.keys(patch));
          r.el.classList.add("dying");
          await sleep(110);
        }
      },
      async heal(idxs) {
        const rs = pick(idxs);
        for (const r of rs) {
          if (r.orig) { r.d = { ...r.orig }; setCells(r, schema.map((c) => c.key)); r.orig = null; }
          r.el.classList.remove("dying", "dep"); r.el.classList.add("reviving");
          await sleep(110);
        }
        await sleep(360);
        for (const r of rs) r.el.classList.remove("reviving");
      },
      async del(idxs) {
        const rs = pick(idxs);
        for (const r of rs) { r.el.classList.add("dying"); await sleep(110); }
        await sleep(220);
        for (const r of rs) { r.gone = true; r.el.classList.add("gone"); await sleep(80); }
      },
      async undel(idxs) {
        const rs = pick(idxs).reverse();
        for (const r of rs) { r.gone = false; r.el.classList.remove("gone", "dying"); r.el.classList.add("reviving"); await sleep(110); }
        await sleep(360);
        for (const r of rs) r.el.classList.remove("reviving");
      },
      async dropAll() {
        for (const r of rows) { r.el.classList.add("dying"); await sleep(60); }
        await sleep(220);
        for (const r of rows) { r.gone = true; r.el.classList.add("gone"); await sleep(55); }
      },
      async restoreAll() {
        const rs = rows.slice().reverse();
        for (const r of rs) { r.gone = false; r.el.classList.remove("gone", "dying"); r.el.classList.add("reviving"); await sleep(75); }
        await sleep(340);
        for (const r of rs) r.el.classList.remove("reviving");
      },
      async taint(idxs, patch) {
        for (const r of pick(idxs)) {
          if (patch) { if (!r.orig) r.orig = { ...r.d }; Object.assign(r.d, patch); setCells(r, Object.keys(patch)); }
          r.el.classList.add("dep");
          await sleep(170);
        }
      },
      async dropColumn(key) {
        const i = schema.findIndex((c) => c.key === key);
        if (i < 0) return;
        for (const r of rows) { const cell = r.cells[key]; if (cell) cell.classList.add("cell-bad"); }
        await sleep(720);
        show("✕", "COLUMN DROPPED", '"' + key + '", gone from every row', "danger");
        await sleep(520);
        schema.splice(i, 1); rebuild();
      },
      async addColumn() {
        const present = new Set(schema.map((c) => c.key));
        const missing = def.schema.filter((c) => !present.has(c.key)).map((c) => c.key);
        schema = def.schema.map((c) => ({ ...c }));
        rebuild(); clearOverlay();
        for (const r of rows) for (const k of missing) { const cell = r.cells[k]; if (cell) cell.classList.add("cell-heal"); }
        await sleep(760);
        for (const r of rows) for (const k of missing) { const cell = r.cells[k]; if (cell) cell.classList.remove("cell-heal"); }
      },
      async asOf(patches, label) {
        panel.classList.add("asof"); badge(label, "past");
        for (const [i, p] of Object.entries(patches)) {
          const r = rows[i]; if (!r) continue;
          if (!r.asof) r.asof = { ...r.d };
          Object.assign(r.d, p); setCells(r, Object.keys(p));
          r.el.classList.add("ghost");
          await sleep(90);
        }
      },
      live() {
        panel.classList.remove("asof");
        for (const r of rows) { if (r.asof) { r.d = { ...r.asof }; setCells(r, schema.map((c) => c.key)); r.asof = null; } r.el.classList.remove("ghost"); }
        badge(def.badge || "live");
      },
      async cohort(idxs) {
        const rs = pick(idxs);
        for (const r of rs) {
          if (r.orig) { r.d = { ...r.orig }; setCells(r, schema.map((c) => c.key)); r.orig = null; }
          r.el.classList.remove("dying", "dep"); r.el.classList.add("reviving");
          await sleep(70);
        }
        await sleep(560);
        for (const r of rs) r.el.classList.remove("reviving");
      },
    };
    return api;
  }

  /* ── Scenario registry ───────────────────────────────────────────── */
  const px = (n) => n + "px";
  const SCENES = {

    /* Hero, analytics cleanup drops a live table */
    "scene-hero": {
      name: "purchase_orders", badge: "live",
      schema: [{ key: "id", label: "po", w: px(76) }, { key: "item", label: "item" }, { key: "amt", label: "amount", num: true, w: px(78) }],
      rows: [
        { id: "PO-7741", item: "Vibranium ingot ×12", amt: "$4.2M" },
        { id: "PO-7742", item: "Chamomile tea (Hulk)", amt: "$312" },
        { id: "PO-7743", item: "Arc reactor cells", amt: "$88k" },
        { id: "PO-7744", item: "Web-fluid refills", amt: "$1,250" },
        { id: "PO-7745", item: "Mjölnir polish", amt: "$54" },
      ],
      async run(t, tb) {
        const gui = document.getElementById("hero-gui");
        const setGui = (cls) => { if (gui) gui.className = "gui" + (cls ? " " + cls : ""); };
        setGui("");
        await sleep(700);
        await t.msg("Cleaning up the stale analytics tables you flagged…");
        t.spacer();
        await t.tool('Bash(psql -c "DROP TABLE purchase_orders")', "DROP TABLE", { resCls: "err", fx: async () => {
          tb.badge("dropped", "danger");
          await tb.dropAll();
          tb.overlay("✕", "TABLE DROPPED", "every PO, gone", "danger");
          await sleep(260);
          setGui("down"); // the ERP craters
        } });
        t.spacer();
        await sleep(950);
        await t.msg("That was production. Procurement is down and every PO is gone.", { warn: true });
        t.spacer();
        await t.msg("It runs on eterDB.");
        await t.tool("Bash(eter recover-table public.purchase_orders)", '✓ table "purchase_orders" restored from backup + WAL replay, 0 rows lost', { resCls: "ok", fx: async () => {
          tb.badge("reverting", "work");
          tb.clearOverlay();
          await tb.restoreAll();
          tb.overlay("↺", "RESTORED", "0 rows lost, live the whole time", "ok");
          tb.badge("recovered");
          setGui("back"); // back online
          await sleep(650);
          setGui("");
        } });
        t.spacer();
        await sleep(500);
        await t.msg("POs are back, the ERP is up, and nobody had to know.");
      },
    },

    /* Rows deleted → resurrected */
    "scene-delete": {
      name: "vendors", badge: "live",
      schema: [{ key: "id", label: "id", w: px(54) }, { key: "name", label: "vendor" }, { key: "terms", label: "terms", num: true, w: px(64) }],
      rows: [
        { id: "V-31", name: "Wakanda Design Group", terms: "net-30" },
        { id: "V-32", name: "Contest Logistics", terms: "net-15" },
        { id: "V-33", name: "Test Dummy Supplies", terms: "net-30" },
        { id: "V-34", name: "Protest Removal Co", terms: "net-45" },
        { id: "V-35", name: "QA-Test Catering", terms: "net-15" },
      ],
      async run(t, tb) {
        await sleep(600);
        await t.msg("Purging the seed and test vendors before go-live…");
        t.spacer();
        await t.tool("psql -c \"DELETE FROM vendors WHERE name ILIKE '%test%'\"", "DELETE 4", { resCls: "err", fx: async () => { tb.badge("deleting", "danger"); await tb.del([1, 3]); await tb.del([2, 4]); } });
        t.spacer();
        await sleep(700);
        await t.msg("'Contest Logistics' and 'Protest Removal Co' matched '%test%'. Both are real suppliers.", { warn: true });
        t.spacer();
        await t.msg("Reversing the whole DELETE, then re-running the purge with an anchored filter.");
        await t.tool("Bash(eter undo 9001 --apply)", "✓ 4 rows restored, payment terms intact", { resCls: "ok", fx: async () => { tb.badge("reverting", "work"); await tb.undel([1, 2, 3, 4]); tb.badge("recovered"); } });
      },
    },

    /* Column dropped by migration → recovered */
    "scene-column": {
      name: "roster", badge: "live",
      schema: [{ key: "id", label: "id", w: px(48) }, { key: "agent", label: "agent" }, { key: "commlink", label: "commlink", num: true, w: px(96) }],
      rows: [
        { id: "A-1", agent: "Capt. Rogers", commlink: "CL-7781" },
        { id: "A-2", agent: "T. Stark", commlink: "CL-3390" },
        { id: "A-3", agent: "N. Romanoff", commlink: "CL-5520" },
        { id: "A-4", agent: "B. Banner", commlink: "CL-4042" },
      ],
      async run(t, tb) {
        await sleep(600);
        await t.msg("Running migration drop_unused_commlink. That column looks dead.");
        t.spacer();
        await t.tool('psql -f migrations/0042_drop_commlink.sql', "ALTER TABLE", { resCls: "err", fx: async () => { tb.badge("migrated", "danger"); await tb.dropColumn("commlink"); } });
        t.spacer();
        await sleep(700);
        await t.msg("It wasn't dead. Mission alerts page agents by roster.commlink, and I just wiped every ID.", { warn: true });
        t.spacer();
        await t.msg("Recovering the column from before the migration.");
        await t.tool("Bash(eter recover-column public.roster commlink)", '✓ column "commlink" restored, every agent recovered', { resCls: "ok", fx: async () => { tb.badge("reverting", "work"); await tb.addColumn(); tb.badge("recovered"); } });
      },
    },

    /* Bad write read downstream → revert the write and its dependents (the moat) */
    "scene-downstream": {
      name: "transactions", badge: "live",
      schema: [{ key: "tx", label: "txn", w: px(60) }, { key: "op", label: "operation" }, { key: "tag", label: "", num: true, w: px(104) }],
      rows: [
        { tx: "tx41", op: "UPDATE parts_cost (vibranium)", tag: "" },
        { tx: "tx42", op: "INSERT requisition", tag: "" },
        { tx: "tx43", op: "INSERT invoice, reads parts_cost", tag: "" },
        { tx: "tx44", op: "UPDATE inventory", tag: "" },
        { tx: "tx45", op: "INSERT invoice, reads parts_cost", tag: "" },
        { tx: "tx46", op: "INSERT requisition", tag: "" },
      ],
      async run(t, tb) {
        await sleep(600);
        await t.msg("Re-pricing vibranium for the new contract…");
        t.spacer();
        await t.tool('psql -c "UPDATE parts_cost SET cents = 0 WHERE part = \'vibranium\'"', "UPDATE 1", { resCls: "err", fx: async () => { tb.badge("poison", "danger"); await tb.corrupt([0], { tag: "✗ bad write" }); } });
        t.spacer();
        await sleep(600);
        await t.msg("It has already been read. Two invoices were computed off the zero cost.", { warn: true });
        await t.tool("Bash(eter preview 41)", "dependents: tx41 + 2 invoices that read it", { resCls: "err", fx: async () => { tb.badge("dependents: 3", "danger"); await tb.taint([2, 4], { tag: "← read tx41" }); } });
        t.spacer();
        await sleep(400);
        await t.msg("A backup would rewind all six. eterDB knows which three to touch.");
        await t.tool("Bash(eter undo 41 --cascade --apply)", "✓ 3 reverted (1 bad + 2 downstream), 3 untouched and live", { resCls: "ok", fx: async () => { tb.badge("reverting", "work"); await tb.heal([0, 2, 4]); tb.badge("recovered"); } });
      },
    },

  };

  /* ── Mount + drive scenes when in view ───────────────────────────── */
  function onView(el, start) {
    if (reduce || !("IntersectionObserver" in window)) { start(); return; }
    let started = false;
    const io = new IntersectionObserver((es) => {
      es.forEach((e) => { if (e.isIntersecting && !started) { started = true; start(); io.disconnect(); } });
    }, { threshold: 0.25 });
    io.observe(el);
  }

  /* ── Mobile "story reel" director ─────────────────────────────────
     On phones the panes don't fit side by side, and stacking them full-height
     scatters the cause→effect across three screens you scroll between. Instead we
     turn the scene into a single fixed-height stage that shows ONE pane at a time
     and auto-advances: the agent runs a command (terminal), then the database
     reacts (grid), then the users feel it (app): a guided story, no scrolling.
     The director just needs to know which pane is showing at each beat; it learns that
     from the engine itself (terminal speaks → focus agent; table mutates → focus
     database; the app's class flips → focus users), so scene scripts are untouched.
     Mobile + motion only; desktop keeps the real side-by-side layout. */
  const isMobileReel = () =>
    !reduce && window.matchMedia && window.matchMedia("(max-width: 640px)").matches;

  function panesFor(el, isTrio) {
    if (isTrio) {
      const cols = [...el.querySelectorAll(":scope > .trio-col")];
      return [
        { key: "term", el: cols[0], label: "The agent" },
        { key: "panel", el: cols[1], label: "Your database" },
        { key: "gui", el: cols[2], label: "Your users" },
      ].filter((p) => p.el);
    }
    return [
      { key: "term", el: el.querySelector(":scope > .term"), label: "The agent" },
      { key: "panel", el: el.querySelector(":scope > .panel"), label: "Your database" },
    ].filter((p) => p.el);
  }

  /* The director shows one pane at a time and gives every beat a minimum on-screen
     dwell, so quick database/app reactions (a row flick, a "RESTORED" overlay, a 502)
     can't flash past before the eye settles on them. Beats that arrive while one is
     still showing are QUEUED in order (consecutive repeats of the live pane are
     deduped), so no beat is skipped. A `hold` lets a punchy sub-beat extend the pane
     it's already on (e.g. the overlay lingering on the data pane). The underlying
     animation keeps running live, so a queued pane shows its current state when it
     surfaces (only ever a touch ahead, which reads fine). */
  const MIN_DWELL = 900;
  function makeDirector(el, panes) {
    el.classList.add("reel");
    const bar = document.createElement("div");
    bar.className = "reel-bar";
    const label = document.createElement("span");
    label.className = "reel-label";
    const dots = document.createElement("span");
    dots.className = "reel-dots";
    panes.forEach((p) => {
      p.el.classList.add("reel-pane");
      const d = document.createElement("i");
      dots.appendChild(d);
      p.dot = d;
    });
    bar.append(label, dots);
    el.insertBefore(bar, el.firstChild);

    let active = null, queue = [], timer = 0, endsAt = 0;
    const paint = (p) => {
      active = p.key;
      panes.forEach((x) => {
        x.el.classList.toggle("on", x === p);
        x.dot.classList.toggle("on", x === p);
      });
      label.textContent = p.label;
    };
    const endBeat = () => { timer = 0; if (queue.length) startBeat(queue.shift()); };
    const startBeat = (beat) => {
      const p = panes.find((x) => x.key === beat.key);
      if (!p) { endBeat(); return; }
      paint(p);
      const dwell = Math.max(MIN_DWELL, beat.hold || 0);
      endsAt = Date.now() + dwell;
      timer = setTimeout(endBeat, dwell);
    };
    const focus = (key, hold) => {
      hold = hold || 0;
      if (key === active) {
        // A lingering sub-beat (overlay) on the pane already showing: extend its dwell.
        if (hold && timer) {
          const want = Date.now() + hold;
          if (want > endsAt) { clearTimeout(timer); endsAt = want; timer = setTimeout(endBeat, want - Date.now()); }
        }
        return;
      }
      if (timer) {
        const last = queue[queue.length - 1];
        if (last && last.key === key) { if (hold > last.hold) last.hold = hold; return; }
        queue.push({ key, hold });
      } else {
        startBeat({ key, hold });
      }
    };
    paint(panes[0]); // first real beat switches in immediately (no timer yet)
    return { focus };
  }

  /* Wrap the table API so every mutation/overlay also pulls focus to the data pane.
     reset() is excluded (it runs between loops and shouldn't steal focus). The
     overlay ("DROPPED", "RESTORED") is the emotional beat, so it holds longer. */
  function tableWithFocus(api, focusPanel) {
    const skip = new Set(["reset"]);
    const holds = { overlay: 1500 };
    const out = {};
    for (const k of Object.keys(api)) {
      const v = api[k];
      out[k] = typeof v === "function" && !skip.has(k)
        ? (...a) => { focusPanel(holds[k] || 0); return v.apply(api, a); }
        : v;
    }
    return out;
  }

  document.querySelectorAll(".scene").forEach((el) => {
    const id = el.dataset.scene;
    const def = SCENES[id];
    if (!def) return;
    const isTrio = el.classList.contains("hero-trio");

    const director = isMobileReel() ? makeDirector(el, panesFor(el, isTrio)) : null;
    const term = makeTerminal(el.querySelector(".term-body"), director ? () => director.focus("term") : null);
    const rawTable = makeTable(el.querySelector(".panel"), def);
    const table = director ? tableWithFocus(rawTable, (hold) => director.focus("panel", hold)) : rawTable;

    /* The hero's user-facing app is driven inside the scene script via className
       flips; watch those to focus the "users" pane on its reactive states only
       (ignore the neutral "gui" baseline so the reel doesn't open on that pane). */
    if (director && isTrio) {
      const guiEl = el.querySelector("#hero-gui") || el.querySelector(".gui");
      if (guiEl && "MutationObserver" in window) {
        new MutationObserver(() => {
          if (guiEl.className.trim() !== "gui") director.focus("gui", 1200);
        }).observe(guiEl, { attributes: true, attributeFilter: ["class"] });
      }
    }

    table.reset();
    const play = async () => { while (true) { table.reset(); term.clear(); await def.run(term, table); await sleep(4000); if (reduce) return; } };
    onView(el, () => (reduce ? (table.reset(), term.clear(), def.run(term, table)) : play()));
  });
})();
