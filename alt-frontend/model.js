/** Local design demo. These values do not quote or send a blockchain transaction. */
import { createCurve, estimateBuy } from './curve.js';

export const WEIGHTS = Object.freeze([25, 18, 14, 10, 8, 7, 6, 5, 4, 3]);
export const MIN_BUY = 5_000_000_000_000_000n;
const WAD = 10n ** 18n;
const UINT_MAX = (1n << 256n) - 1n;
export const MAX_SECONDS = 248_660;
export const IBCO_SECONDS = 3 * 24 * 60 * 60;

export function parseAmount(value) {
  if (typeof value !== 'string') return 0n;
  const text = value.trim();
  if (text.length > 100 || !/^(?:\d+(?:\.\d{0,18})?|\.\d{1,18})$/.test(text)) return 0n;
  const [whole = '0', fraction = ''] = text.split('.');
  const amount = BigInt(whole || '0') * WAD + BigInt(fraction.padEnd(18, '0'));
  return amount <= UINT_MAX ? amount : 0n;
}

function unsigned(value) {
  return typeof value === 'bigint' && value >= 0n && value <= UINT_MAX ? value : 0n;
}

function count(value, maximum) {
  return Number.isFinite(value) ? Math.min(maximum, Math.max(0, Math.floor(value))) : 0;
}

export function formatAmount(amount, decimals = 4) {
  const value = unsigned(amount);
  const precision = count(decimals, 18);
  const whole = value / WAD;
  if (precision === 0) return String(whole);
  const fraction = String(value % WAD).padStart(18, '0').slice(0, precision).replace(/0+$/, '');
  return `${whole}${fraction ? `.${fraction}` : ''}`;
}

export function ticketPrice(potWei, genesisPotWei) {
  const pot = unsigned(potWei);
  const genesis = unsigned(genesisPotWei);
  const growth = pot > genesis ? pot - genesis : 0n;
  return MIN_BUY + growth * 21n / 1_000_000n;
}

export function feeBps(reserveWei, bootWei = 900n * WAD) {
  const reserve = unsigned(reserveWei), boot = unsigned(bootWei);
  const target = boot * 10_000n / 450n;
  if (boot === 0n || reserve <= boot) return 1000;
  if (reserve >= target) return 250;
  return Number(1000n - 750n * (reserve - boot) / (target - boot));
}

function payout(pot, ranks, occupied) {
  const denominator = WEIGHTS.slice(0, occupied).reduce((sum, weight) => sum + weight, 0);
  if (!denominator) return { shareBps: 0, claim: 0n };
  const weight = ranks.reduce((sum, rank) => sum + WEIGHTS[rank - 1], 0);
  const claim = ranks.reduce((sum, rank) => sum + pot * BigInt(WEIGHTS[rank - 1]) / BigInt(denominator), 0n);
  return { shareBps: Math.floor(weight * 10_000 / denominator), claim };
}

