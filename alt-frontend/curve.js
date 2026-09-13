/** Display math for the local prototype, in human mixETH and PSP units.
 * Formula and defaults: src/libraries/SineMath.sol and script/DeploymentSupport.sol.
 * JavaScript estimates are not fixed-point contract quotes or transaction minimums.
 */
export const DEFAULT_CURVE = Object.freeze({
  p0: 0.00001,
  preK: 0.004477562267871699,
  referenceBoot: 450,
  pTarget: 0.06,
  targetReserve: 10_000,
  ampBps: 10_000,
});

const TAU = 2 * Math.PI;
const EXP_LIMIT = 135.30599936889323;
// The same eight Gauss–Legendre nodes and weights as SineMath.
const NODES = [0.019855071751231912, 0.10166676129318664, 0.23723379504183552,
  0.40828267875217504, 0.5917173212478249, 0.7627662049581645,
  0.8983332387068133, 0.9801449282487681];
const WEIGHTS = [0.050614268145188264, 0.11119051722668723, 0.15685332293894358,
  0.1813418916891809, 0.1813418916891809, 0.15685332293894358,
  0.11119051722668723, 0.050614268145188264];

/** Materialize the launch seam from the post-fee pooled reserve. */
export function createCurve(boot = 900) {
  if (!Number.isFinite(boot) || boot <= 0) {
    throw new RangeError('Invalid launch reserve');
  }
  const { p0, pTarget, ampBps, referenceBoot } = DEFAULT_CURVE;
  const preK = DEFAULT_CURVE.preK * referenceBoot / boot;
  const targetReserve = DEFAULT_CURVE.targetReserve * boot / referenceBoot;
  const lam = (targetReserve - boot) / 3;
  const B = p0 * Math.exp(preK * boot);
  const ratio = pTarget / B;
  if (!Number.isFinite(B) || ratio < 1 + 0.01 / 3) {
    throw new RangeError('Launch reserve exceeds the configured curve range');
  }
  const slope = Math.log(ratio) / (3 * lam);
  const amp = ampBps / 10_000 * slope * lam / TAU;
  const g = Math.exp(slope * lam);
  const q0 = -Math.expm1(-preK * boot) / (preK * p0);
  // Match the existing frontend's guard, below the contract's expWad limit.
  const numericEnd = boot + (Math.min(135, 600 - Math.log(B)) - Math.abs(amp)) / slope;
  if (![targetReserve, q0, numericEnd].every(Number.isFinite)) throw new RangeError('Curve exceeds the display range');
  const curve = { p0, preK, pTarget, targetReserve, ampBps, boot, lam, B, slope, amp, g, q0, numericEnd };
  curve.W = waveSupply(curve, lam);
  return Object.freeze(curve);
}

/** Marginal mixETH price per PSP. Unsupported values return null, never Infinity. */
export function priceAt(curve, reserve) {
  if (!Number.isFinite(reserve) || reserve < 0) return null;
  const arg = reserve <= curve.boot ? curve.preK * reserve
    : curve.slope * (reserve - curve.boot)
      - curve.amp * Math.sin(TAU * ((reserve - curve.boot) % curve.lam) / curve.lam);
  if (!Number.isFinite(arg) || arg > EXP_LIMIT) return null;
  const price = (reserve <= curve.boot ? curve.p0 : curve.B) * Math.exp(arg);
  return Number.isFinite(price) && price > 0 ? price : null;
}

function gl8(curve, left, right) {
  const width = right - left;
  let sum = 0;
  for (let i = 0; i < NODES.length; i++) {
    const price = priceAt(curve, left + width * NODES[i]);
    if (price === null) return null;
    sum += WEIGHTS[i] / price;
  }
  return width * sum;
}

function waveSupply(curve, distance) {
  let left = curve.boot, total = 0;
  const end = curve.boot + distance;
  for (let cell = 1; cell <= 4 && left < end; cell++) {
    const right = Math.min(end, curve.boot + curve.lam * cell / 4);
    total += gl8(curve, left, right);
    left = right;
  }
  return total;
}

