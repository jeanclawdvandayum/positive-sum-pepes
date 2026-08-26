/// curveMath.mjs — BYTE-EXACT JS port of solady FixedPointMathLib (mulWad, divWad,
/// expWad, lnWad) + CurveMath (marginalPrice, curveIntegral, zone walks).
/// Generated for the rolling-curves work (psp-rolling.py, 2026-08-22). Every
/// operation mirrors EVM semantics: 256-bit wrapping, truncation-toward-zero
/// division, arithmetic (sign-propagating) right shifts. Referee-tested against
/// forge CSV dumps (test/CurveDumpRolling.t.sol) — see curveMath.referee.mjs.
/// Kept as .mjs so `node` can run the referee without a TS build; the vite app
/// imports the identical file (types in curveMath.d.mts).

// ── EVM integer helpers ────────────────────────────────────────────────────
const U0 = 0n;
const U255 = (1n << 255n) - 1n;
const U256 = 1n << 256n;

function u(x) { const v = BigInt.asUintN(256, x); return v; } // canonical uint256
function sx(x) { return BigInt.asIntN(256, x); } // canonical int256
function shru(x, n) { return u(x) >> n; } // unsigned shift (input canonicalized)
function sar(x, n) { return sx(x) >> n; } // arithmetic shift
function mul256(a, b) { return u(a * b); }
function add256(a, b) { return u(a + b); }
function smul(a, b) { return sx(sx(a) * sx(b)); } // wraps like EVM mul on int256
function sadd(a, b) { return sx(sx(a) + sx(b)); }
function sdiv(a, b) { return sx(sx(a) / sx(b)); } // BigInt / truncates toward zero — matches EVM

// ── solady FixedPointMathLib ───────────────────────────────────────────────
const WAD = 1000000000000000000n; // 1e18

/// uint256 (x * y) / WAD, floored. (solady mulWad)
export function mulWad(x, y) { return (u(x) * u(y)) / WAD; }

/// uint256 (x * WAD) / y, floored. (solady divWad)
export function divWad(x, y) { return (u(x) * WAD) / u(y); }

/// int256 exp(x / 1e18) * 1e18. (solady expWad, (6,7)-term rational approx)
/// Throws beyond solady's domain; CurveMath caps inputs before calling.
export function expWad(x) {
  x = sx(x);
  if (x <= -41446531673892822313n) return 0n; // result < 1 wei
  if (!(x < 135305999368893231589n)) throw new Error("ExpOverflow");
  // Base conversion 1e18 -> 2**96: x = (x << 78) / 5**18 (EVM division truncates
  // toward zero; BigInt division matches for negatives).
  x = sx(sx(x << 78n) / (5n ** 18n));
  // Range-reduce to (-½ln2, ½ln2)·2**96 by k = round(x / ln2).
  const LN2_96 = 54916777467707473351141471128n;
  let k = sx((sx(x << 96n) / LN2_96 + (1n << 95n)) >> 96n);
  x = sadd(x, smul(k, -LN2_96)); // x - k*ln2
  // (6,7)-term rational approximation in 2**96 basis (p left in 2**192 basis).
  let y = sadd(x, 1346386616545796478920950773328n);
  y = sadd(sar(smul(y, x), 96n), 57155421227552351082224309758442n);
  let p = sadd(sadd(y, x), -94201549194550492254356042504812n);
  p = sadd(sar(smul(p, y), 96n), 28719021644029726153956944680412240n);
  p = sadd(smul(p, x), sx(4385272521454847904659076985693276n << 96n));
  let q = sadd(x, -2855989394907223263936484059900n);
  q = sadd(sar(smul(q, x), 96n), 50020603652535783019961831881945n);
  q = sadd(sar(smul(q, x), 96n), -533845033583426703283633433725380n);
  q = sadd(sar(smul(q, x), 96n), 3604857256930695427073651918091429n);
  q = sadd(sar(smul(q, x), 96n), -14423608567350463180887372962807573n);
  q = sadd(sar(smul(q, x), 96n), 26449188498355588339934803723976023n);
  let r = sdiv(p, q); // r in (0.09, 0.25)·2**96
  // Scale · 2**k · 1e18/2**96, intermediate in 2**213 basis (unsigned shift).
  r = sx(shru(mul256(u(r), 3822833074963236453042738258902158003155416615667n), u(sx(BigInt(195) - k))));
  return r;
}

