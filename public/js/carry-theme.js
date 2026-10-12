/**
 * Light / dark mode. Sets <html data-theme="light"> from localStorage ("carry-theme"); dark is the default.
 * Any element with [data-theme-toggle] flips it. The bundle replaces <html> when it unpacks, so the attribute is
 * re-applied whenever the document root changes. Colors live in css/theme.css.
 */
(function () {
  'use strict';

  const KEY = 'carry-theme';
  const saved = () => { try { return localStorage.getItem(KEY) === 'light' ? 'light' : 'dark'; } catch (e) { return 'dark'; } };
  const current = () => (document.documentElement.getAttribute('data-theme') === 'light' ? 'light' : 'dark');

  function apply(t) {
    const root = document.documentElement;
    if (t === 'light') root.setAttribute('data-theme', 'light'); else root.removeAttribute('data-theme');
    document.querySelectorAll('[data-theme-toggle]').forEach((b) => {
      b.setAttribute('aria-pressed', t === 'light' ? 'true' : 'false');
      b.title = t === 'light' ? 'Switch to dark mode' : 'Switch to light mode';
    });
  }

  apply(saved());

  document.addEventListener('click', (e) => {
    const b = e.target.closest && e.target.closest('[data-theme-toggle]');
    if (!b) return;
    const t = current() === 'light' ? 'dark' : 'light';
    try { localStorage.setItem(KEY, t); } catch (err) {}
    apply(t);
  });

  // Re-apply after the bundle swaps the root element, and label toggles as they mount.
  new MutationObserver(() => {
    if (current() !== saved() || document.querySelector('[data-theme-toggle]:not([aria-pressed])')) apply(saved());
  }).observe(document, { childList: true, subtree: true });
})();
