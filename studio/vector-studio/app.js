/* PSP Vector Studio — manual placement dialing for the traced-vector pepes.
 * Mirrors VectorPepeDescriptor.renderSVG exactly: same layer order, same
 * 10px-per-cell offsets, same 16-slot palette assembly. Exports
 * overrides.json that trace_vector.py merges over stamp defaults. */
'use strict';

const L = window.VEC_LIB;
const S = L.S; // cells are 10px on the 480 canvas
const AXES = ['expr', 'eyes', 'hat', 'wear', 'item'];
const LAYERS = [
  ['nostrils', 'nostrils'],
  ['expr', 'expression'],
  ['eyes', 'eyes'],
  ['hat', 'hat'],
  ['wear', 'eyewear'],
  ['item', 'item'],
];

// ── state ────────────────────────────────────────────────────────────
let sel = { expr: 0, eyes: 0, hat: 0, wear: 0, item: 0, skin: 0, iris: 0, bg: 0 };
let off = {};                                    // {axis: {trait: {dx,dy}}}
let noff = { dx: 0, dy: 0 };
let layer = 'eyes';

function save() {
  localStorage.setItem('psp-vector-studio-v1',
    JSON.stringify({ sel, off, noff, layer }));
}
function load() {
  try {
    const s = JSON.parse(localStorage.getItem('psp-vector-studio-v1'));
    if (s) { Object.assign(sel, s.sel || {}); off = s.off || {};
             noff = s.noff || noff; layer = s.layer || layer; }
  } catch (e) { /* fresh start */ }
}

// ── trait lists (order = stamps order = chain ids) ──────────────────
function axisNames(axis) {
  if (axis === 'expr' || axis === 'eyes') return Object.keys(L.stamps[axis]);
  return ['None'].concat(Object.keys(L.stamps[axis]));   // id 0 = None
}
function traitName(axis, id) { return axisNames(axis)[id]; }
function traitId(axis, name) { return axisNames(axis).indexOf(name); }

function curOff(axis, name) {
  if (axis === 'nostrils') return noff;
  const t = (off[axis] || {})[name];
  if (t) return t;
  const baked = L.stamps[axis][name];
  return { dx: baked ? baked.dx : 0, dy: baked ? baked.dy : 0 };
}
function setOff(axis, name, o) {
  if (axis === 'nostrils') { noff = o; return; }
  (off[axis] = off[axis] || {})[name] = o;
}

// ── palette (mirrors VectorBaseArt.palette) ─────────────────────────
const rgb = (c) => '#' + c.map((v) => v.toString(16).padStart(2, '0')).join('');
function palette() {
  const m = new Array(16);
  const sk = L.palettes.skins[sel.skin];
  for (const k of [2, 3, 4, 10]) m[k] = rgb(sk[k]);
  for (const k in L.palettes.fixed) m[+k] = rgb(L.palettes.fixed[k]);
  m[6] = rgb(L.palettes.irises[sel.iris]);
  m[15] = rgb(L.palettes.bgs[sel.bg]);
  return m;
}

// ── render (mirrors the descriptor layer order) ─────────────────────
function render() {
  const pal = palette();
  let g = `<rect width="480" height="480" fill="${pal[15]}"/>`;
  for (const s of [4, 2, 3])                       // rim under fill, light on top
    if (L.base[s]) g += `<path d="${L.base[s]}" fill="${pal[s]}"/>`;

  const hl = (ax) => ax === layer
    ? ' stroke="#ffffff" stroke-width="2" opacity="0.95"' : '';

  const o = noff;
  g += `<g data-layer="nostrils" transform="translate(${o.dx * S},${o.dy * S})">`
     + L.nostrils.map(([cx, cy, rx, ry]) =>
         `<ellipse cx="${cx}" cy="${cy}" rx="${rx}" ry="${ry}" fill="${pal[10]}"${hl('nostrils')}/>`).join('')
     + '</g>';

  for (const ax of AXES) {
    const id = sel[ax];
    if (ax !== 'expr' && ax !== 'eyes' && id === 0) continue;   // None
    const name = traitName(ax, id);
    const meta = L.stamps[ax][name];
    const t = curOff(ax, name);
    g += `<g data-layer="${ax}" transform="translate(${t.dx * S},${t.dy * S})">`
       + meta.paths.map(([slot, d]) =>
           `<path d="${d}" fill="${pal[slot]}"${hl(ax)}/>`).join('')
       + '</g>';
  }
  document.getElementById('stage').innerHTML = g + '';
  renderPanels();
}