export function previewBuy({ amount, pot, genesisPot, reserve, holders, remaining, laterSeats = 0, board, userName, bootReserve }) {
  const beforePot = unsigned(pot);
  const price = ticketPrice(beforePot, genesisPot);
  const seconds = count(remaining, MAX_SECONDS);
  const supplied = unsigned(amount);
  const gross = supplied >= MIN_BUY && seconds > 0 ? supplied : 0n;
  const tickets = gross / price;
  const seats = Number(tickets > 10n ? 10n : tickets);
  const existing = Array.isArray(board) && typeof userName === 'string' && userName.length > 0
    ? board.slice(0, 10).map(entry => entry?.name === userName)
    : Array(count(holders, 10)).fill(false);
  const owners = [...Array(seats).fill(true), ...existing].slice(0, 10);
  const ownedRanks = owners.flatMap((owned, index) => owned ? [index + 1] : []);
  const occupied = owners.length;
  const occupiedRanks = Array.from({ length: seats }, (_, index) => index + 1);
  const bootWei = bootReserve === undefined ? unsigned(genesisPot) * 9n
    : Number.isFinite(bootReserve * 1e18) && bootReserve > 0
      && bootReserve * 1e18 <= Number(UINT_MAX) ? BigInt(Math.floor(bootReserve * 1e18)) : 0n;
  const fee = gross * BigInt(feeBps(reserve, bootWei || 900n * WAD)) / 10_000n;
  // The real curve formula runs locally with this demo round's launch reserve.
  // Conversion happens only after rejecting unsupported or nonfinite estimates.
  let pspOut = 0n, quoteAvailable = true;
  if (gross > 0n) {
    quoteAvailable = false;
    const genesis = unsigned(genesisPot);
    const boot = bootReserve ?? (genesis > 0n ? Number(genesis) * 9 / 1e18 : 900);
    try {
      if (typeof reserve !== 'bigint' || reserve < 0n || reserve > UINT_MAX) throw new RangeError('Invalid reserve');
      const estimate = estimateBuy(createCurve(boot), Number(reserve) / 1e18, Number(gross - fee) / 1e18);
      const scaled = estimate === null ? NaN : estimate * 1e18;
      if (Number.isFinite(scaled) && scaled >= 0 && scaled <= Number(UINT_MAX)) {
        const wei = BigInt(Math.floor(scaled));
        if (wei <= UINT_MAX) {
          pspOut = wei;
          quoteAvailable = true;
        }
      }
    } catch { /* Unsupported demo state stays visible with an unavailable quote. */ }
  }
  // Unattributed trade: 60% to stakers, 1% to deployer, remainder to pot.
  const potAdded = fee - fee * 6000n / 10_000n - fee * 100n / 10_000n;
  const nextPot = beforePot + potAdded;
  const headroom = MAX_SECONDS - seconds;
  const rawTime = tickets * 69n;
  const timeAdded = Number(rawTime > BigInt(headroom) ? BigInt(headroom) : rawTime);
  const current = payout(nextPot, ownedRanks, occupied);
  const shift = count(laterSeats, 10);
  const afterRanks = ownedRanks.map(rank => rank + shift).filter(rank => rank <= 10);
  // Hold the pot fixed to isolate displacement. Future trades can also add fees.
  const after = payout(nextPot, afterRanks, Math.min(10, occupied + shift));
  return {
    tickets, seats, timeAdded, price, fee, pspOut, quoteAvailable, potAdded, nextPot,
    shareBps: current.shareBps, claim: current.claim,
    afterShareBps: after.shareBps, afterClaim: after.claim,
    occupiedRanks,
  };
}

export function initialState() {
  const board = [
    { name: 'bagholder', pepe: 0, age: '12s' },
    { name: 'anon pepe 0x43de', pepe: 3, age: '28s' },
    { name: 'frogfather', pepe: 5, age: '41s' },
    { name: 'anon pepe 0x8a21', pepe: 8, age: '1m' },
    { name: 'bagholder', pepe: 0, age: '2m' },
    { name: 'ribbitmaxi', pepe: 10, age: '3m' },
    { name: 'anon pepe 0xd120', pepe: 2, age: '3m' },
    { name: 'moonintern', pepe: 9, age: '4m' },
    { name: 'anon pepe 0x71ba', pepe: 6, age: '5m' },
    { name: 'frogfather', pepe: 5, age: '7m' },
  ];
  return {
    pot: parseAmount('128.42'),
    genesisPot: parseAmount('100'),
    reserve: parseAmount('1248.36'),
    bootReserve: 900,
    remaining: 8078,
    board,
    trades: [
      { name: 'bagholder', pepe: 0, age: '12s', side: 'buy', amount: parseAmount('0.01'), tickets: 1, seconds: 69 },
      { name: 'anon pepe 0x43de', pepe: 3, age: '28s', side: 'buy', amount: parseAmount('0.01'), tickets: 1, seconds: 69 },
      { name: 'paperhands', pepe: 11, age: '34s', side: 'sell', amount: parseAmount('0.42'), tickets: 0, seconds: 0 },
      { name: 'frogfather', pepe: 5, age: '41s', side: 'buy', amount: parseAmount('0.01'), tickets: 1, seconds: 69 },
    ],
  };
}
