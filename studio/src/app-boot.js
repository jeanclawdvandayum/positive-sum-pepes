/* PSP Trait Studio — boot: binds modules, global keyboard shortcuts,
 * kicks off PSP.init(). Load this file LAST. */
(function () {
'use strict';

const PSP = window.PSPApp;

function typing(e) {
  const t = e.target;
  return t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' || t.tagName === 'SELECT' || t.isContentEditable);
}

document.addEventListener('keydown', (e) => {
  if (typing(e) || PSP.modalOpen()) return;
  const UI = PSP.ui();
  if (!UI) return;

  // undo / redo work on trait axes even mid-typing? no — guarded above.
  const mod = e.metaKey || e.ctrlKey;
  if (mod && e.key.toLowerCase() === 'z') {
    e.preventDefault();
    if (e.shiftKey) PSP.redo(); else PSP.undo();
    return;
  }
  if (mod && e.key.toLowerCase() === 'y') { e.preventDefault(); PSP.redo(); return; }
  if (mod) return;

  if (UI.axis === 'palettes') return; // editor shortcuts live on trait tabs
  if (!PSP.currentTrait()) return;    // NONE selected — nothing to paint
  if (PSP.Canvas.onKey(e)) e.preventDefault();
});

PSP.Panels.bind();
PSP.Dialogs.bind();
PSP.Canvas.bind();
PSP.init();
PSP.Canvas.syncToolbar();

})();
