'use strict';

/*
 * Shared browser-side helpers. Loaded on every page via partials/head.ejs.
 *
 * Modals in this app were previously opened by adding a class and closed by
 * removing it — no dialog semantics, no focus trap, no Escape, no overlay
 * click, and focus left stranded behind the scrim. Everything that opens a
 * modal now goes through openModal()/closeModal() so that behaviour lives in
 * exactly one place.
 */

var FOCUSABLE = [
  'a[href]',
  'button:not([disabled])',
  'input:not([disabled]):not([type="hidden"])',
  'select:not([disabled])',
  'textarea:not([disabled])',
  '[tabindex]:not([tabindex="-1"])'
].join(',');

var openModalId = null;
var lastFocused = null;

function focusableWithin(el) {
  return Array.prototype.filter.call(
    el.querySelectorAll(FOCUSABLE),
    function (node) { return node.offsetParent !== null || node === document.activeElement; }
  );
}

function openModal(id) {
  var overlay = document.getElementById(id);
  if (!overlay) return;

  lastFocused = document.activeElement;
  openModalId = id;
  overlay.classList.add('modal-open');

  var targets = focusableWithin(overlay);
  if (targets.length) targets[0].focus();
}

function closeModal(id) {
  var overlay = document.getElementById(id || openModalId);
  if (!overlay) return;

  overlay.classList.remove('modal-open');
  openModalId = null;

  // Return focus to whatever opened the dialog, so a keyboard user isn't
  // dumped back at the top of the document.
  if (lastFocused && typeof lastFocused.focus === 'function') lastFocused.focus();
  lastFocused = null;
}

document.addEventListener('keydown', function (e) {
  if (!openModalId) return;

  if (e.key === 'Escape') {
    e.preventDefault();
    closeModal(openModalId);
    return;
  }

  if (e.key !== 'Tab') return;

  // Cycle focus inside the dialog rather than letting Tab walk out into the
  // page behind the scrim.
  var overlay = document.getElementById(openModalId);
  if (!overlay) return;
  var targets = focusableWithin(overlay);
  if (!targets.length) return;

  var first = targets[0];
  var last = targets[targets.length - 1];

  if (e.shiftKey && document.activeElement === first) {
    e.preventDefault();
    last.focus();
  } else if (!e.shiftKey && document.activeElement === last) {
    e.preventDefault();
    first.focus();
  }
});

// Click on the scrim (but not inside the card) dismisses.
document.addEventListener('click', function (e) {
  if (!openModalId) return;
  var overlay = document.getElementById(openModalId);
  if (overlay && e.target === overlay) closeModal(openModalId);
});

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, function (c) {
    return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
  });
}

// navigator.clipboard is unavailable on insecure origins and, in some
// browsers, when the page uses an untrusted self-signed certificate — which
// is exactly this app's situation. Fall back to a hidden textarea.
function copyText(text, onDone) {
  function fallback() {
    var ta = document.createElement('textarea');
    ta.value = text;
    ta.setAttribute('readonly', '');
    ta.style.position = 'fixed';
    ta.style.left = '-9999px';
    document.body.appendChild(ta);
    ta.select();
    var ok = false;
    try { ok = document.execCommand('copy'); } catch (err) { ok = false; }
    document.body.removeChild(ta);
    if (onDone) onDone(ok);
  }

  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(text).then(
      function () { if (onDone) onDone(true); },
      fallback
    );
  } else {
    fallback();
  }
}

// A run has finished — re-enable the topbar links that were server-rendered
// as locked while it was in flight.
function unlockTopbarNav() {
  Array.prototype.forEach.call(document.querySelectorAll('.topbar .is-disabled'), function (el) {
    el.classList.remove('is-disabled');
    el.removeAttribute('aria-disabled');
  });
  var note = document.getElementById('topbar-lock-note');
  if (note) note.remove();
}
