/* PSP 420 edition — collection inspector.
 * Renders the embedded 420 art (window.PSP_DEFAULTS) and the original
 * release-2 art (window.PSP_ORIGINAL) with the studio's own path:
 * PSPCompiler.resolvePalette + the same layer order as PSPApp.compose
 * (head, expression, eyes, hat, eyewear, item) + the same per-pixel fill as
 * the studio preview. Plain browser JS, works from file://. */
(function () {
'use strict';

const C = window.PSPCompiler;
const NEW = window.PSP_DEFAULTS;
const OLD = window.PSP_ORIGINAL;
const N = C.SIZE;
const AXES = ['expressions', 'eyes', 'hats', 'eyewear', 'items'];
const STAMP = { hats: true, eyewear: true, items: true };
const KEY = { expressions: 'expr', eyes: 'eyes', hats: 'hat', eyewear: 'wear', items: 'item' };
const $ = (id) => document.getElementById(id);

function el(tag, cls, html) {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  if (html != null) n.innerHTML = html;
  return n;
}

/* identical to PSPApp.compose: expr/eyes always drawn, stamps id 0 = NONE */
function compose(art, ids) {
  const g = art.axes.head[0].grid.map((r) => r.slice());
  const ov = (src) => { for (let y = 0; y < N; y++) for (let x = 0; x < N; x++) if (src[y][x]) g[y][x] = src[y][x]; };
  const flat = (axis, id) => { const a = art.axes[axis][id]; if (a) ov(a.grid); };
  flat('expressions', ids.expr);
  flat('eyes', ids.eyes);
  const stamp = (axis, id) => { if (id > 0) { const a = art.axes[axis][id - 1]; if (a) ov(a.grid); } };
  stamp('hats', ids.hat); stamp('eyewear', ids.wear); stamp('items', ids.item);
  return g;
}

function palFor(art, p) {
  const P = art.palettes;
  return C.resolvePalette(P, Math.min(p.skin, P.skins.length - 1),
    Math.min(p.iris, P.irises.length - 1), Math.min(p.bg, P.backgrounds.length - 1));
}

/* same fill loop as the studio's renderPreview */
function draw(art, ids, scale) {
  const pal = palFor(art, ids);
  const grid = compose(art, ids);
  const cvs = document.createElement('canvas');
  const px = N * scale;
  cvs.width = px; cvs.height = px;
  const c = cvs.getContext('2d');
  const bgc = pal[15];
  c.fillStyle = 'rgb(' + bgc[0] + ',' + bgc[1] + ',' + bgc[2] + ')';
  c.fillRect(0, 0, px, px);
  for (let y = 0; y < N; y++) for (let x = 0; x < N; x++) {
    const v = grid[y][x];
    if (!v) continue;
    const rgb = pal[v];
    c.fillStyle = 'rgb(' + rgb[0] + ',' + rgb[1] + ',' + rgb[2] + ')';
    c.fillRect(x * scale, y * scale, scale, scale);
  }
  return cvs;
}

const view = { skin: 0, iris: 0, bg: 0, scale: 3 };
function baseIds() { return { expr: 0, eyes: 0, hat: 0, wear: 0, item: 0, skin: view.skin, iris: view.iris, bg: view.bg }; }
function idsFor(axis, dnaId) { const ids = baseIds(); ids[KEY[axis]] = dnaId; return ids; }
const dnaOf = (axis, i) => (STAMP[axis] ? i + 1 : i);

function gridsEqual(a, b) {
  for (let y = 0; y < N; y++) for (let x = 0; x < N; x++) if (a[y][x] !== b[y][x]) return false;
  return true;
}
/* status of 420 trait i vs the original at the same DNA slot */
function status(axis, i) {
  const o = OLD.axes[axis][i];
  const t = NEW.axes[axis][i];
  if (!o) return 'new';
  if (o.name !== t.name) return 'renamed';
  return gridsEqual(o.grid, t.grid) ? '' : 'changed';
}
function tag(st, o) {
  if (!st) return '';
  const txt = st === 'renamed' ? 'was ' + o.name : st;
  return '<span class="tag ' + st + '">' + txt + '</span>';
}

function renderTraits() {
  const body = $('traits-body');
  body.innerHTML = '';
  for (const axis of AXES) {
    body.appendChild(el('h3', null, axis.toUpperCase() + ' · ' + NEW.axes[axis].length + ' traits'
      + (STAMP[axis] ? ' + NONE' : '') + ' · ' + (NEW.axes[axis].length + (STAMP[axis] ? 1 : 0)) + '/16 DNA ids'));
    const grid = el('div', 'grid');
    NEW.axes[axis].forEach((t, i) => {
      const card = el('div', 'card');
      card.appendChild(draw(NEW, idsFor(axis, dnaOf(axis, i)), view.scale));
      card.appendChild(el('div', 'lbl', '<span class="id">#' + dnaOf(axis, i) + '</span> ' + t.name
        + tag(status(axis, i), OLD.axes[axis][i])));
      grid.appendChild(card);
    });
    body.appendChild(grid);
  }
}

function renderChanges() {
  const body = $('changes-body');
  body.innerHTML = '';
  const sc = Math.max(view.scale, 3);
  let total = 0;
  for (const axis of AXES) {
    const rows = [];
    NEW.axes[axis].forEach((t, i) => { const st = status(axis, i); if (st) rows.push([i, st]); });
    if (!rows.length) continue;
    total += rows.length;
    body.appendChild(el('h3', null, axis.toUpperCase() + ' · ' + rows.length + ' changed/added'));
    const grid = el('div', 'grid');
    for (const [i, st] of rows) {
      const o = OLD.axes[axis][i];
      const t = NEW.axes[axis][i];
      const card = el('div', 'card');
      const pair = el('div', 'pair');
      const left = el('div', 'side');
      if (o) left.appendChild(draw(OLD, idsFor(axis, dnaOf(axis, i)), sc));
      else { const nb = el('div', 'none-box', 'not in<br>original'); nb.style.width = nb.style.height = (N * sc) + 'px'; left.appendChild(nb); }
      left.appendChild(el('div', 'cap', 'ORIGINAL' + (o ? ' · ' + o.name : '')));
      const right = el('div', 'side');
      right.appendChild(draw(NEW, idsFor(axis, dnaOf(axis, i)), sc));
      right.appendChild(el('div', 'cap', '420 · ' + t.name));
      pair.appendChild(left); pair.appendChild(el('div', 'arrow', '→')); pair.appendChild(right);
      card.appendChild(pair);
      card.appendChild(el('div', 'lbl', '<span class="id">' + axis + ' #' + dnaOf(axis, i) + '</span> ' + t.name + tag(st, o)));
      grid.appendChild(card);
    }
    body.appendChild(grid);
  }
  $('summary').textContent = total + ' traits changed/added vs original';
}

function renderPalettes() {
  const body = $('palettes-body');
  body.innerHTML = '';
  const rgb = (c) => 'rgb(' + c[0] + ',' + c[1] + ',' + c[2] + ')';
  const same = (a, b) => a && b && a[0] === b[0] && a[1] === b[1] && a[2] === b[2];
  const group = (title, items) => {
    body.appendChild(el('h3', null, title));
    const w = el('div', 'swatches');
    for (const it of items) {
      const s = el('div', 'sw' + (it.st ? ' ' + it.st : ''));
      s.innerHTML = it.colors.map((c) => '<i style="background:' + rgb(c) + '"></i>').join('') + it.label;
      w.appendChild(s);
    }
    body.appendChild(w);
  };
  const ramp = [2, 3, 4, 10, 16, 17, 18, 19];
  group('SKINS (slots 2 3 4 10 16 17 18 19)', NEW.palettes.skins.map((s, i) => {
    const o = OLD.palettes.skins[i];
    return { colors: ramp.map((k) => s.slots[k]), label: i + ' · ' + s.name,
      st: !o ? 'new' : ramp.every((k) => same(o.slots[k], s.slots[k])) ? '' : 'changed' };
  }));
  group('FIXED SLOTS', Object.keys(NEW.palettes.fixed).map((k) => {
    const o = OLD.palettes.fixed[k];
    const c = NEW.palettes.fixed[k];
    return { colors: o && !same(o, c) ? [o, c] : [c], label: 'slot ' + k + (o && !same(o, c) ? ' (recolored)' : ''),
      st: !o ? 'new' : same(o, c) ? '' : 'changed' };
  }));
  group('IRISES (slot 6)', NEW.palettes.irises.map((s, i) => ({ colors: [s.rgb], label: i + ' · ' + s.name,
    st: !OLD.palettes.irises[i] ? 'new' : same(OLD.palettes.irises[i].rgb, s.rgb) ? '' : 'changed' })));
  group('BACKGROUNDS (slot 15)', NEW.palettes.backgrounds.map((s, i) => ({ colors: [s.rgb], label: i + ' · ' + s.name,
    st: !OLD.palettes.backgrounds[i] ? 'new' : same(OLD.palettes.backgrounds[i].rgb, s.rgb) ? '' : 'changed' })));
}

/* mulberry32 — seeded so a given ?seed= / #seed= is reproducible */
function rng(seed) {
  let a = seed >>> 0;
  return function () {
    a = (a + 0x6D2B79F5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
let seed = (function () {
  const m = /seed=(\d+)/.exec(location.search + location.hash);
  return m ? +m[1] : (Date.now() % 1e9);
})();
const COUNT = (function () {
  const m = /count=(\d+)/.exec(location.search + location.hash);
  return m ? Math.max(48, +m[1]) : 72;
})();

function renderRandom() {
  const body = $('random-body');
  body.innerHTML = '';
  const r = rng(seed);
  const ri = (n) => Math.floor(r() * n);
  const A = NEW.axes, P = NEW.palettes;
  const lower = (s) => s.toLowerCase();
  for (let k = 0; k < COUNT; k++) {
    const ids = {
      expr: ri(A.expressions.length), eyes: ri(A.eyes.length),
      hat: ri(A.hats.length + 1), wear: ri(A.eyewear.length + 1), item: ri(A.items.length + 1),
      skin: ri(P.skins.length), iris: ri(P.irises.length), bg: ri(P.backgrounds.length),
    };
    const card = el('div', 'card');
    card.appendChild(draw(NEW, ids, 2));
    const nm = (axis, id) => (STAMP[axis] ? (id ? lower(A[axis][id - 1].name) : '-') : lower(A[axis][id].name));
    card.appendChild(el('div', 'lbl', [nm('expressions', ids.expr), nm('eyes', ids.eyes), nm('hats', ids.hat),
      nm('eyewear', ids.wear), nm('items', ids.item)].join(' · ') + '<br>' + lower(P.skins[ids.skin].name) + ' · '
      + lower(P.irises[ids.iris].name) + ' · ' + lower(P.backgrounds[ids.bg].name)));
    body.appendChild(card);
  }
  $('random-sub').textContent = COUNT + ' random 420 pepes (uniform over every axis and palette) · seed ' + seed
    + ' — add #seed=' + seed + ' to the URL to reproduce';
}

function fill(sel, arr, cur) {
  sel.innerHTML = '';
  arr.forEach((o, i) => { const opt = document.createElement('option'); opt.value = String(i); opt.textContent = i + ' · ' + o.name; sel.appendChild(opt); });
  sel.value = String(cur);
}

function renderAll() { renderTraits(); renderChanges(); renderPalettes(); }

function init() {
  fill($('sel-skin'), NEW.palettes.skins, view.skin);
  fill($('sel-iris'), NEW.palettes.irises, view.iris);
  fill($('sel-bg'), NEW.palettes.backgrounds, view.bg);
  for (const k of ['skin', 'iris', 'bg', 'scale']) {
    $('sel-' + k).addEventListener('change', (e) => { view[k] = +e.target.value; renderAll(); });
  }
  $('btn-reroll').addEventListener('click', () => { seed = (seed * 1103515245 + 12345) % 1e9; renderRandom(); });
  renderAll();
  renderRandom();
  // the 420 golden: sha256 of the compiled export, same as the studio self-test
  const sol = C.compileSolidity(NEW);
  if (window.crypto && crypto.subtle) {
    crypto.subtle.digest('SHA-256', new TextEncoder().encode(sol)).then((buf) => {
      $('sha').textContent = '420 export sha256 ' + Array.from(new Uint8Array(buf), (b) => b.toString(16).padStart(2, '0')).join('');
    }).catch(() => {});
  }
  window.PSPCollection = { compose: compose, draw: draw, art: NEW, original: OLD, render: renderAll };
  window.__collectionReady = true;
}
init();
})();
