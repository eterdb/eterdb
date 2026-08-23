/* eterDB, global header: logo spin + burger menu. Shared by every page.
   The star counts are the official GitHub Buttons widget, which fetches its own. */

/* ── Logo spin: jet-engine spin-up on load, and again on hover ──
   Defined here (not main.js) so the header behaves the same on every page,
   including /tech which loads tech.js instead of main.js. */
(() => {
  "use strict";
  const reduce = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  if (reduce) return;
  const spin = (m) => { m.classList.remove("spin"); void m.offsetWidth; m.classList.add("spin"); };
  document.querySelectorAll(".brand-mark").forEach((m) => {
    m.addEventListener("animationend", () => m.classList.remove("spin"));
    const hoverTarget = m.closest(".brand, .footer-brand") || m;
    hoverTarget.addEventListener("mouseenter", () => spin(m));
    spin(m);
  });
})();

/* ── Mobile burger menu ──
   Toggles the nav dropdown on small viewports. Desktop never sees the burger
   (CSS hides it), so this is inert there. Closes on link tap, Escape, or an
   outside click, and keeps aria-expanded in sync for screen readers. */
(() => {
  "use strict";
  const burger = document.getElementById("nav-burger");
  const nav = document.getElementById("site-nav");
  if (!burger || !nav) return;

  const setOpen = (open) => {
    nav.classList.toggle("open", open);
    burger.setAttribute("aria-expanded", String(open));
  };
  const isOpen = () => nav.classList.contains("open");

  burger.addEventListener("click", (e) => { e.stopPropagation(); setOpen(!isOpen()); });
  /* Any nav choice collapses the menu. */
  nav.addEventListener("click", (e) => { if (e.target.closest("a, button")) setOpen(false); });
  document.addEventListener("keydown", (e) => { if (e.key === "Escape" && isOpen()) setOpen(false); });
  document.addEventListener("click", (e) => {
    if (isOpen() && !nav.contains(e.target) && !burger.contains(e.target)) setOpen(false);
  });
})();
