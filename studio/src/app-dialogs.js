/* PSP Trait Studio — dialogs: compile modal, PALETTES tab editor,
 * import (.txt / palettes.json), export files, restore-session modal.
 * Depends on app-core.js. */
(function () {
'use strict';

const PSP = window.PSPApp;
const Dialogs = PSP.Dialogs = {};

function $(id) { return document.getElementById(id); }
function el(tag, cls, html) {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  if (html != null) n.innerHTML = html;
  return n;
}
const hex2 = (v) => '0x' + v.toString(16).toUpperCase().padStart(2, '0');
const rgbHex = (c) => '#' + [c[0], c[1], c[2]].map((v) => v.toString(16).padStart(2, '0')).join('');
const hexRgb = (h) => [parseInt(h.slice(1, 3), 16), parseInt(h.slice(3, 5), 16), parseInt(h.slice(5, 7), 16)];

/* ── boot ──────────────────────────────────────────────── */
let structureDirty = true;
let lastAxis = null;
Dialogs.bind = function () {
  $('btn-compile').addEventListener('click', openCompile);
  $('btn-import').addEventListener('click', () => $('file-input').click());
  $('file-input').addEventListener('change', (e) => { importFiles(e.target.files); e.target.value = ''; });
  $('btn-export').addEventListener('click', exportFiles);
  $('btn-reset-all').addEventListener('click', onResetAll);
  PSP.on('render', () => {
    const axis = PSP.ui().axis;
    if (axis !== lastAxis) { lastAxis = axis; structureDirty = true; }
    if (axis === 'palettes' && structureDirty) Dialogs.renderPaletteEditor();
  });
  PSP.on('found-save', (saved) => offerRestore(saved));
};

/* ── compile modal ─────────────────────────────────────── */
async function openCompile() {
  const S = PSP.state();
  const C = window.PSPCompiler;
  let sol = null, err = null;
  try { sol = C.compileSolidity({ baseGrid: S.axes.head[0].grid, axes: S.axes, palettes: S.palettes }); }
  catch (e) { err = e; }
  const sha = sol ? await PSP.sha256Hex(sol) : null;
  const golden = sha === PSP.GOLDEN_SHA;

  const body = el('div');
  if (err) {
    body.appendChild(el('div', 'banner error', '✗ compile failed — ' + String(err.message || err)));
    body.appendChild(el('p', 'sub', 'Fix the errors in the VALIDATION panel (bottom right) and try again.'));
  } else {
    body.appendChild(el('div', 'banner ' + (golden ? 'golden' : 'plain'),
      golden ? 'identical to repo build ✓' : 'differs from repo build'));
    const lines = sol.split('\n');
    const kv = el('dl', 'kv');
    kv.innerHTML =
      '<dt>sha256</dt><dd>' + sha + '</dd>' +
      '<dt>lines</dt><dd>' + lines.length + '</dd>' +
      '<dt>bytes</dt><dd>' + new TextEncoder().encode(sol).length + '</dd>' +
      '<dt>first line</dt><dd>' + lines[0] + '</dd>' +
      '<dt>last line</dt><dd>' + lines[lines.length - 1] || '' + '</dd>';
    body.appendChild(kv);
    body.appendChild(el('p', 'sub', 'Per-layer byte sizes (stampBytes length — 4-byte header + RLE):'));
    body.appendChild(layerTable(S, C));
    const pre = el('pre', null, sol.replace(/&/g, '&amp;').replace(/</g, '&lt;'));
    body.appendChild(pre);
  }
  PSP.openModal({
    title: '▶ Compile — PepeArtData.sol',
    body: body,
    wide: true,
    buttons: sol ? [
      { label: 'Download PepeArtData.sol', class: 'accent', default: true,
        onClick: () => { PSP.downloadText('PepeArtData.sol', sol, 'text/plain'); } },
      { label: 'Copy', onClick: async () => {
          try { await navigator.clipboard.writeText(sol); }
          catch (e) { const ta = el('textarea'); ta.value = sol; document.body.appendChild(ta); ta.select(); document.execCommand('copy'); ta.remove(); }
        } },
      { label: 'Close' },
    ] : [{ label: 'Close', class: 'accent' }],
  });
}

function layerTable(S, C) {
  const tbl = el('table');
  let rows = '<tr><th>layer</th><th>axis</th><th class="mono">bytes</th></tr>';
  rows += '<tr><td>SPRITE_BASE</td><td>base (head)</td><td class="mono">' + C.rle(S.axes.head[0].grid).length + '</td></tr>';
  const pre = { expressions: 'EXPR', eyes: 'EYE', hats: 'HAT', eyewear: 'WEAR', items: 'ITEM' };  // head == SPRITE_BASE, shown above
  for (const axis of PSP.AXES) {
    if (axis === PSP.HEAD_AXIS) continue;
    for (const t of S.axes[axis]) {
      let n;
      try { n = PSP.gridEmpty(t.grid) ? '— (empty!)' : String(C.stampBytes(t.grid).length); }
      catch (e) { n = '—'; }
      rows += '<tr><td>' + pre[axis] + '_' + t.name + '</td><td>' + axis + '</td><td class="mono">' + n + '</td></tr>';
    }
  }
  tbl.innerHTML = rows;
  return tbl;
}

/* ── palettes.py generation (repo literal format) ──────── */
function tup3(c) { return '(' + hex2(c[0]) + ', ' + hex2(c[1]) + ', ' + hex2(c[2]) + ')'; }
Dialogs.palettesPyText = function (P) {
  const pad11 = (s) => (s + ' '.repeat(11)).slice(0, 11);
  let out = '';
  out += '# PSP pepe palettes — colors for skin / iris / background axes.\n';
  out += '# RGB tuples. Slots each axis recolors:\n';
  out += '#   skin -> slots 2 (base), 3 (light shade), 4 (dark shade), 10 (nostril)\n';
  out += '#   iris -> slot 6 (pupils + brows + eye bags)\n';
  out += '#   bg   -> slot 15 (background)\n';
  out += '# FIXED slots below are shared by every skin — edit with care, they recolor\n';
  out += '# ALL pepes (5 white, 7 lips-rose, 8 lips-dark, 9 red, 11 gold, 12 gold-dark,\n';
  out += '# 13 cookie, 14 shades-black).\n';
  out += '# DNA id = list index. Reordering changes existing DNA!\n';
  out += '\nSKINS = [\n';
  for (const s of P.skins) {
    out += '    (' + pad11('"' + s.name + '",') + '{2: ' + tup3(s.slots[2]) + ', 3: ' + tup3(s.slots[3]) + ',\n';
    out += '                 4: ' + tup3(s.slots[4]) + ', 10: ' + tup3(s.slots[10]) + ')}),\n';
  }
  out += ']\n\nFIXED = {\n';
  for (const k of [5, 6, 7, 8, 9, 11, 12, 13, 14]) {
    const c = P.fixed[k];
    const key = (k + ':').padEnd(4, ' ');
    out += '    ' + key + tup3(c) + ',   # ' + PSP.FIXED_COMMENTS[k] + '\n';
  }
  out += '}\n\nIRISES = [\n';
  for (const i of P.irises) out += '    (' + pad11('"' + i.name + '",') + tup3(i.rgb) + '),\n';
  out += ']\n\nBACKGROUNDS = [\n';
  for (const b of P.backgrounds) out += '    (' + pad11('"' + b.name + '",') + tup3(b.rgb) + '),\n';
  out += ']\n';
  return out;
};

/* ── export ────────────────────────────────────────────── */
async function exportFiles() {
  const S = PSP.state();
  const C = window.PSPCompiler;
  const names = { head: 'head', expressions: 'expressions', eyes: 'eyes', hats: 'hats', eyewear: 'eyewear', items: 'items' };
  for (const axis of PSP.AXES) {
    const traits = S.axes[axis].map((t) => C.gridToTrait(axis, t.name, t.grid));
    PSP.downloadText(names[axis] + '.txt', C.traitText(axis, traits));
    await new Promise((r) => setTimeout(r, 350)); // sequential downloads, no zip needed
  }
  if (PSP.ui().palettesEdited) {
    PSP.downloadText('palettes.py', Dialogs.palettesPyText(S.palettes), 'text/x-python');
  }
  PSP.snapshotExported();
  PSP.addVMsg('info', 'exported 6 trait files (incl. head.txt)' + (PSP.ui().palettesEdited ? ' + palettes.py' : '') + ' to your downloads', { dismissible: true });
}

/* ── import ────────────────────────────────────────────── */
async function importFiles(files) {
  for (const file of files) {
    const text = await file.text();
    if (/\.json$/i.test(file.name)) { await importPalettes(file, text); continue; }
    await importTraitFile(file, text);
  }
  PSP.markChanged();
}
async function importPalettes(file, text) {
  let o = null;
  try { o = JSON.parse(text); } catch (e) {
    PSP.addVMsg('error', file.name + ': not valid JSON — skipped'); return;
  }
  if (!o || !Array.isArray(o.skins) || !o.fixed || !Array.isArray(o.irises) || !Array.isArray(o.backgrounds)) {
    PSP.addVMsg('error', file.name + ': expected a palettes object {skins, fixed, irises, backgrounds} — skipped');
    return;
  }
  const ok = await PSP.confirmModal({
    title: 'Import palettes',
    html: '<p>Replace all palettes with <b>' + file.name + '</b>?</p><p class="sub">' +
      o.skins.length + ' skins · ' + o.irises.length + ' irises · ' + o.backgrounds.length + ' backgrounds</p>',
    okLabel: 'Replace', danger: true,
  });
  if (!ok) return;
  PSP.state().palettes = PSP.clone(o);
  PSP.ui().palettesEdited = true;
  structureDirty = true;
  PSP.addVMsg('info', 'imported palettes from ' + file.name, { dismissible: true });
}
async function importHead(file, parsed) {
  const C = window.PSPCompiler;
  if (parsed.traits.length !== 1 || parsed.traits[0].name !== 'BASE') {
    PSP.addVMsg('error', file.name + ': head.txt must contain exactly one block named BASE — skipped');
    return;
  }
  const ok = await PSP.confirmModal({
    title: 'Import head',
    html: '<p>Replace the base head sprite with <b>' + file.name + '</b>?</p><p class="sub">Every pepe starts from this grid — trait stamps stay untouched.</p>',
    okLabel: 'Replace', danger: true,
  });
  if (!ok) return;
  const S = PSP.state();
  S.axes.head[0].grid = C.traitToGrid(parsed.traits[0]);
  PSP.markChanged();
}
async function importTraitFile(file, text) {
  const C = window.PSPCompiler;
  let parsed;
  try { parsed = C.parseTraitText(text, file.name); }
  catch (e) {
    PSP.addVMsg('error', String(e.message || e) + ' — file skipped');
    return;
  }
  const axis = parsed.axis;
  if (axis === 'head') { await importHead(file, parsed); return; }
  const incoming = parsed.traits.map((t) => ({ name: t.name, grid: C.traitToGrid(t) }));
  const mode = await PSP.chooseModal({
    title: 'Import ' + file.name,
    html: '<p>Parsed <b>' + incoming.length + ' ' + axis.toUpperCase() + '</b> traits: ' +
      incoming.map((t) => t.name).join(', ') + '</p><p class="sub">Replace wipes the axis (DNA ids change). Merge keeps same-name traits in place (same DNA id) and appends new ones at the end.</p>',
    choices: [
      { label: 'Replace axis', class: 'danger', value: 'replace' },
      { label: 'Merge-append', class: 'accent', value: 'merge' },
      { label: 'Skip file', value: 'skip' },
    ],
  });
  if (mode === 'skip' || !mode) return;
  const S = PSP.state();
  if (mode === 'replace') {
    PSP.logDNAShift(axis + ': axis replaced from ' + file.name + ' — old ids: ' +
      S.axes[axis].map((t, i) => '#' + (PSP.STAMP_AXES[axis] ? i + 1 : i) + ' ' + t.name).join(', '));
    S.axes[axis] = incoming.map((t) => ({ name: t.name, grid: t.grid }));
  } else {
    const byName = new Map(S.axes[axis].map((t) => [t.name, t]));
    let kept = 0, appended = 0;
    for (const t of incoming) {
      const ex = byName.get(t.name);
      if (ex) { ex.grid = t.grid; kept++; }
      else { S.axes[axis].push({ name: t.name, grid: t.grid }); appended++; }
    }
    PSP.addVMsg('info', 'merged ' + file.name + ' into ' + axis + ': ' + kept + ' overwritten in place, ' + appended + ' appended', { dismissible: true });
  }
  PSP.ui().sel[axis] = Math.min(PSP.ui().sel[axis], S.axes[axis].length - 1);
  if (PSP.ui().sel[axis] < 0) PSP.ui().sel[axis] = 0;
  PSP.syncSelToPreview();
}

/* ── session restore / reset ───────────────────────────── */
function offerRestore(saved) {
  PSP.openModal({
    title: 'Found a saved session',
    body: '<p>localStorage has autosaved work (' + saved.axes.expressions.length + ' expressions, ' +
      saved.axes.hats.length + ' hats…).</p><p class="sub">Restore it, or start from the embedded repo defaults?</p>',
    buttons: [
      { label: 'Restore', class: 'accent', default: true, onClick: (close) => { PSP.applySaved(saved); close(); } },
      { label: 'Use defaults', onClick: (close) => close() },
    ],
  });
}
async function onResetAll() {
  $('menu').classList.add('hidden');
  const ok = await PSP.confirmModal({
    title: 'Reset all',
    html: '<p>Throw away every edit and reload the <b>embedded repo defaults</b>?</p><p class="sub">Your autosaved session is overwritten. Export first if you want to keep changes.</p>',
    okLabel: 'Reset everything', danger: true,
  });
  if (!ok) return;
  PSP.resetAll();
  structureDirty = true;
  PSP.addVMsg('info', 'state reset to embedded repo defaults', { dismissible: true });
}

/* ── PALETTES tab editor ───────────────────────────────── */
Dialogs.renderPaletteEditor = function () {
  structureDirty = false;
  const root = $('palette-editor');
  root.innerHTML = '';
  const S = PSP.state();
  const P = S.palettes;

  const secSkins = el('div', 'pal-section');
  secSkins.appendChild(el('h3', null, 'SKINS'));
  secSkins.appendChild(el('p', 'note', 'Slots 2/3/4/10 recolor with the skin DNA. Renaming + recoloring is safe; reordering or deleting shifts skin DNA ids.'));
  P.skins.forEach((s, i) => {
    secSkins.appendChild(palRow({
      idx: i, name: s.name, onName: (v) => { s.name = v; touch(); },
      colors: [2, 3, 4, 10].map((k) => ({ label: 'slot ' + k, get: () => s.slots[k], set: (c) => { s.slots[k] = c; touch(); } })),
      onDelete: P.skins.length > 1 ? () => delPal('skins', i, 'skin "' + s.name + '"') : null,
      deletable: P.skins.length > 1,
    }));
  });
  secSkins.appendChild(addBtn('＋ add skin', () => {
    const last = P.skins[P.skins.length - 1];
    P.skins.push({ name: 'SKIN' + (P.skins.length + 1), slots: PSP.clone(last.slots) });
    structureDirty = true; touch(true);
  }));

  const secIris = el('div', 'pal-section');
  secIris.appendChild(el('h3', null, 'IRISES'));
  secIris.appendChild(el('p', 'note', 'Slot 6 (pupils + brows + eye bags). DNA id = list index.'));
  P.irises.forEach((o, i) => {
    secIris.appendChild(palRow({
      idx: i, name: o.name, onName: (v) => { o.name = v; touch(); },
      colors: [{ label: 'rgb', get: () => o.rgb, set: (c) => { o.rgb = c; touch(); } }],
      deletable: P.irises.length > 1,
      onDelete: P.irises.length > 1 ? () => delPal('irises', i, 'iris "' + o.name + '"') : null,
    }));
  });
  secIris.appendChild(addBtn('＋ add iris', () => {
    P.irises.push({ name: 'IRIS' + (P.irises.length + 1), rgb: [128, 128, 128] });
    structureDirty = true; touch(true);
  }));

  const secBg = el('div', 'pal-section');
  secBg.appendChild(el('h3', null, 'BACKGROUNDS'));
  secBg.appendChild(el('p', 'note', 'Slot 15 (preview + PNG background). DNA id = list index.'));
  P.backgrounds.forEach((o, i) => {
    secBg.appendChild(palRow({
      idx: i, name: o.name, onName: (v) => { o.name = v; touch(); },
      colors: [{ label: 'rgb', get: () => o.rgb, set: (c) => { o.rgb = c; touch(); } }],
      deletable: P.backgrounds.length > 1,
      onDelete: P.backgrounds.length > 1 ? () => delPal('backgrounds', i, 'background "' + o.name + '"') : null,
    }));
  });
  secBg.appendChild(addBtn('＋ add background', () => {
    P.backgrounds.push({ name: 'BG' + (P.backgrounds.length + 1), rgb: [20, 24, 20] });
    structureDirty = true; touch(true);
  }));

  const secFixed = el('div', 'pal-section');
  secFixed.appendChild(el('h3', null, 'FIXED SLOTS'));
  secFixed.appendChild(el('p', 'note', '⚠ Shared by every skin — editing recolors ALL pepes on every skin.'));
  const grid = el('div', 'fixed-grid');
  for (const k of [5, 7, 8, 9, 11, 12, 13, 14]) {
    const cell = el('div', 'fixed-cell');
    const inp = el('input'); inp.type = 'color'; inp.value = rgbHex(P.fixed[k]);
    inp.title = 'slot ' + k;
    inp.addEventListener('input', () => { P.fixed[k] = hexRgb(inp.value); touch(); });
    cell.appendChild(inp);
    const meta = el('div', 'meta');
    meta.appendChild(el('div', 'fn', PSP.SLOT_NAMES[k]));
    meta.appendChild(el('div', 'fc', 'slot ' + k + ' · ' + rgbHex(P.fixed[k]).toUpperCase()));
    cell.appendChild(meta);
    grid.appendChild(cell);
  }
  secFixed.appendChild(grid);

  const bar = el('div', 'row-btns');
  const reset = el('button', null, 'Reset palettes');
  reset.addEventListener('click', async () => {
    const ok = await PSP.confirmModal({
      title: 'Reset palettes', okLabel: 'Reset', danger: true,
      html: '<p>Restore skins / irises / backgrounds / fixed slots to the embedded repo defaults?</p>',
    });
    if (!ok) return;
    S.palettes = PSP.clone(window.PSP_DEFAULTS.palettes);
    PSP.ui().palettesEdited = false;
    structureDirty = true;
    PSP.markChanged();
  });
  bar.appendChild(reset);
  const note = el('span', 'dim', PSP.ui().palettesEdited ? ' · palettes edited — Export Files includes palettes.py' : ' · unedited (repo defaults)');
  note.style.alignSelf = 'center';
  bar.appendChild(note);

  root.appendChild(secSkins);
  root.appendChild(secIris);
  root.appendChild(secBg);
  root.appendChild(secFixed);
  root.appendChild(bar);
};

function addBtn(label, fn) {
  const b = el('button', null, label);
  b.addEventListener('click', fn);
  return b;
}
function touch(structural) {
  PSP.ui().palettesEdited = true;
  PSP.markChanged();
}
async function delPal(kind, idx, label) {
  const P = PSP.state().palettes;
  if (idx !== P[kind].length - 1) {
    const ok = await PSP.confirmModal({
      title: 'Delete ' + kind.slice(0, -1),
      html: '<p>Delete <b>' + label + '</b>?</p><p class="sub">⚠ Not the last entry — every entry after it shifts down one DNA id, re-mapping existing pepes.</p>',
      okLabel: 'Delete', danger: true,
    });
    if (!ok) return;
    PSP.logDNAShift(kind + ': deleted ' + label + ' (was #' + idx + ') — ids after it shifted down');
  }
  P[kind].splice(idx, 1);
  const pv = PSP.ui().preview;
  if (kind === 'skins') pv.skin = Math.min(pv.skin, P.skins.length - 1);
  if (kind === 'irises') pv.iris = Math.min(pv.iris, P.irises.length - 1);
  if (kind === 'backgrounds') pv.bg = Math.min(pv.bg, P.backgrounds.length - 1);
  structureDirty = true;
  PSP.markChanged();
}

function palRow(opts) {
  const row = el('div', 'pal-row');
  row.appendChild(el('span', 'idx', '#' + opts.idx));
  const name = el('input'); name.type = 'text'; name.value = opts.name; name.spellcheck = false;
  name.addEventListener('change', () => { const v = name.value.trim() || opts.name; name.value = v; opts.onName(v); });
  row.appendChild(name);
  for (const c of opts.colors) {
    const lab = el('label', 'cid', c.label);
    const inp = el('input'); inp.type = 'color'; inp.value = rgbHex(c.get());
    inp.addEventListener('input', () => { c.set(hexRgb(inp.value)); });
    lab.appendChild(inp);
    row.appendChild(lab);
  }
  if (opts.deletable) {
    const del = el('button', 'rowdel danger', '✕');
    del.title = 'Remove (may shift DNA ids)';
    del.addEventListener('click', opts.onDelete);
    row.appendChild(del);
  } else {
    const del = el('button', 'rowdel', '✕');
    del.disabled = true; del.title = 'Cannot remove the last entry';
    row.appendChild(del);
  }
  return row;
}

})();