// ── panels ───────────────────────────────────────────────────────────
function dnaOf() {
  return sel.expr | (sel.eyes << 3) | (sel.hat << 7) | (sel.wear << 11)
       | (sel.item << 15) | (sel.skin << 19) | (sel.iris << 22) | (sel.bg << 25);
}
function renderPanels() {
  document.getElementById('dna').innerHTML =
    `dna <b>${dnaOf()}</b> (0x${dnaOf().toString(16)}) &middot; ` +
    `skin <b>${(L.palettes.skin_names || [])[sel.skin] || sel.skin}</b>`;
  const tb = document.getElementById('offTable');
  tb.innerHTML = LAYERS.map(([ax, label]) => {
    const name = ax === 'nostrils' ? '—' : traitName(ax, sel[ax]);
    const t = ax === 'nostrils' ? noff : curOff(ax, name);
    const cls = ax === layer ? ' class="cur"' : '';
    return `<tr${cls}><td>${label}</td><td>${name}</td>` +
           `<td>dx ${t.dx >= 0 ? '+' : ''}${t.dx} dy ${t.dy >= 0 ? '+' : ''}${t.dy}</td></tr>`;
  }).join('');
  document.getElementById('jsonBox').value = JSON.stringify(buildOverrides(), null, 2);
}

// ── overrides ────────────────────────────────────────────────────────
function buildOverrides() {
  const o = {};
  for (const ax of AXES) {
    for (const n of Object.keys(L.stamps[ax])) {
      const t = (off[ax] || {})[n];
      if (t) (o[ax] = o[ax] || {})[n] = t;
    }
  }
  if (noff.dx || noff.dy) o.nostrils = { dx: noff.dx, dy: noff.dy };
  return o;
}
function applyOverrides(o) {
  for (const ax of AXES) {
    if (!o[ax]) continue;
    for (const n in o[ax]) {
      if (L.stamps[ax][n]) (off[ax] = off[ax] || {})[n] = {
        dx: o[ax][n].dx | 0, dy: o[ax][n].dy | 0 };
    }
  }
  if (o.nostrils) noff = { dx: o.nostrils.dx | 0, dy: o.nostrils.dy | 0 };
}

// ── controls ─────────────────────────────────────────────────────────
function buildSelects() {
  const mk = (id, names, key) => {
    const el = document.getElementById(id);
    el.innerHTML = names.map((n, i) =>
      `<option value="${i}">${i}: ${n}</option>`).join('');
    el.value = sel[key];
    el.onchange = () => { sel[key] = +el.value; render(); save(); };
  };
  mk('sel-expr', axisNames('expr'), 'expr');
  mk('sel-eyes', axisNames('eyes'), 'eyes');
  mk('sel-hat', axisNames('hat'), 'hat');
  mk('sel-wear', axisNames('wear'), 'wear');
  mk('sel-item', axisNames('item'), 'item');
  const P = L.palettes;
  mk('sel-skin', (P.skin_names || []).map((n, i) => `${n}`), 'skin');
  mk('sel-iris', (P.iris_names || []).map((n, i) => `${n}`), 'iris');
  mk('sel-bg', (P.bg_names || []).map((n, i) => `${n}`), 'bg');

  const ls = document.getElementById('layerSel');
  ls.innerHTML = LAYERS.map(([v, label]) => `<option value="${v}">${label}</option>`).join('');
  ls.value = layer;
  ls.onchange = () => { layer = ls.value; render(); save(); };
}

function randomize() {
  const r = (n) => Math.floor(Math.random() * n);
  sel.expr = r(axisNames('expr').length);
  sel.eyes = r(axisNames('eyes').length);
  sel.hat = r(axisNames('hat').length);
  sel.wear = r(axisNames('wear').length);
  sel.item = r(axisNames('item').length);
  sel.skin = r(L.palettes.skins.length);
  sel.iris = r(L.palettes.irises.length);
  sel.bg = r(L.palettes.bgs.length);
  buildSelects(); render(); save();
}

function resetLayer() {
  if (layer === 'nostrils') { noff = { dx: 0, dy: 0 }; }
  else {
    const name = traitName(layer, sel[layer]);
    if (off[layer]) delete off[layer][name];
  }
  render(); save();
}

