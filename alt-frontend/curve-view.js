import { createCurve, sampleCurve, priceAt } from './curve.js';

const compact = (value, digits = 4) => {
  if (!Number.isFinite(value)) return 'unavailable';
  if (value === 0) return '0';
  if (Math.abs(value) < 0.0001 || Math.abs(value) >= 1e7) return value.toExponential(2);
  return value.toLocaleString('en-US', { maximumFractionDigits: digits });
};
const xy = value => Number(value.toFixed(3));

/** Render the protocol curve at the local demo reserve. No wallet quote is implied. */
export function renderCurve(boot, reserve, flat = false) {
  const curve = createCurve(boot);
  const data = sampleCurve(curve, reserve);
  const points = data.points.filter(p => p.reserve >= 1 && p.price > 0);
  if (!points.length) return '<section class="chart-panel"><h3>curve unavailable.</h3><p>the demo reserve is outside the supported chart range.</p></section>';
  const xMin = Math.min(10, points[0].reserve), xMax = data.end;
  const live = data.livePoint;
  const flatPrice = live?.supply > 0 ? reserve / live.supply : null;
  const flatLine = flat && flatPrice > 0;
  const yMin = Math.log10(Math.min(points[0].price, flatLine ? flatPrice : Infinity));
  const yMax = Math.log10(Math.max(points.at(-1).price, flatLine ? flatPrice : 0));
  const yLo = Math.floor(yMin), yHi = Math.max(yLo + 1, Math.ceil(yMax));
  const sx = r => (Math.log10(r) - Math.log10(xMin)) / (Math.log10(xMax) - Math.log10(xMin)) * 1000;
  const sy = price => (yHi - Math.log10(price)) / (yHi - yLo) * 300;
  const visible = [{reserve:xMin,price:priceAt(curve,xMin)},...points.filter(p => p.reserve > xMin)];
  const path = flatLine ? `M0 ${xy(sy(flatPrice))}H1000` : visible.map((p,i)=>`${i?'L':'M'}${xy(sx(p.reserve))} ${xy(sy(p.price))}`).join('');
  const xTicks = [];
  for(let exponent=Math.ceil(Math.log10(xMin));exponent<=Math.floor(Math.log10(xMax));exponent++)xTicks.push(10**exponent);
  const yTicks = [];
  for(let exponent=yLo;exponent<=yHi;exponent+=Math.max(1,Math.ceil((yHi-yLo)/5)))yTicks.push(10**exponent);
  const marker = live && reserve>=xMin && reserve<=xMax;
  const markerPrice = flatLine ? flatPrice : live?.price;
  return `<section class="chart-panel actual-curve" aria-label="PSP bonding curve"><div class="chart-head"><h3>${flatLine?'the curve is flat.':'the bonding curve.'}</h3><span>${flatLine?'proportional redemption':'tilted sine'} · log scales</span></div><div class="curve-readout"><span>demo reserves <strong>${compact(reserve,4)} mixETH</strong></span><span>${flatLine?'backing per PSP':'marginal price'} <strong>${compact(markerPrice,8)} mixETH / PSP</strong></span></div><div class="curve-axis-title">price · mixETH / PSP</div><div class="curve-plot"><div class="curve-y-axis">${yTicks.map(v=>`<span style="top:${xy(sy(v)/3)}%">${compact(v,6)}</span>`).join('')}</div><div class="curve-drawing"><svg class="actual-curve-svg" viewBox="0 0 1000 300" preserveAspectRatio="none" role="img" aria-label="${flatLine?'Flat redemption price':'PSP price against mixETH reserves, calculated from the project’s tilted-sine curve'}"><defs><linearGradient id="actual-curve-fill" x1="0" y1="0" x2="0" y2="1"><stop offset="0%" stop-color="var(--amber)" stop-opacity=".15"/><stop offset="100%" stop-color="var(--amber)" stop-opacity="0"/></linearGradient></defs>${yTicks.map(v=>`<line class="gridline" x1="0" x2="1000" y1="${xy(sy(v))}" y2="${xy(sy(v))}"/>`).join('')}${xTicks.map(v=>`<line class="gridline" x1="${xy(sx(v))}" x2="${xy(sx(v))}" y1="0" y2="300"/>`).join('')}<path class="actual-curve-area" d="${path}L1000 300L0 300Z"/><path class="actual-curve-line" d="${path}"/>${marker?`<line class="curve-position-guide" x1="${xy(sx(reserve))}" x2="${xy(sx(reserve))}" y1="${xy(sy(markerPrice))}" y2="300"/>`:''}</svg>${marker?`<span class="curve-position-dot" title="demo reserve: ${compact(reserve)} mixETH" style="left:${xy(sx(reserve)/10)}%;top:${xy(sy(markerPrice)/3)}%"></span>`:''}<div class="curve-x-axis">${xTicks.map(v=>`<span style="left:${xy(sx(v)/10)}%">${compact(v,0)}</span>`).join('')}</div></div></div><div class="curve-bottom-line"><span>${flatLine?'after detonation':'launch reserve: '+compact(boot)+' mixETH'}</span><span>reserves · mixETH</span></div><p class="chart-caption">${data.truncated?'the curve exceeds the chart’s numeric range. the plot stops at the last supported price.':flatLine?'PSP redeems for its share of remaining backing. payouts round down and can return less than you paid.':'the project’s curve formula and default parameters, applied to this demo round. the marker follows your simulated buys.'}</p></section>`;
}
