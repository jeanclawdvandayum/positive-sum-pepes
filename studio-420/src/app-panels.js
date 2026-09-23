/* PSP Trait Studio — panels: axis tabs, trait list, palette dock,
 * live preview, validation panel, status bar. Depends on app-core.js. */
(function () {
'use strict';

const PSP = window.PSPApp;
const Panels = PSP.Panels = {};

function $(id) { return document.getElementById(id); }
function el(tag, cls, html) {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  if (html != null) n.innerHTML = html;
  return n;
}

/* ── boot wiring ───────────────────────────────────────── */
Panels.bind = function () {
  $('t-new').addEventListener('click', onNew);
  $('t-dup').addEventListener('click', () => PSP.duplicateTrait());
  $('t-rename').addEventListener('click', onRename);
  $('t-del').addEventListener('click', onDelete);
  $('t-up').addEventListener('click', () => onMove(-1));
  $('t-down').addEventListener('click', () => onMove(1));

  $('preview-scale').addEventListener('change', (e) => {
    PSP.ui().preview.scale = +e.target.value;
    Panels.renderPreview();
    PSP.persistSoon();
  });
  $('sel-skin').addEventListener('change', (e) => { PSP.ui().preview.skin = +e.target.value; PSP.emit('render'); PSP.persistSoon(); });
  $('sel-iris').addEventListener('change', (e) => { PSP.ui().preview.iris = +e.target.value; PSP.emit('render'); PSP.persistSoon(); });
  $('sel-bg').addEventListener('change', (e) => { PSP.ui().preview.bg = +e.target.value; PSP.emit('render'); PSP.persistSoon(); });
  $('btn-random').addEventListener('click', onRandom);
  $('btn-png').addEventListener('click', onPng);

  $('validation-toggle').addEventListener('click', () => {
    const list = $('validation-list');
    const hidden = list.classList.toggle('hidden');
    $('validation-toggle').innerHTML =
      (hidden ? '▸' : '▾') + ' <span>VALIDATION</span> <span id="validation-badge"></span>';
    Panels.renderValidation();
  });
  PSP.on('validation', () => Panels.renderValidation());
  PSP.on('render', () => Panels.render());
};

/* ── main render ───────────────────────────────────────── */
Panels.render = function () {
  Panels.renderTabs();
  const axis = PSP.ui().axis;
  const isPal = axis === 'palettes';
  $('left').classList.toggle('hidden', isPal);
  $('editor-ui').classList.toggle('hidden', isPal);
  $('palette-editor').classList.toggle('hidden', !isPal);
  $('traitlist-title').textContent = isPal ? '' : axis.toUpperCase();
  if (!isPal) {
    Panels.renderTraitList();
    Panels.renderStatusMid();
  }
  Panels.renderDock();
  Panels.renderPreview();
  Panels.renderValidation();
  if (PSP.Canvas) PSP.Canvas.render();
};

/* ── tabs ──────────────────────────────────────────────── */
Panels.renderTabs = function () {
  const c = PSP.counts();
  const UI = PSP.ui();
  PSP.AXES.forEach((a) => {
    const b = document.querySelector('#tabs .tab[data-axis="' + a + '"]');
    if (!b) return;
    b.classList.toggle('active', UI.axis === a);
    const cnt = $('count-' + a);
    if (cnt) cnt.textContent = '(' + c[a] + ')';
  });
  const pb = document.querySelector('#tabs .tab[data-axis="palettes"]');
  if (pb) pb.classList.toggle('active', UI.axis === 'palettes');
};

/* ── trait list ────────────────────────────────────────── */
Panels.renderTraitList = function () {
  const UI = PSP.ui();
  const axis = UI.axis;
  const list = $('trait-list');
  list.innerHTML = '';
  const isStamp = !!PSP.STAMP_AXES[axis];
  const arr = PSP.state().axes[axis];

  const isHead = axis === PSP.HEAD_AXIS;   // one BASE sprite: no trait ops
  const enable = (id, on) => { $(id).disabled = !on; };
  const idx = UI.sel[axis];
  enable('t-new', !isHead);
  enable('t-rename', !isHead && idx >= 0);
  enable('t-del', !isHead && idx >= 0);
  enable('t-dup', !isHead && idx >= 0);
  enable('t-up', !isHead && idx >= 0 && idx > 0);
  enable('t-down', !isHead && idx >= 0 && idx < arr.length - 1);

  if (isStamp) list.appendChild(noneRow(axis, idx < 0));
  arr.forEach((t, i) => {
    const dna = isStamp ? i + 1 : i;
    list.appendChild(traitRow(axis, t, i, dna, i === idx));
  });
};

function noneRow(axis, selected) {
  const row = el('div', 'trait-row none-row' + (selected ? ' selected' : ''));
  row.appendChild(el('span', 'dna-badge', '#0'));
  row.appendChild(el('span', 'trait-name', 'NONE'));
  const th = el('canvas', 'trait-thumb');
  th.width = PSP.SIZE; th.height = PSP.SIZE; th.title = 'implicit — no ' + axis + ' stamp';
  row.appendChild(th);
  row.addEventListener('click', () => PSP.selectTrait(axis, -1));
  return row;
}
function traitRow(axis, t, i, dna, selected) {
  const row = el('div', 'trait-row' + (selected ? ' selected' : ''));
  row.appendChild(el('span', 'dna-badge', '#' + dna));
  row.appendChild(el('span', 'trait-name', t.name));
  const th = el('canvas', 'trait-thumb');
  th.width = PSP.SIZE; th.height = PSP.SIZE;
  drawThumb(th, t.grid);
  row.appendChild(th);
  row.title = t.name + ' — DNA id ' + dna + ' · double-click to rename';
  row.addEventListener('click', () => PSP.selectTrait(axis, i));
  if (axis !== PSP.HEAD_AXIS) {
    row.addEventListener('dblclick', () => { PSP.selectTrait(axis, i); onRename(); });
  }
  return row;
}
function drawThumb(cvs, grid) {
  const c = cvs.getContext('2d');
  c.clearRect(0, 0, PSP.SIZE, PSP.SIZE);
  const pal = PSP.resolvePal();
  for (let y = 0; y < PSP.SIZE; y++) for (let x = 0; x < PSP.SIZE; x++) {
    const v = grid[y][x];
    if (!v) continue;
    const rgb = pal[v];
    c.fillStyle = 'rgb(' + rgb[0] + ',' + rgb[1] + ',' + rgb[2] + ')';
    c.fillRect(x, y, 1, 1);
  }
}

/* ── trait list actions ────────────────────────────────── */
async function onNew() {
  const axis = PSP.ui().axis;
  if (axis === PSP.HEAD_AXIS) return;
  const name = await PSP.promptModal({
    title: 'New ' + axis.slice(0, -1) + ' trait',
    label: 'Appends at the end — no DNA shift. Name (used as the Solidity constant suffix):',
    value: PSP.uniqueName(axis, 'NEW'),
    okLabel: 'Create',
    validate: (v) => PSP.isValidTraitName(axis, v),
  });
  if (name) PSP.addTrait(axis, name);
}
async function onRename() {
  const UI = PSP.ui();
  const t = PSP.currentTrait();
  if (!t) return;
  const name = await PSP.promptModal({
    title: 'Rename trait',
    label: 'Renaming does NOT shift DNA ids (ids are positional).',
    value: t.name,
    validate: (v) => PSP.isValidTraitName(UI.axis, v, t),
  });
  if (name) PSP.renameTrait(t, name);
}
async function onDelete() {
  const UI = PSP.ui();
  const axis = UI.axis;
  const arr = PSP.state().axes[axis];
  const idx = UI.sel[axis];
  if (idx < 0) return;
  const t = arr[idx];
  const isStamp = !!PSP.STAMP_AXES[axis];
  const dna = isStamp ? idx + 1 : idx;
  let body = '<p>Delete <b>' + t.name + '</b> (#' + dna + ') from <b>' + axis.toUpperCase() + '</b>?</p>';
  if (PSP.shiftsDNA(axis, idx)) {
    body += '<p class="sub">⚠ This is not the last trait — <b>every trait after it shifts down one DNA id</b>, which re-maps existing pepes.</p>';
    body += '<p class="sub">New ordering:</p><ul class="order">'
      + PSP.orderList(axis, idx).map((o) => '<li>#' + o.id + ' ' + o.name + '</li>').join('')
      + '</ul>';
  }
  const ok = await PSP.confirmModal({ title: 'Delete trait', html: body, okLabel: 'Delete', danger: true });
  if (!ok) return;
  PSP.deleteTraitIdx(axis, idx);
  const after = PSP.orderList(axis, null);
  PSP.logDNAShift(axis + ': deleted "' + t.name + '" (was #' + dna + ') — axis now has '
    + after.length + ' traits: ' + after.map((o) => '#' + o.id + ' ' + o.name).join(', '));
}
async function onMove(dir) {
  const UI = PSP.ui();
  const axis = UI.axis;
  const arr = PSP.state().axes[axis];
  const idx = UI.sel[axis];
  if (idx < 0) return;
  const t = arr[idx];
  const isStamp = !!PSP.STAMP_AXES[axis];
  const dna = isStamp ? idx + 1 : idx;
  const j = idx + dir;
  if (j < 0 || j >= arr.length) return;
  if (idx !== arr.length - 1 || j !== arr.length - 1) {
    const other = arr[j];
    const body = '<p>Swap <b>' + t.name + '</b> (#' + dna + ') with <b>' + other.name + '</b> (#' + (isStamp ? j + 1 : j) + ')?</p>'
      + '<p class="sub">⚠ Reordering changes <b>DNA ids</b> of existing pepes. New ordering:</p><ul class="order">'
      + (() => {
          const a2 = arr.slice(); const tmp = a2[idx]; a2[idx] = a2[j]; a2[j] = tmp;
          return a2.map((o, i) => '<li class="' + (o === t || o === other ? 'added' : '') + '">#' + (isStamp ? i + 1 : i) + ' ' + o.name + '</li>').join('');
        })()
      + '</ul>';
    const ok = await PSP.confirmModal({ title: 'Move trait', html: body, okLabel: 'Move', danger: true });
    if (!ok) return;
    PSP.logDNAShift(axis + ': moved "' + t.name + '" from #' + dna + ' to #' + (isStamp ? j + 1 : j));
  }
  PSP.moveTraitIdx(axis, idx, dir);
}

/* ── palette dock ──────────────────────────────────────── */
const GROUPS = [
  { label: 'TRANSPARENT', slots: [0] },
  { label: 'SKIN — recolors with skin', slots: [2, 3, 4, 10] },
  { label: 'SKIN RAMP (69px) — high-contrast, recolors with skin', slots: [16, 17, 18, 19] },
  { label: 'IRIS', slots: [6] },
  { label: 'FIXED', slots: [5, 7, 8, 9, 11, 12, 13, 14, 20, 21, 22, 23] },
  { label: 'UNUSED IN STAMPS', slots: [1, 15] },
];
Panels.renderDock = function () {
  const dock = $('palette-dock');
  if (!dock) return;
  dock.innerHTML = '';
  const pal = PSP.resolvePal();
  const armed = PSP.ui().editor.armed;
  for (const grp of GROUPS) {
    const g = el('div', 'pal-group');
    g.appendChild(el('div', 'pal-group-label', grp.label));
    const sw = el('div', 'pal-swatches');
    for (const slot of grp.slots) {
      const b = el('button', 'swatch' + (slot === armed ? ' armed' : '') + ((slot === 1 || slot === 15) ? ' disabled' : ''));
      b.type = 'button';
      if (slot !== 0) {
        const f = el('span', 'fill');
        const c = pal[slot];
        f.style.background = 'rgb(' + c[0] + ',' + c[1] + ',' + c[2] + ')';
        b.appendChild(f);
      }
      b.appendChild(el('span', 'slotno', String(slot)));
      const extra = slot === 2 || slot === 3 || slot === 4 || slot === 10 || (slot >= 16 && slot <= 19) ? ' — recolors with skin'
        : slot === 6 ? ' — recolors with iris' : slot === 15 ? ' — recolors with background'
        : slot === 1 || slot === 0 ? '' : ' — fixed';
      b.title = slot + ' · ' + PSP.SLOT_NAMES[slot] + extra + (slot === 1 || slot === 15 ? ' (unused in stamps)' : '');
      if (slot !== 1 && slot !== 15) b.addEventListener('click', () => PSP.armSlot(slot));
      else b.disabled = true;
      sw.appendChild(b);
    }
    g.appendChild(sw);
    dock.appendChild(g);
  }
};

/* ── preview ───────────────────────────────────────────── */
Panels.renderPreview = function () {
  const UI = PSP.ui();
  const P = UI.preview;
  const sel = $('preview-scale');
  if (+sel.value !== P.scale) sel.value = String(P.scale);
  const pal = PSP.resolvePal();
  const grid = PSP.compose({ expr: P.expr, eyes: P.eyes, hat: P.hat, wear: P.wear, item: P.item });

  const cvs = $('preview');
  const scale = P.scale;
  const px = PSP.SIZE * scale;
  cvs.width = px; cvs.height = px;
  cvs.style.width = Math.min(px, 340) + 'px';
  cvs.style.height = 'auto';
  const c = cvs.getContext('2d');
  const bgc = pal[15];
  c.fillStyle = 'rgb(' + bgc[0] + ',' + bgc[1] + ',' + bgc[2] + ')';
  c.fillRect(0, 0, px, px);
  for (let y = 0; y < PSP.SIZE; y++) for (let x = 0; x < PSP.SIZE; x++) {
    const v = grid[y][x];
    if (!v) continue;
    const rgb = pal[v];
    c.fillStyle = 'rgb(' + rgb[0] + ',' + rgb[1] + ',' + rgb[2] + ')';
    c.fillRect(x * scale, y * scale, scale, scale);
  }

  // dropdowns
  fillSel($('sel-skin'), PSP.state().palettes.skins, P.skin);
  fillSel($('sel-iris'), PSP.state().palettes.irises, P.iris);
  fillSel($('sel-bg'), PSP.state().palettes.backgrounds, P.bg);

  // dna line
  const dna = PSP.packDNA(P);
  $('dna-line').textContent = 'dna ' + dna + ' · 0x' + dna.toString(16).toUpperCase().padStart(8, '0')
    + ' · ' + comboNames(P);
};
function fillSel(sel, arr, cur) {
  const val = String(Math.min(cur, arr.length - 1));
  if (sel.value !== val || sel.options.length !== arr.length) {
    sel.innerHTML = '';
    arr.forEach((o, i) => {
      const opt = document.createElement('option');
      opt.value = String(i);
      opt.textContent = i + ' · ' + o.name;
      sel.appendChild(opt);
    });
  }
  sel.value = val;
}
function comboNames(P) {
  const S = PSP.state();
  const name = (axis, id, noneAt0) => {
    if (noneAt0 && id === 0) return 'none';
    const t = S.axes[axis][noneAt0 ? id - 1 : id];
    return t ? t.name.toLowerCase() : '?';
  };
  return [
    name('expressions', P.expr), name('eyes', P.eyes), name('hats', P.hat, true),
    name('eyewear', P.wear, true), name('items', P.item, true),
  ].join(' · ') + ' · ' + S.palettes.skins[Math.min(P.skin, S.palettes.skins.length - 1)].name.toLowerCase()
    + ' · ' + S.palettes.irises[Math.min(P.iris, S.palettes.irises.length - 1)].name.toLowerCase()
    + ' · ' + S.palettes.backgrounds[Math.min(P.bg, S.palettes.backgrounds.length - 1)].name.toLowerCase();
}

function onRandom() {
  const UI = PSP.ui();
  const c = PSP.counts();
  const ri = (n) => Math.floor(Math.random() * n);
  const P = UI.preview;
  P.expr = ri(c.expressions); P.eyes = ri(c.eyes);
  P.hat = ri(c.hats); P.wear = ri(c.eyewear); P.item = ri(c.items);
  P.skin = ri(PSP.state().palettes.skins.length);
  P.iris = ri(PSP.state().palettes.irises.length);
  P.bg = ri(PSP.state().palettes.backgrounds.length);
  PSP.syncSelToPreview();
  PSP.emit('render');
  PSP.persistSoon();
}

function onPng() {
  const P = PSP.ui().preview;
  const cvs = $('preview');
  const url = cvs.toDataURL('image/png');
  const dna = PSP.packDNA(P).toString(16).toUpperCase().padStart(8, '0');
  PSP.download('pepe-' + dna + '-' + P.scale + 'x.png', url);
}

/* ── validation panel ──────────────────────────────────── */
Panels.renderValidation = function () {
  const badge = $('validation-badge');
  const list = $('validation-list');
  if (!badge || !list) return;
  const msgs = PSP.vmsgs();
  const errs = msgs.filter((m) => m.sev === 'error').length;
  const warns = msgs.filter((m) => m.sev === 'warn').length;
  if (!msgs.length) { badge.textContent = 'OK'; badge.className = 'ok'; }
  else {
    badge.textContent = (errs ? errs + ' error' + (errs > 1 ? 's' : '') : '') +
      (errs && warns ? ' · ' : '') + (warns ? warns + ' warning' + (warns > 1 ? 's' : '') : '') +
      (!errs && !warns ? msgs.length + ' note' + (msgs.length > 1 ? 's' : '') : '');
    badge.className = errs ? 'bad' : 'ok';
  }
  list.innerHTML = '';
  for (const m of msgs) {
    const row = el('div', 'vmsg ' + m.sev);
    row.appendChild(el('span', 'sev', m.sev === 'error' ? '✗ error' : m.sev === 'warn' ? '⚠ warn' : 'ℹ note'));
    const txt = el('span', 'mono', m.text);
    row.appendChild(txt);
    if (m.dismissible) {
      const d = el('button', 'dismiss', '✕');
      d.title = 'Dismiss';
      d.addEventListener('click', () => PSP.dismissVMsg(m.key));
      row.appendChild(d);
    }
    list.appendChild(row);
  }
};

/* ── status bar ────────────────────────────────────────── */
Panels.renderStatusMid = function () {
  const c = PSP.counts();
  const S = PSP.state();
  const combos = c.expressions * c.eyes * c.hats * c.eyewear * c.items *
    S.palettes.skins.length * S.palettes.irises.length * S.palettes.backgrounds.length;
  const m = combos >= 1e6 ? (combos / 1e6).toFixed(2) + 'M' : combos.toLocaleString();
  $('statusbar-mid').textContent =
    c.expressions + ' expressions · ' + c.eyes + ' eyes · ' + c.hats + ' hats · ' +
    c.eyewear + ' eyewear · ' + c.items + ' items · ' + m + ' combos';
};

})();
