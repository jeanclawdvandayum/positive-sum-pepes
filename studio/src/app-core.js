/* PSP Trait Studio — core: helpers, state, persistence, undo, trait ops,
 * validation, pub/sub, modal system, DNA codec, compose, self-test.
 * Plain browser JS (works from file:// and static servers). No deps. */
(function () {
'use strict';

const PSP = window.PSPApp = {};

/* ── constants ─────────────────────────────────────────── */
PSP.GOLDEN_SHA =
  '73fff0a5d6c0b59cd29cd396eedc6ac09ba679858a844049bfa2a30facc8d364';
PSP.SIZE = 69;
PSP.AXES = ['head', 'expressions', 'eyes', 'hats', 'eyewear', 'items'];
PSP.HEAD_AXIS = 'head';   // single BASE trait, NOT a DNA axis
PSP.STAMP_AXES = { hats: true, eyewear: true, items: true };
PSP.SLOT_NAMES = {
  0: 'transparent', 1: 'outline (unused)', 2: 'base skin', 3: 'light skin',
  4: 'dark skin', 5: 'eye white', 6: 'pupil / iris', 7: 'lips rose',
  8: 'lips dark', 9: 'accent red', 10: 'nostril', 11: 'gold',
  12: 'gold dark', 13: 'cookie', 14: 'shades black', 15: 'background',
  16: 'skin bright', 17: 'skin deep', 18: 'skin glint',
  19: 'skin mid-shadow', 20: 'steel light', 21: 'steel dark',
  22: 'cream', 23: 'umber',
};
PSP.FIXED_COMMENTS = {
  5: 'eye white', 6: 'pupil slate (iris 0 default)', 7: 'lips rose',
  8: 'mouth dark', 9: 'accent red (cap / ember)', 11: 'gold',
  12: 'gold dark', 13: 'cookie gold', 14: 'shades black',
};
const LS_KEY = 'psp-trait-studio-v1';
const UNDO_MAX = 150;

/* ── tiny DOM helpers ──────────────────────────────────── */
const $ = (id) => document.getElementById(id);
PSP.$ = $;
PSP.el = function (tag, attrs, html) {
  const n = document.createElement(tag);
  if (attrs) for (const k of Object.keys(attrs)) n.setAttribute(k, attrs[k]);
  if (html != null) n.innerHTML = html;
  return n;
};
const clone = (o) => JSON.parse(JSON.stringify(o));
PSP.clone = clone;

/* ── pub/sub ───────────────────────────────────────────── */
const subs = {};
PSP.on = function (name, fn) { (subs[name] = subs[name] || []).push(fn); };
PSP.emit = function (name) {
  const args = Array.prototype.slice.call(arguments, 1);
  (subs[name] || []).forEach((fn) => { try { fn.apply(null, args); } catch (e) { console.error(e); } });
};

/* ── grids ─────────────────────────────────────────────── */
PSP.emptyGrid = function () {
  const g = [];
  const N = PSP.SIZE;
  for (let y = 0; y < N; y++) { const r = new Array(N); for (let x = 0; x < N; x++) r[x] = 0; g.push(r); }
  return g;
};
PSP.gridEmpty = function (g) {
  for (let y = 0; y < PSP.SIZE; y++) for (let x = 0; x < PSP.SIZE; x++) if (g[y][x]) return false;
  return true;
};
PSP.cloneGrid = (g) => g.map((r) => r.slice());

/* ── state ─────────────────────────────────────────────── */
let uidSeq = 1;
let S = null;                 // persisted art state
let UI = null;                // session UI state (partially persisted)
let undoMap = new Map();      // trait object -> {u:[], r:[]}
let vmsgs = [];               // validation messages
let lastExportSnap = '';
let saveTimer = null;
let shiftLogSeq = 1;

function makeTrait(name, grid) {
  return { name: name, grid: grid, _uid: uidSeq++ };
}

function defaultsArt() {
  const d = window.PSP_DEFAULTS;
  const art = { palettes: clone(d.palettes), axes: {} };
  for (const a of PSP.AXES) art.axes[a] = d.axes[a].map((t) => makeTrait(t.name, clone(t.grid)));
  return art;
}
PSP.headGrid = function () {
  const h = S && S.axes.head && S.axes.head[0];
  return h ? h.grid : window.PSP_DEFAULTS.axes.head[0].grid;
};

PSP.state = () => S;
PSP.ui = () => UI;
PSP.undoMap = () => undoMap;

function freshUI() {
  return {
    axis: 'expressions',
    sel: { head: 0, expressions: 0, eyes: 0, hats: 0, eyewear: 0, items: 0 }, // index in array; stamps: -1 = NONE row
    preview: { expr: 0, eyes: 0, hat: 0, wear: 0, item: 0, skin: 0, iris: 0, bg: 0, scale: 4 },
    editor: { tool: 'pencil', prevTool: 'pencil', mirror: false, grid: true, ghost: true,
              ghostAlpha: 0.4, bg: 'checker', cell: 16, armed: 2 },
    palettesEdited: false,
  };
}

PSP.resetAll = function () {
  S = defaultsArt();
  UI = freshUI();
  undoMap = new Map();
  vmsgs = [];
  shiftLogSeq = 1;
  persistNow();
  lastExportSnap = artSnap();
  PSP.emit('render');
  PSP.emit('undochange');
};

/* ── persistence ───────────────────────────────────────── */
function artSnap() {
  // v2: the head lives in axes.head (its grid is the SPRITE_BASE source)
  const o = { v: 2, palettes: S.palettes, palettesEdited: UI.palettesEdited,
    axes: {} };
  for (const a of PSP.AXES) o.axes[a] = S.axes[a].map((t) => ({ name: t.name, grid: t.grid }));
  return JSON.stringify(o);
}
PSP.artSnap = artSnap;

function fullSave() {
  const o = JSON.parse(artSnap());
  o.ui = { preview: UI.preview, editor: { tool: UI.editor.tool, mirror: UI.editor.mirror,
    grid: UI.editor.grid, ghost: UI.editor.ghost, ghostAlpha: UI.editor.ghostAlpha,
    bg: UI.editor.bg, cell: UI.editor.cell, armed: UI.editor.armed } };
  return o;
}

PSP.persistSoon = function () {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(persistNow, 500);
};
function persistNow() {
  clearTimeout(saveTimer);
  try {
    localStorage.setItem(LS_KEY, JSON.stringify(fullSave()));
    const t = new Date();
    const pad = (n) => (n < 10 ? '0' : '') + n;
    const note = $('autosave-note');
    if (note) note.textContent = 'autosaved ' + pad(t.getHours()) + ':' + pad(t.getMinutes()) + ':' + pad(t.getSeconds());
  } catch (e) { /* storage unavailable (private mode etc.) — session still works */ }
}
PSP.persistNow = persistNow;
PSP.loadSaved = function () {
  try {
    const raw = localStorage.getItem(LS_KEY);
    if (!raw) return null;
    const o = JSON.parse(raw);
    if (!o || !o.axes || !o.palettes) return null;
    if (o.v === 1) {
      // v1 kept the head as a separate baseGrid key — fold it into axes.head
      if (!o.baseGrid) return null;
      o.axes.head = [{ name: 'BASE', grid: o.baseGrid }];
      delete o.baseGrid;
    } else if (o.v !== 2) return null;
    for (const a of PSP.AXES) {
      if (!Array.isArray(o.axes[a])) return null;
    }
    if (!o.axes.head.length || o.axes.head[0].name !== 'BASE') return null;
    return o;
  } catch (e) { return null; }
};
PSP.applySaved = function (o) {
  S = { palettes: o.palettes, axes: {} };
  for (const a of PSP.AXES) S.axes[a] = o.axes[a].map((t) => makeTrait(t.name, t.grid));
  UI = freshUI();
  UI.palettesEdited = !!o.palettesEdited;
  if (o.ui) {
    if (o.ui.preview) Object.assign(UI.preview, o.ui.preview);
    if (o.ui.editor) Object.assign(UI.editor, o.ui.editor);
  }
  clampUI();
  undoMap = new Map();
  lastExportSnap = artSnap();
  PSP.emit('render');
  PSP.emit('undochange');
};
PSP.forgetSave = function () { try { localStorage.removeItem(LS_KEY); } catch (e) {} };

function clampUI() {
  const c = PSP.counts();
  const P = UI.preview;
  P.expr = Math.min(P.expr, c.expressions - 1);
  P.eyes = Math.min(P.eyes, c.eyes - 1);
  P.hat = Math.min(P.hat, c.hats - 1);
  P.wear = Math.min(P.wear, c.eyewear - 1);
  P.item = Math.min(P.item, c.items - 1);
  P.skin = Math.min(P.skin, S.palettes.skins.length - 1);
  P.iris = Math.min(P.iris, S.palettes.irises.length - 1);
  P.bg = Math.min(P.bg, S.palettes.backgrounds.length - 1);
  for (const a of PSP.AXES) {
    const n = S.axes[a].length;
    UI.sel[a] = Math.min(UI.sel[a], n - 1);
    if (UI.sel[a] === 0 && PSP.STAMP_AXES[a]) { /* id 0 is NONE — keep 0 = first stored */ }
  }
}

PSP.markChanged = function (opts) {
  opts = opts || {};
  revalidate();
  PSP.persistSoon();
  if (!opts.noDirtyCheck) updateDirty();
  if (!opts.noRender) PSP.emit('render');
};
function updateDirty() {
  const dot = $('dirty-dot');
  if (!dot) return;
  const dirty = artSnap() !== lastExportSnap;
  dot.classList.toggle('dirty', dirty);
  dot.title = dirty ? 'unsaved changes since last export' : 'state matches last export';
}
PSP.snapshotExported = function () { lastExportSnap = artSnap(); updateDirty(); };
PSP.isDirtySinceExport = () => artSnap() !== lastExportSnap;

/* ── undo / redo (per-trait, grid snapshots) ───────────── */
function stacksFor(trait) {
  let st = undoMap.get(trait);
  if (!st) { st = { u: [], r: [] }; undoMap.set(trait, st); }
  return st;
}
PSP.pushUndo = function (trait, gridSnap) {
  const st = stacksFor(trait);
  st.u.push(gridSnap);
  if (st.u.length > UNDO_MAX) st.u.splice(0, st.u.length - UNDO_MAX);
  st.r.length = 0;
  PSP.emit('undochange');
};
PSP.canUndo = function () { const t = PSP.currentTrait(); return !!t && stacksFor(t).u.length > 0; };
PSP.canRedo = function () { const t = PSP.currentTrait(); return !!t && stacksFor(t).r.length > 0; };
PSP.undo = function () {
  const t = PSP.currentTrait();
  if (!t) return false;
  const st = stacksFor(t);
  if (!st.u.length) return false;
  st.r.push(PSP.cloneGrid(t.grid));
  t.grid = st.u.pop();
  PSP.markChanged();
  PSP.emit('undochange');
  return true;
};
PSP.redo = function () {
  const t = PSP.currentTrait();
  if (!t) return false;
  const st = stacksFor(t);
  if (!st.r.length) return false;
  st.u.push(PSP.cloneGrid(t.grid));
  t.grid = st.r.pop();
  PSP.markChanged();
  PSP.emit('undochange');
  return true;
};

/* ── trait management ──────────────────────────────────── */
PSP.currentAxis = () => UI.axis;
PSP.currentTraits = () => (PSP.AXES.indexOf(UI.axis) >= 0 ? S.axes[UI.axis] : null);
PSP.currentTrait = function () {
  const arr = PSP.currentTraits();
  if (!arr) return null;
  const i = UI.sel[UI.axis];
  return i >= 0 && i < arr.length ? arr[i] : null;
};
PSP.counts = function () {
  const c = {};
  for (const a of PSP.AXES) {
    const n = S.axes[a].length;
    c[a] = PSP.STAMP_AXES[a] ? n + 1 : n; // DNA counts include implicit NONE
  }
  delete c.head; // the head is not a DNA axis — no combo multiplier
  return c;
};

PSP.setAxis = function (axis) {
  UI.axis = axis;
  PSP.emit('render');
};

function uniqueName(axis, base) {
  const names = new Set(S.axes[axis].map((t) => t.name));
  let n = base, k = 1;
  while (names.has(n)) n = base + (++k);
  return n;
}
PSP.uniqueName = uniqueName;

PSP.isValidTraitName = function (axis, name, self) {
  if (!/^[A-Za-z][A-Za-z0-9_]{0,31}$/.test(name)) return 'letters/digits/_ only, must start with a letter (max 32)';
  if (name === 'NONE' && PSP.STAMP_AXES[axis]) return 'NONE is reserved for implicit id 0';
  for (const t of S.axes[axis]) if (t !== self && t.name === name) return 'name already used on this axis';
  return null;
};

PSP.addTrait = function (axis, name, grid) {
  if (axis === PSP.HEAD_AXIS) return null;   // exactly one head, ever
  const t = makeTrait(name || uniqueName(axis, 'NEW'), grid || PSP.emptyGrid());
  S.axes[axis].push(t);
  UI.sel[axis] = S.axes[axis].length - 1;
  PSP.markChanged();
  return t;
};
PSP.duplicateTrait = function () {
  const src = PSP.currentTrait();
  if (!src) return null;
  const t = makeTrait(uniqueName(UI.axis, src.name + '_COPY'), PSP.cloneGrid(src.grid));
  S.axes[UI.axis].push(t);
  UI.sel[UI.axis] = S.axes[UI.axis].length - 1;
  PSP.markChanged();
  return t;
};
PSP.renameTrait = function (trait, name) {
  trait.name = name;
  PSP.markChanged();
};
PSP.deleteTraitIdx = function (axis, idx) {
  const arr = S.axes[axis];
  const t = arr[idx];
  undoMap.delete(t);
  arr.splice(idx, 1);
  if (UI.sel[axis] >= arr.length) UI.sel[axis] = arr.length - 1;
  syncPreviewToSel(axis);
  PSP.markChanged();
};
PSP.moveTraitIdx = function (axis, idx, dir) {
  const arr = S.axes[axis];
  const j = idx + dir;
  if (j < 0 || j >= arr.length) return;
  const tmp = arr[idx]; arr[idx] = arr[j]; arr[j] = tmp;
  UI.sel[axis] = j;
  PSP.markChanged();
};

/* DNA-shift question: does mutating index idx move anyone else's id? */
PSP.shiftsDNA = (axis, idx) => idx !== S.axes[axis].length - 1;
PSP.orderList = function (axis, removedIdx) {
  // returns trait-name list after a hypothetical delete at removedIdx (or null = current)
  const arr = S.axes[axis].slice();
  if (removedIdx != null) arr.splice(removedIdx, 1);
  return arr.map((t, i) => ({ name: t.name, id: PSP.STAMP_AXES[axis] ? i + 1 : i }));
};

PSP.logDNAShift = function (text) {
  vmsgs = vmsgs.filter((m) => m.kind !== 'shift' || !m.stale);
  vmsgs.push({ sev: 'info', kind: 'shift', dismissible: true, key: 'shift' + (shiftLogSeq++) + '_' + Date.now(), text: text });
  PSP.emit('validation');
};

/* selection <-> preview ids */
PSP.selectTrait = function (axis, idx) {
  UI.sel[axis] = idx;
  syncPreviewToSel(axis);
  PSP.emit('render');
  PSP.emit('undochange');
};
function syncPreviewToSel(axis) {
  const i = UI.sel[axis];
  if (axis === 'expressions') UI.preview.expr = Math.max(0, i);
  else if (axis === 'eyes') UI.preview.eyes = Math.max(0, i);
  else if (axis === 'hats') UI.preview.hat = i < 0 ? 0 : i + 1;
  else if (axis === 'eyewear') UI.preview.wear = i < 0 ? 0 : i + 1;
  else if (axis === 'items') UI.preview.item = i < 0 ? 0 : i + 1;
}
PSP.syncSelToPreview = function () { // after RANDOM / restore: highlight rows
  const P = UI.preview;
  UI.sel.expressions = P.expr;
  UI.sel.eyes = P.eyes;
  UI.sel.hats = P.hat === 0 ? 0 : P.hat - 1;
  UI.sel.eyewear = P.wear === 0 ? 0 : P.wear - 1;
  UI.sel.items = P.item === 0 ? 0 : P.item - 1;
};

/* ── palette resolution / compose / DNA ────────────────── */
PSP.resolvePal = function () {
  const P = UI.preview;
  const nS = S.palettes.skins.length, nI = S.palettes.irises.length, nB = S.palettes.backgrounds.length;
  return window.PSPCompiler.resolvePalette(S.palettes,
    Math.min(P.skin, nS - 1), Math.min(P.iris, nI - 1), Math.min(P.bg, nB - 1));
};

PSP.compose = function (ids) {
  const g = PSP.cloneGrid(S.axes.head[0].grid);
  const ov = (src) => { for (let y = 0; y < PSP.SIZE; y++) for (let x = 0; x < PSP.SIZE; x++) if (src[y][x]) g[y][x] = src[y][x]; };
  // expressions + eyes are ALWAYS drawn (DNA 0-based, index 0 = a real trait,
  // e.g. NEUTRAL overlays its lips onto the base) — matches PepeDescriptor
  // _layers() which stamps expr(t.expr)/eye(t.eyes) unconditionally.
  const flat = (axis, id) => { const a = S.axes[axis][id]; if (a) ov(a.grid); };
  flat('expressions', ids.expr);
  flat('eyes', ids.eyes);
  const stamp = (axis, id) => { if (id > 0) ov(S.axes[axis][id - 1].grid); };
  stamp('hats', ids.hat); stamp('eyewear', ids.wear); stamp('items', ids.item);
  return g;
};

PSP.packDNA = function (ids) {
  // layout matches PepeDescriptor.sol: expr 3b | eyes 4b | hat 4b | wear 4b |
  // item 4b | skin 3b | iris 3b | bg 4b  (eyes widened 3b -> 4b for 9 traits)
  return (ids.expr | (ids.eyes << 3) | (ids.hat << 7) | (ids.wear << 11) |
          (ids.item << 15) | (ids.skin << 19) | (ids.iris << 22) | (ids.bg << 25)) >>> 0;
};

PSP.armSlot = function (slot) {
  UI.editor.armed = slot;
  PSP.emit('render');
};

/* ── validation ────────────────────────────────────────── */
PSP.addVMsg = function (sev, text, opts) {
  opts = opts || {};
  vmsgs = vmsgs.filter((m) => m.key !== opts.key);
  vmsgs.push({ sev: sev, text: text, dismissible: !!opts.dismissible, key: opts.key || ('dyn' + Date.now() + Math.random()) });
  PSP.emit('validation');
};
PSP.dismissVMsg = function (key) {
  vmsgs = vmsgs.filter((m) => m.key !== key);
  PSP.emit('validation');
};
PSP.vmsgs = () => vmsgs;

function revalidate() {
  const keep = vmsgs.filter((m) => m.kind === 'shift'); // session log entries survive
  const list = keep;
  for (const axis of PSP.AXES) {
    const seen = new Set();
    for (const t of S.axes[axis]) {
      if (seen.has(t.name)) list.push({ sev: 'error', dismissible: false, key: 'dup:' + axis + ':' + t.name,
        text: axis + ': duplicate trait name "' + t.name + '"' });
      seen.add(t.name);
      if (PSP.gridEmpty(t.grid)) list.push({ sev: 'error', dismissible: false, key: 'empty:' + axis + ':' + t.name,
        text: axis + ' "' + t.name + '": grid is empty — compile would fail (stampBytes throws)' });
      if (axis === 'expressions' || axis === 'head') {
        let teeth = 0;
        for (let y = 39; y < 52; y++) for (let x = 19; x <= 61; x++) if (t.grid[y][x] === 5) teeth++;
        if (teeth) list.push({ sev: 'warn', dismissible: false, key: 'teeth:' + axis + ':' + t.name,
          text: 'frogs have no teeth: ' + axis + ' "' + t.name + '" has ' + teeth + ' eye-white px in the mouth zone (rows ≥39, cols 19–61)' });
      }
    }
  }
  vmsgs = list;
  PSP.emit('validation');
}
PSP.revalidate = revalidate;

/* ── sha256 (Web Crypto + pure-JS fallback for odd contexts) ── */
const shaTab = [];
(function () {
  let k = 0;
  for (let i = 0; i < 64; i++) { k = i < 16 ? i + 1 : shaTab[i - 2] ^ shaTab[i - 7] ^ shaTab[i - 15] ^ shaTab[i - 16]; shaTab.push(k >>> 0); }
})();
function sha256Bytes(bytes) {
  const H = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
  const l = bytes.length;
  const bitLen = l * 8;
  const data = bytes.slice();
  data.push(0x80);
  while (data.length % 64 !== 56) data.push(0);
  for (let i = 7; i >= 0; i--) data.push((bitLen / Math.pow(2, i * 8)) & 0xff);
  const w = new Array(64);
  const rr = (x, n) => (x >>> n) | (x << (32 - n));
  for (let off = 0; off < data.length; off += 64) {
    for (let i = 0; i < 16; i++) w[i] = (data[off + i * 4] << 24) | (data[off + i * 4 + 1] << 16) | (data[off + i * 4 + 2] << 8) | data[off + i * 4 + 3];
    for (let i = 16; i < 64; i++) {
      const s0 = rr(w[i - 15], 7) ^ rr(w[i - 15], 18) ^ (w[i - 15] >>> 3);
      const s1 = rr(w[i - 2], 17) ^ rr(w[i - 2], 19) ^ (w[i - 2] >>> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) >>> 0;
    }
    let [a, b, c, d, e, f, g, h] = H;
    for (let i = 0; i < 64; i++) {
      const S1 = rr(e, 6) ^ rr(e, 11) ^ rr(e, 25);
      const ch = (e & f) ^ (~e & g);
      const t1 = (h + S1 + ch + shaTab[i] + w[i]) >>> 0;
      const S0 = rr(a, 2) ^ rr(a, 13) ^ rr(a, 22);
      const mj = (a & b) ^ (a & c) ^ (b & c);
      const t2 = (S0 + mj) >>> 0;
      h = g; g = f; f = e; e = (d + t1) >>> 0; d = c; c = b; b = a; a = (t1 + t2) >>> 0;
    }
    H[0] = (H[0] + a) >>> 0; H[1] = (H[1] + b) >>> 0; H[2] = (H[2] + c) >>> 0; H[3] = (H[3] + d) >>> 0;
    H[4] = (H[4] + e) >>> 0; H[5] = (H[5] + f) >>> 0; H[6] = (H[6] + g) >>> 0; H[7] = (H[7] + h) >>> 0;
  }
  const out = [];
  for (const v of H) out.push((v >>> 24) & 255, (v >>> 16) & 255, (v >>> 8) & 255, v & 255);
  return out;
}
function hex(out) { let s = ''; for (const b of out) s += (b < 16 ? '0' : '') + b.toString(16); return s; }
PSP.sha256Hex = async function (text) {
  const bytes = new TextEncoder().encode(text);
  if (window.crypto && crypto.subtle && crypto.subtle.digest) {
    try {
      const buf = await crypto.subtle.digest('SHA-256', bytes);
      return hex(new Uint8Array(buf));
    } catch (e) { /* fall through */ }
  }
  return hex(sha256Bytes(bytes));
};

/* ── self-test: embedded defaults must compile to the golden .sol ── */
PSP.selfTest = async function () {
  try {
    const sol = window.PSPCompiler.compileSolidity(window.PSP_DEFAULTS);
    const sha = await PSP.sha256Hex(sol);
    const pass = sha === PSP.GOLDEN_SHA;
    return { pass: pass, sha: sha };
  } catch (e) {
    return { pass: false, sha: null, error: String(e && e.message || e) };
  }
};
window.__pspSelfTest = function () { return PSP.selfTest(); };

/* ── modal system ──────────────────────────────────────── */
let openModals = 0;
PSP.openModal = function (opts) {
  const root = $('modal-root');
  root.classList.remove('hidden');
  root.innerHTML = '';
  const m = PSP.el('div', { class: 'modal' + (opts.wide ? ' wide' : ''), role: 'dialog' });
  const head = PSP.el('div', { class: 'modal-head' });
  head.appendChild(PSP.el('span', null, opts.title || ''));
  const x = PSP.el('button', { class: 'x', title: 'Close' }, '✕');
  head.appendChild(x);
  const body = PSP.el('div', { class: 'modal-body' });
  if (typeof opts.body === 'string') body.innerHTML = opts.body;
  else if (opts.body) body.appendChild(opts.body);
  m.appendChild(head); m.appendChild(body);
  let closed = false;
  function close(val) {
    if (closed) return; closed = true;
    root.classList.add('hidden'); root.innerHTML = '';
    openModals--;
    document.removeEventListener('keydown', onKey, true);
    if (opts.onClose) opts.onClose(val);
  }
  const foot = PSP.el('div', { class: 'modal-foot' });
  (opts.buttons || []).forEach((b) => {
    const btn = PSP.el('button', b.class ? { class: b.class } : null, b.label);
    btn.addEventListener('click', () => {
      if (b.onClick) { const r = b.onClick(close, body); if (r === false) return; if (r !== undefined) close(r); }
      else close();
    });
    foot.appendChild(btn);
  });
  if (foot.childNodes.length) m.appendChild(foot);
  function onKey(e) {
    if (e.key === 'Escape') { e.stopPropagation(); close(null); }
    if (e.key === 'Enter' && opts.enterButton !== false && !e.shiftKey && e.target.tagName !== 'TEXTAREA' && e.target.tagName !== 'BUTTON') {
      const def = (opts.buttons || []).find((b) => b.default);
      if (def) { e.preventDefault(); def.onClick ? (def.onClick(close, body) === false ? null : close()) : close(); }
    }
  }
  x.addEventListener('click', () => close(null));
  if (!opts.noBackdrop) root.addEventListener('click', function onBg(e) { if (e.target === root) { close(null); root.removeEventListener('click', onBg); } });
  root.appendChild(m);
  document.addEventListener('keydown', onKey, true);
  openModals++;
  const first = body.querySelector('input, select, textarea, button');
  if (first && opts.focus !== false) setTimeout(() => first.focus(), 0);
  return close;
};
PSP.modalOpen = () => openModals > 0;

PSP.confirmModal = function (opts) {
  return new Promise((res) => {
    let settled = false;
    const done = (v) => { if (!settled) { settled = true; res(v); } };
    PSP.openModal({
      title: opts.title || 'Confirm',
      body: opts.html || '',
      onClose: done,
      buttons: [
        { label: opts.okLabel || 'OK', class: opts.danger ? 'danger' : 'accent', default: true, onClick: (close) => close(true) },
        { label: 'Cancel', onClick: (close) => close(false) },
      ],
    });
  });
};
PSP.promptModal = function (opts) {
  return new Promise((res) => {
    let settled = false;
    const done = (v) => { if (!settled) { settled = true; res(v); } };
    const body = PSP.el('div');
    body.innerHTML = '<p class="sub">' + (opts.label || '') + '</p>';
    const wrap = PSP.el('p');
    const inp = PSP.el('input', { type: 'text', value: opts.value || '', spellcheck: 'false' });
    inp.style.width = '100%';
    wrap.appendChild(inp); body.appendChild(wrap);
    const err = PSP.el('p', { class: 'sub' }); err.style.color = 'var(--err)'; err.style.minHeight = '1em';
    body.appendChild(err);
    inp.addEventListener('input', () => { inp.classList.remove('err-input'); err.textContent = ''; });
    PSP.openModal({
      title: opts.title || 'Rename',
      body: body,
      onClose: done,
      buttons: [
        { label: opts.okLabel || 'OK', class: 'accent', default: true, onClick: (close) => {
          const v = inp.value.trim();
          const bad = opts.validate ? opts.validate(v) : null;
          if (bad) { inp.classList.add('err-input'); err.textContent = bad; return false; }
          close(v);
        } },
        { label: 'Cancel', onClick: (close) => close(null) },
      ],
    });
    setTimeout(() => { inp.focus(); inp.select(); }, 0);
  });
};
PSP.chooseModal = function (opts) {
  return new Promise((res) => {
    let settled = false;
    const done = (v) => { if (!settled) { settled = true; res(v); } };
    PSP.openModal({ title: opts.title || 'Choose', body: opts.html || '', onClose: () => done(null),
      buttons: (opts.choices || []).map((c) => ({ label: c.label, class: c.class, onClick: (close) => close(c.value) })) });
  });
};

/* ── downloads ─────────────────────────────────────────── */
PSP.download = function (filename, dataUrl) {
  const a = PSP.el('a', { href: dataUrl, download: filename });
  document.body.appendChild(a);
  a.click();
  setTimeout(() => a.remove(), 500);
};
PSP.downloadText = function (filename, text, mime) {
  PSP.download(filename, 'data:' + (mime || 'text/plain') + ';charset=utf-8,' + encodeURIComponent(text));
};

/* ── boot (wires top bar; called by app-boot.js after all modules) ── */
PSP.init = function () {
  S = defaultsArt();
  UI = freshUI();
  lastExportSnap = artSnap();
  PSP.syncSelToPreview();

  document.querySelectorAll('#tabs .tab').forEach((b) => {
    b.addEventListener('click', () => PSP.setAxis(b.getAttribute('data-axis')));
  });
  $('btn-menu').addEventListener('click', (e) => { e.stopPropagation(); $('menu').classList.toggle('hidden'); });
  document.addEventListener('click', (e) => {
    const mw = $('menu-wrap');
    if (!mw.classList.contains('hidden') && !mw.contains(e.target)) $('menu').classList.add('hidden');
  });
  $('btn-selftest').addEventListener('click', runSelfTestBadge);
  PSP.emit('ready');
  PSP.emit('render');
  runSelfTestBadge(); // auto-run once on load
  const saved = PSP.loadSaved();
  if (saved) PSP.emit('found-save', saved);
};

async function runSelfTestBadge() {
  const badge = $('selftest-badge');
  badge.textContent = 'self-test …';
  badge.className = 'mono';
  const r = await PSP.selfTest();
  if (r.pass) { badge.textContent = '✓ self-test passed'; badge.className = 'mono pass'; }
  else { badge.textContent = '✗ self-test FAILED' + (r.error ? ' — ' + r.error : ''); badge.className = 'mono fail'; }
  return r;
}
PSP.runSelfTestBadge = runSelfTestBadge;

})();