/** Canonical four-cell GL8 supply integral, with whole-wave geometric endpoints. */
export function supplyAt(curve, reserve) {
  if (!Number.isFinite(reserve) || reserve < 0 || reserve > curve.numericEnd) return null;
  if (reserve <= curve.boot) return -Math.expm1(-curve.preK * reserve) / (curve.preK * curve.p0);
  const distance = reserve - curve.boot;
  const waveIndex = distance / curve.lam;
  const waves = Math.floor(waveIndex);
  const inverseGrowth = 1 / curve.g;
  const decay = Math.pow(inverseGrowth, waves);
  const completed = curve.W * -Math.expm1(waves * Math.log(inverseGrowth)) / (1 - inverseGrowth);
  // Derive both parts from the same quotient. Mixing floor(division) and %
  // can count an extra wave when floating-point arithmetic lands on a seam.
  const partial = waveSupply(curve, (waveIndex - waves) * curve.lam);
  return curve.q0 + completed + partial * decay;
}

/** Estimate net-reserve spend with direct integration to preserve small buy amounts.
 * The contract also shaves one wei and one basis point from the PSP output.
 * The one-wei adjustment is below the display precision of these Number estimates.
 */
export function estimateBuy(curve, reserve, netMix) {
  if (![reserve, netMix].every(Number.isFinite) || reserve < 0 || netMix < 0) return null;
  if (reserve > curve.numericEnd) return null;
  if (netMix === 0) return 0;
  const end = reserve + netMix;
  if (!Number.isFinite(end) || end > curve.numericEnd || end <= reserve) return null;
  let left = reserve, total = 0;
  if (left < curve.boot) {
    const right = Math.min(end, curve.boot);
    total += Math.exp(-curve.preK * left) * -Math.expm1(-curve.preK * (right - left))
      / (curve.preK * curve.p0);
    left = right;
  }
  // At most 8,192 price evaluations, even for extreme demo amounts.
  const cells = Math.ceil((end - left) / (curve.lam / 4));
  if (cells > 1024) return null;
  for (let cell = 0; cell < cells; cell++) {
    const a = left + (end - left) * cell / cells;
    const b = left + (end - left) * (cell + 1) / cells;
    const part = gl8(curve, a, b);
    if (part === null) return null;
    total += part;
  }
  const result = Math.max(0, total - 1e-18) * 0.9999;
  return Number.isFinite(result) ? result : null;
}

/** Bounded geometry with the same headroom and exponent guard as sineChart.ts. */
export function sampleCurve(curve, liveReserve = 0) {
  if (!Number.isFinite(liveReserve) || liveReserve < 0) throw new RangeError('Invalid live reserve');
  const headroom = liveReserve + Math.max(1000, curve.lam, liveReserve * 0.1);
  const waves = Math.max(4, Math.ceil((Math.max(curve.targetReserve, headroom) - curve.boot) / curve.lam));
  const requestedEnd = curve.boot + waves * curve.lam;
  const end = Math.min(requestedEnd, curve.numericEnd);
  const truncated = end < requestedEnd;
  const reserves = new Set([0, curve.boot, Math.min(curve.targetReserve, end), end]);
  for (let i = 1; i <= 64; i++) reserves.add(curve.boot * i / 64);
  const steps = Math.min(8192, Math.ceil((end - curve.boot) / curve.lam) * 128);
  for (let i = 1; i <= steps; i++) reserves.add(curve.boot + (end - curve.boot) * i / steps);
  if (liveReserve <= end) reserves.add(liveReserve);
  const point = reserve => ({ reserve, price: priceAt(curve, reserve), supply: supplyAt(curve, reserve) });
  const points = [...reserves].sort((a, b) => a - b).map(point);
  const markers = [{ reserve: curve.boot, price: curve.B, kind: 'boot', k: 0 }];
  for (let k = 1; k <= 12; k++) {
    const reserve = curve.boot + curve.lam * k / 4;
    if (reserve > end) break;
    markers.push({ reserve, price: priceAt(curve, reserve), kind: k % 4 === 0 ? 'top' : 'anchor', k });
  }
  return { points, markers, boot: curve.boot, top: curve.targetReserve,
    span: curve.targetReserve - curve.boot, end, truncated,
    livePoint: liveReserve <= end ? point(liveReserve) : null };
}