// ── drag / nudge ─────────────────────────────────────────────────────
function activeTarget() {
  if (layer === 'nostrils') return { ax: 'nostrils', name: null, o: noff };
  const name = traitName(layer, sel[layer]);
  return { ax: layer, name, o: { ...curOff(layer, name) } };
}
function stagePoint(ev) {
  const r = document.getElementById('stage').getBoundingClientRect();
  return { x: (ev.clientX - r.left) * 480 / r.width,
           y: (ev.clientY - r.top) * 480 / r.height };
}
let drag = null;
function initDrag() {
  const st = document.getElementById('stage');
  st.addEventListener('pointerdown', (ev) => {
    const p = stagePoint(ev);
    const t = activeTarget();
    drag = { start: p, base: { ...t.o }, moved: 0, target: t, ev0: ev };
    st.setPointerCapture(ev.pointerId);
    st.classList.add('dragging');
    ev.preventDefault();
  });
  st.addEventListener('pointermove', (ev) => {
    if (!drag) return;
    const p = stagePoint(ev);
    const ddx = p.x - drag.start.x, ddy = p.y - drag.start.y;
    drag.moved = Math.max(drag.moved, Math.abs(ddx) + Math.abs(ddy));
    const t = drag.target;
    const o = { dx: Math.round((drag.base.dx * S + ddx) / S),
                dy: Math.round((drag.base.dy * S + ddy) / S) };
    setOff(t.ax, t.name, o);
    render();
  });
  const up = (ev) => {
    if (!drag) return;
    const st = document.getElementById('stage');
    st.classList.remove('dragging');
    if (drag.moved < 3) {                        // click = pick layer
      const g = ev.target && ev.target.closest && ev.target.closest('[data-layer]');
      if (g) { layer = g.dataset.layer;
               document.getElementById('layerSel').value = layer; render(); }
    }
    drag = null; save();
  };
  st.addEventListener('pointerup', up);
  st.addEventListener('pointercancel', up);
}
function nudge(dx, dy) {
  const t = activeTarget();
  setOff(t.ax, t.name, { dx: t.o.dx + dx, dy: t.o.dy + dy });
  render(); save();
}

// ── export / import ──────────────────────────────────────────────────
function initIO() {
  const dl = (text, name) => {
    const a = document.createElement('a');
    a.href = URL.createObjectURL(new Blob([text], { type: 'application/json' }));
    a.download = name; a.click(); URL.revokeObjectURL(a.href);
  };
  document.getElementById('btnExport').onclick = () =>
    dl(JSON.stringify(buildOverrides(), null, 2) + '\n', 'overrides.json');
  document.getElementById('btnCopy').onclick = () => {
    const ta = document.getElementById('jsonBox');
    ta.select(); document.execCommand('copy');
    navigator.clipboard && navigator.clipboard.writeText(ta.value).catch(() => {});
  };
  const fi = document.getElementById('fileImport');
  document.getElementById('btnImport').onclick = () => fi.click();
  fi.onchange = () => {
    const f = fi.files[0]; if (!f) return;
    const rd = new FileReader();
    rd.onload = () => { try { applyOverrides(JSON.parse(rd.result));
                             render(); save(); } catch (e) { alert('bad json: ' + e); } };
    rd.readAsText(f);
  };
  document.getElementById('btnClear').onclick = () => {
    if (!confirm('clear all overrides?')) return;
    off = {}; noff = { dx: 0, dy: 0 }; render(); save();
  };
  document.getElementById('btnRandom').onclick = randomize;
  document.getElementById('btnResetLayer').onclick = resetLayer;
}

// ── boot ─────────────────────────────────────────────────────────────
load();
buildSelects();
initDrag();
initIO();
document.addEventListener('keydown', (ev) => {
  if (ev.target.tagName === 'INPUT' || ev.target.tagName === 'TEXTAREA'
      || ev.target.tagName === 'SELECT') return;
  const step = ev.shiftKey ? 5 : 1;
  if (ev.key === 'ArrowLeft') { nudge(-step, 0); ev.preventDefault(); }
  else if (ev.key === 'ArrowRight') { nudge(step, 0); ev.preventDefault(); }
  else if (ev.key === 'ArrowUp') { nudge(0, -step); ev.preventDefault(); }
  else if (ev.key === 'ArrowDown') { nudge(0, step); ev.preventDefault(); }
});
render();