/// int256 ln(x / 1e18) * 1e18 for x > 0. (solady lnWad, (8,8)-term rational approx)
export function lnWad(x) {
  x = sx(x);
  if (x <= 0n) throw new Error("LnWadUndefined");
  // r = 255 - floorLog2(x); reduce x to (1, 2)·2**96.
  let r = 255n - BigInt(BigInt(u(x)).toString(2).length - 1);
  x = sx(shru(shl256(u(x), u(r)), 159n));
  // (8,8)-term rational approximation (p monic, left in 2**192 basis).
  let t = sar(smul(sadd(x, 3273285459638523848632254066296n), x), 96n);
  t = sar(smul(sadd(t, 24828157081833163892658089445524n), x), 96n);
  t = sar(smul(sadd(t, 43456485725739037958740375743393n), x), 96n);
  let p = sadd(t, -11111509109440967052023855526967n);
  p = sadd(sar(smul(p, x), 96n), -45023709667254063763336534515857n);
  p = sadd(sar(smul(p, x), 96n), -14706773417378608786704636184526n);
  p = sadd(smul(p, x), -(795164235651350426258249787498n << 96n));
  let q = sadd(x, 5573035233440673466300451813936n);
  q = sadd(sar(smul(x, q), 96n), 71694874799317883764090561454958n);
  q = sadd(sar(smul(x, q), 96n), 283447036172924575727196451306956n);
  q = sadd(sar(smul(x, q), 96n), 401686690394027663651624208769553n);
  q = sadd(sar(smul(x, q), 96n), 204048457590392012362485061816622n);
  q = sadd(sar(smul(x, q), 96n), 31853899698501571402653359427138n);
  q = sadd(sar(smul(x, q), 96n), 909429971244387300277376558375n);
  p = sdiv(p, q);
  // Scale by s = 5.549…, add ln(2)·k and ln(2**96/1e18); all in 5**18·2**192 basis.
  p = smul(p, 1677202110996718588342820967067443963516166n);
  p = sadd(smul(16597577552685614221487285958193947469193820559219878177908093499208371n, sx(BigInt(159) - r)), p);
  p = sadd(p, 600920179829731861736702779321621459595472258049074101567377883020018308n);
  return sar(p, 174n);
}
function shl256(x, n) { return u(x << n); }

// ── CurveMath ──────────────────────────────────────────────────────────────
const MAX_SUPPLY = 10000000000000000000000000000n; // 1e28
const EXP_INPUT_CAP = 135305999368893231588n; // CurveMath._expPrice cap

/// Exponential zone price walk step: pStart * e^(k·delta).
function _expPrice(pStart, k, delta) {
  if (delta === 0n) return pStart;
  let expInput = mulWad(k, delta);
  if (expInput > EXP_INPUT_CAP) expInput = EXP_INPUT_CAP;
  const ePow = expWad(sx(expInput));
  return mulWad(pStart, u(ePow));
}

/// Log zone price walk step: pStart * (1 + k·max(ln(s/sStart), 0)).
function _logPrice(pStart, k, s, sStart) {
  if (s === sStart) return pStart;
  const sCapped = s > MAX_SUPPLY ? MAX_SUPPLY : s;
  const ratio = divWad(sCapped, sStart);
  const lnRatio = lnWad(sx(ratio));
  const lnAbs = lnRatio > 0n ? u(lnRatio) : U0;
  const growthFactor = WAD + mulWad(k, lnAbs);
  return mulWad(pStart, growthFactor);
}

/// Marginal price at supply S (wad). Mirrors CurveMath.marginalPrice.
export function marginalPrice(S, cc) {
  if (S === 0n) return cc.P0;
  let price = cc.P0;
  for (const z of cc.zones) {
    if (S <= z.startSupply) break;
    const zoneEnd = z.endSupply;
    const evalPoint = S < zoneEnd ? S : zoneEnd;
    if (z.isExponential) {
      price = _expPrice(price, z.rate, evalPoint - z.startSupply);
    } else {
      price = _logPrice(price, z.rate, evalPoint, z.startSupply);
    }
    if (S <= zoneEnd) break;
  }
  return price;
}

