/* PSP Trait Studio — canvas editor: 48x48 grid painting, tools, mirror-X,
 * ghost underlay, grid lines, hover status. Depends on app-core.js. */
(function () {
'use strict';

const PSP = window.PSPApp;
const Canvas = PSP.Canvas = {};

let cvs = null, ctx = null;
let hover = null;          // {x,y} cell under cursor
let gesture = null;        // active drag: {tool, snapshot, anchor, last, changed}
let linePreview = null;    // cells while dragging line/rect

Canvas.bind = function () {
  cvs = PSP.$('editor');
  ctx = cvs.getContext('2d');
  cvs.addEventListener('pointerdown', onDown);
  cvs.addEventListener('pointermove', onMove);
  cvs.addEventListener('pointerup', onUp);
  cvs.addEventListener('pointercancel', onCancel);
  cvs.addEventListener('pointerleave', () => { hover = null; linePreview = null; Canvas.render(); setStatus(); });
  cvs.addEventListener('contextmenu', (e) => e.preventDefault());
  PSP.$('cell-size').addEventListener('input', (e) => {
    PSP.ui().editor.cell = +e.target.value;
    PSP.$('cell-size-label').textContent = e.target.value;
    Canvas.render();
    PSP.persistSoon();
  });
  PSP.$('btn-gridlines').addEventListener('click', (e) => {
    const ed = PSP.ui().editor; ed.grid = !ed.grid;
    e.currentTarget.classList.toggle('on', ed.grid); Canvas.render(); PSP.persistSoon();
  });
  PSP.$('btn-ghost').addEventListener('click', (e) => {
    const ed = PSP.ui().editor; ed.ghost = !ed.ghost;
    e.currentTarget.classList.toggle('on', ed.ghost); Canvas.render(); PSP.persistSoon();
  });
  PSP.$('ghost-opacity').addEventListener('input', (e) => {
    PSP.ui().editor.ghostAlpha = +e.target.value / 100; Canvas.render(); PSP.persistSoon();
  });
  PSP.$('btn-mirror').addEventListener('click', (e) => {
    const ed = PSP.ui().editor; ed.mirror = !ed.mirror;
    e.currentTarget.classList.toggle('on', ed.mirror); Canvas.render(); PSP.persistSoon();
  });
  PSP.$('bg-checker').addEventListener('click', () => setBg('checker'));
  PSP.$('bg-dark').addEventListener('click', () => setBg('dark'));
  document.querySelectorAll('#tool-buttons .tool').forEach((b) => {
    b.addEventListener('click', () => setTool(b.getAttribute('data-tool')));
  });
  PSP.$('btn-undo').addEventListener('click', () => PSP.undo());
  PSP.$('btn-redo').addEventListener('click', () => PSP.redo());
  PSP.on('undochange', updateUndoButtons);
};

function setBg(mode) {
  const ed = PSP.ui().editor;
  ed.bg = mode;
  PSP.$('bg-checker').classList.toggle('on', mode === 'checker');
  PSP.$('bg-dark').classList.toggle('on', mode === 'dark');
  Canvas.render();
  PSP.persistSoon();
}
function setTool(t) {
  const ed = PSP.ui().editor;
  if (ed.tool !== 'picker' && t !== 'picker') ed.prevTool = t;
  ed.tool = t;
  document.querySelectorAll('#tool-buttons .tool').forEach((b) => {
    b.classList.toggle('active', b.getAttribute('data-tool') === t);
  });
  cvs.classList.toggle('pick', t === 'picker');
  Canvas.render();
  PSP.persistSoon();
}
Canvas.syncToolbar = function () {
  const ed = PSP.ui().editor;
  document.querySelectorAll('#tool-buttons .tool').forEach((b) => {
    b.classList.toggle('active', b.getAttribute('data-tool') === ed.tool);
  });
  cvs.classList.toggle('pick', ed.tool === 'picker');
  PSP.$('btn-mirror').classList.toggle('on', ed.mirror);
  PSP.$('btn-gridlines').classList.toggle('on', ed.grid);
  PSP.$('btn-ghost').classList.toggle('on', ed.ghost);
  PSP.$('ghost-opacity').value = Math.round(ed.ghostAlpha * 100);
  PSP.$('bg-checker').classList.toggle('on', ed.bg === 'checker');
  PSP.$('bg-dark').classList.toggle('on', ed.bg === 'dark');
  PSP.$('cell-size').value = ed.cell;
  PSP.$('cell-size-label').textContent = String(ed.cell);
  updateUndoButtons();
};
function updateUndoButtons() {
  PSP.$('btn-undo').disabled = !PSP.canUndo();
  PSP.$('btn-redo').disabled = !PSP.canRedo();
}

/* ── rendering ─────────────────────────────────────────── */
Canvas.render = function () {
  if (!cvs) return;
  const UI = PSP.ui(), ed = UI.editor;
  const cell = ed.cell, px = cell * PSP.SIZE;
  if (cvs.width !== px) { cvs.width = px; cvs.height = px; }
  cvs.style.width = px + 'px'; cvs.style.height = px + 'px';
  const pal = PSP.resolvePal();
  const trait = PSP.currentTrait();

  // background
  if (ed.bg === 'dark') {
    ctx.fillStyle = '#0a0e0b';
    ctx.fillRect(0, 0, px, px);
  } else {
    const q = Math.max(4, cell);
    for (let y = 0; y < px; y += q) for (let x = 0; x < px; x += q) {
      ctx.fillStyle = ((x / q + y / q) % 2 === 0) ? '#20261f' : '#171c17';
      ctx.fillRect(x, y, q, q);
    }
  }

  // ghost base-head underlay (for placing hats/eyewear/items; expr/eyes
  // draw over it) — skipped when editing the head itself (it IS the head)
  if (ed.ghost && UI.axis !== PSP.HEAD_AXIS) {
    ctx.globalAlpha = Math.max(0.05, Math.min(0.95, ed.ghostAlpha));
    drawGrid(PSP.state().axes.head[0].grid, pal, cell);
    ctx.globalAlpha = 1;
  }

  // the trait being edited (slightly stronger so it reads over the ghost)
  if (trait) {
    ctx.globalAlpha = 1;
    drawGrid(trait.grid, pal, cell);
    // outline the trait's own pixels so they pop against the ghost
    ctx.globalAlpha = 0.55;
    ctx.strokeStyle = 'rgba(255,255,255,0.5)';
    ctx.lineWidth = 1;
    for (let y = 0; y < PSP.SIZE; y++) for (let x = 0; x < PSP.SIZE; x++) {
      if (trait.grid[y][x] && edge(trait.grid, x, y)) {
        ctx.strokeRect(x * cell + 0.5, y * cell + 0.5, cell - 1, cell - 1);
      }
    }
    ctx.globalAlpha = 1;
  }

  // grid lines
  if (ed.grid) {
    ctx.strokeStyle = 'rgba(255,255,255,0.07)';
    ctx.lineWidth = 1;
    ctx.beginPath();
    for (let i = 0; i <= PSP.SIZE; i++) {
      ctx.moveTo(i * cell + 0.5, 0); ctx.lineTo(i * cell + 0.5, px);
      ctx.moveTo(0, i * cell + 0.5); ctx.lineTo(px, i * cell + 0.5);
    }
    ctx.stroke();
    // center + mirror guide
    ctx.strokeStyle = 'rgba(98,200,117,0.25)';
    ctx.beginPath(); ctx.moveTo(px / 2 + 0.5, 0); ctx.lineTo(px / 2 + 0.5, px); ctx.stroke();
  }
  if (ed.mirror) {
    ctx.strokeStyle = 'rgba(98,200,117,0.8)';
    ctx.setLineDash([4, 3]);
    ctx.beginPath(); ctx.moveTo(px / 2 + 0.5, 0); ctx.lineTo(px / 2 + 0.5, px); ctx.stroke();
    ctx.setLineDash([]);
  }

  // line/rect drag preview
  if (linePreview) {
    ctx.fillStyle = 'rgba(98,200,117,0.65)';
    for (const c of linePreview) ctx.fillRect(c[0] * cell + 1, c[1] * cell + 1, cell - 2, cell - 2);
  }
  // hover cell
  if (hover) {
    ctx.strokeStyle = 'rgba(255,255,255,0.85)';
    ctx.lineWidth = 2;
    ctx.strokeRect(hover.x * cell + 1, hover.y * cell + 1, cell - 2, cell - 2);
  }
};

function edge(g, x, y) {
  const v = g[y][x];
  return !g[y][x - 1] || !g[y][x + 1] || !g[y - 1] || !g[y - 1][x] || !g[y + 1] || !g[y + 1][x] || g[y - 1][x] !== v || g[y + 1][x] !== v;
}
function drawGrid(g, pal, cell) {
  for (let y = 0; y < PSP.SIZE; y++) for (let x = 0; x < PSP.SIZE; x++) {
    const v = g[y][x];
    if (!v) continue;
    const c = pal[v];
    ctx.fillStyle = 'rgb(' + c[0] + ',' + c[1] + ',' + c[2] + ')';
    ctx.fillRect(x * cell, y * cell, cell, cell);
  }
}

/* ── coordinates / status ──────────────────────────────── */
function cellAt(e) {
  const r = cvs.getBoundingClientRect();
  const x = Math.floor((e.clientX - r.left) / r.width * PSP.SIZE);
  const y = Math.floor((e.clientY - r.top) / r.height * PSP.SIZE);
  if (x < 0 || x >= PSP.SIZE || y < 0 || y >= PSP.SIZE) return null;
  return { x: x, y: y };
}
function setStatus() {
  const UI = PSP.ui();
  const ed = UI.editor;
  const slot = ed.armed;
  const slotTxt = slot + ' ' + (PSP.SLOT_NAMES[slot] || '?');
  const trait = PSP.currentTrait();
  let idTxt = 'NONE (#0)';
  if (trait) {
    const idx = UI.sel[UI.axis];
    idTxt = trait.name + ' (#' + (PSP.STAMP_AXES[UI.axis] ? idx + 1 : idx) + ')';
  }
  const pos = hover ? 'x ' + hover.x + ' · y ' + hover.y : '—';
  PSP.$('statusline').innerHTML = pos + ' · slot <b>' + slotTxt + '</b> · trait <b>' + idTxt + '</b>'
    + (ed.mirror ? ' · <b>MIRROR-X</b>' : '');
}

/* ── painting ──────────────────────────────────────────── */
function applyMirror(cells) {
  const ed = PSP.ui().editor;
  if (!ed.mirror) return cells;
  const seen = new Set(cells.map((c) => c[1] * PSP.SIZE + c[0]));
  const out = cells.slice();
  for (const c of cells) {
    const mx = PSP.SIZE - 1 - c[0], k = c[1] * PSP.SIZE + mx;
    if (!seen.has(k)) { seen.add(k); out.push([mx, c[1]]); }
  }
  return out;
}
function paintCells(cells, slot) {
  const g = PSP.currentTrait().grid;
  let changed = false;
  for (const c of cells) {
    if (g[c[1]][c[0]] !== slot) { g[c[1]][c[0]] = slot; changed = true; }
  }
  return changed;
}
function lineCells(a, b) {
  const out = [];
  let x0 = a.x, y0 = a.y, x1 = b.x, y1 = b.y;
  const dx = Math.abs(x1 - x0), dy = Math.abs(y1 - y0);
  const sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1;
  let err = dx - dy;
  for (;;) {
    out.push([x0, y0]);
    if (x0 === x1 && y0 === y1) break;
    const e2 = 2 * err;
    if (e2 > -dy) { err -= dy; x0 += sx; }
    if (e2 < dx) { err += dx; y0 += sy; }
  }
  return out;
}
function rectCells(a, b) {
  const out = [];
  const x0 = Math.min(a.x, b.x), x1 = Math.max(a.x, b.x);
  const y0 = Math.min(a.y, b.y), y1 = Math.max(a.y, b.y);
  for (let x = x0; x <= x1; x++) { out.push([x, y0]); out.push([x, y1]); }
  for (let y = y0 + 1; y < y1; y++) { out.push([x0, y]); out.push([x1, y]); }
  return out;
}
function floodCells(g, sx, sy, slot) {
  const target = g[sy][sx];
  if (target === slot) return [];
  const seen = new Set();
  const out = [];
  const stack = [[sx, sy]];
  while (stack.length) {
    const c = stack.pop();
    const k = c[1] * PSP.SIZE + c[0];
    if (seen.has(k)) continue;
    seen.add(k);
    const x = c[0], y = c[1];
    if (x < 0 || x >= PSP.SIZE || y < 0 || y >= PSP.SIZE || g[y][x] !== target) continue;
    out.push([x, y]);
    stack.push([x + 1, y], [x - 1, y], [x, y + 1], [x, y - 1]);
  }
  return out;
}

function beginGesture() {
  if (!gesture) {
    gesture = { snapshot: PSP.cloneGrid(PSP.currentTrait().grid), changed: false };
  }
}
function endGesture() {
  if (gesture && gesture.changed) {
    PSP.pushUndo(PSP.currentTrait(), gesture.snapshot);
    PSP.markChanged();
  } else if (gesture) {
    PSP.emit('render');
  }
  gesture = null;
  linePreview = null;
}

function onDown(e) {
  e.preventDefault();
  const trait = PSP.currentTrait();
  if (!trait) return;
  cvs.setPointerCapture(e.pointerId);
  const c = cellAt(e);
  if (!c) return;
  const ed = PSP.ui().editor;
  const g = trait.grid;
  const rightBtn = e.button === 2;

  if (ed.tool === 'picker') {
    PSP.armSlot(g[c.y][c.x]);
    return;
  }
  let slot = ed.armed;
  if (ed.tool === 'eraser') slot = 0;
  if (rightBtn) slot = 0; // right-click = erase from any tool

  if (ed.tool === 'fill') {
    beginGesture();
    const cells = floodCells(g, c.x, c.y, slot);
    if (cells.length) gesture.changed = paintCells(cells, slot) || gesture.changed; // flood fill does NOT mirror
    endGesture();
    return;
  }
  if (ed.tool === 'line' || ed.tool === 'rect') {
    gesture = { snapshot: PSP.cloneGrid(g), changed: false, anchor: c, last: c, slot: slot };
    linePreview = [];
    Canvas.render();
    return;
  }
  // pencil / eraser
  beginGesture();
  gesture.anchor = c; gesture.last = c; gesture.slot = slot;
  const cells = applyMirror([[c.x, c.y]]);
  gesture.changed = paintCells(cells, slot) || gesture.changed;
  Canvas.render(); setStatus();
}

function onMove(e) {
  const c = cellAt(e);
  const moved = !hover || !c || c.x !== hover.x || c.y !== hover.y;
  hover = c;
  if (!c) { setStatus(); return; }
  if (!gesture) { if (moved) { Canvas.render(); setStatus(); } return; }
  const trait = PSP.currentTrait();
  if (!trait) return;
  const ed = PSP.ui().editor;
  if (ed.tool === 'line' || ed.tool === 'rect') {
    gesture.last = c;
    const raw = ed.tool === 'line' ? lineCells(gesture.anchor, c) : rectCells(gesture.anchor, c);
    linePreview = applyMirror(raw);
    Canvas.render(); setStatus();
    return;
  }
  // pencil/eraser: interpolate from last to current
  if (moved) {
    const cells = applyMirror(lineCells(gesture.last, c));
    gesture.changed = paintCells(cells, gesture.slot) || gesture.changed;
    gesture.last = c;
    Canvas.render(); setStatus();
  }
}

function onUp(e) {
  if (!gesture) return;
  const c = cellAt(e) || gesture.last;
  const trait = PSP.currentTrait();
  const ed = PSP.ui().editor;
  if (trait && (ed.tool === 'line' || ed.tool === 'rect')) {
    const raw = ed.tool === 'line' ? lineCells(gesture.anchor, c) : rectCells(gesture.anchor, c);
    gesture.changed = paintCells(applyMirror(raw), gesture.slot) || gesture.changed;
  }
  endGesture();
  Canvas.render(); setStatus();
}
function onCancel() { endGesture(); Canvas.render(); }

/* ── keyboard (called from app-boot.js) ────────────────── */
Canvas.onKey = function (e) {
  const map = { b: 'pencil', e: 'eraser', g: 'fill', l: 'line', r: 'rect', i: 'picker' };
  const k = e.key.toLowerCase();
  if (map[k]) { setTool(map[k]); return true; }
  if (k === 'm') {
    PSP.ui().editor.mirror = !PSP.ui().editor.mirror;
    PSP.$('btn-mirror').classList.toggle('on', PSP.ui().editor.mirror);
    Canvas.render(); setStatus(); PSP.persistSoon();
    return true;
  }
  return false;
};

})();