/// ∫_{S1}^{S2} P(s) ds (wad). Mirrors CurveMath.curveIntegral — telescoping F-form.
export function curveIntegral(S1, S2, cc) {
  if (S1 >= S2) return 0n;
  let total = 0n;
  let price = cc.P0;
  for (const z of cc.zones) {
    if (z.endSupply <= S1) {
      // Advance price to zone end.
      if (z.isExponential) price = _expPrice(price, z.rate, z.endSupply - z.startSupply);
      else price = _logPrice(price, z.rate, z.endSupply, z.startSupply);
      continue;
    }
    if (z.startSupply >= S2) break;
    const segStart = S1 > z.startSupply ? S1 : z.startSupply;
    const segEnd = S2 < z.endSupply ? S2 : z.endSupply;
    if (z.isExponential) {
      total += _integralExp(price, z.rate, segStart, segEnd, z.startSupply);
    } else {
      total += _integralLog(price, z.rate, segStart, segEnd, z.startSupply);
    }
    if (S2 <= z.endSupply) break;
    if (z.isExponential) price = _expPrice(price, z.rate, z.endSupply - z.startSupply);
    else price = _logPrice(price, z.rate, z.endSupply, z.startSupply);
  }
  return total;
}

/// F(s) = mulWad(divWad(pZoneStart, k), expWad(k·(s - sZoneStart))) telescoped.
function _integralExp(pZoneStart, k, segStart, segEnd, sZoneStart) {
  if (segEnd - segStart === 0n) return 0n;
  if (k === 0n) return mulWad(pZoneStart, segEnd) - mulWad(pZoneStart, segStart);
  const pOverK = divWad(pZoneStart, k);
  let expEnd = mulWad(k, segEnd - sZoneStart);
  if (expEnd > EXP_INPUT_CAP) expEnd = EXP_INPUT_CAP;
  let expStart = mulWad(k, segStart - sZoneStart);
  if (expStart > EXP_INPUT_CAP) expStart = EXP_INPUT_CAP;
  const fEnd = mulWad(pOverK, u(expWad(sx(expEnd))));
  const fStart = mulWad(pOverK, u(expWad(sx(expStart))));
  if (fEnd <= fStart) return 0n;
  return fEnd - fStart;
}

/// F(s) = mulWad(s, 1-k) + mulWad(mulWad(k, s), ln(s/s0)) telescoped.
function _integralLog(pZoneStart, k, segStart, segEnd, sZoneStart) {
  if (segEnd - segStart === 0n) return 0n;
  const lnEnd = lnWad(sx(divWad(segEnd, sZoneStart)));
  const lnStart = lnWad(sx(divWad(segStart, sZoneStart)));
  const F_end = sadd(sx(mulWad(segEnd, WAD - k)), sx(mulWad(mulWad(k, segEnd), u(lnEnd))));
  const F_start = sadd(sx(mulWad(segStart, WAD - k)), sx(mulWad(mulWad(k, segStart), u(lnStart))));
  if (F_end <= F_start) return 0n;
  return mulWad(pZoneStart, u(F_end - F_start));
}

// ── config assembly (from generator sidecar / on-chain zones) ──────────────
export const MAX_SUPPLY_WAD = MAX_SUPPLY;
export const UINT256_MAX = U256 - 1n;

/// Assemble a CurveConfig from parallel arrays (bounds, rates 1e18, isExponential
/// flags) + P0 (1e18) — the shape emitted by psp-rolling.py's curveConfigs.json
/// and by CurveHook.getCurveZones() on chain.
export function makeConfig(p0, bounds, rates, exps) {
  const n = bounds.length;
  const zones = [];
  for (let i = 0; i < n; i++) {
    zones.push({
      startSupply: bounds[i],
      endSupply: i + 1 < n ? bounds[i + 1] : UINT256_MAX,
      rate: rates[i],
      isExponential: exps[i],
    });
  }
  return { P0: p0, zones };
}
