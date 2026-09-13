import test from 'node:test';
import assert from 'node:assert/strict';
import { MIN_BUY, WEIGHTS, parseAmount, formatAmount, ticketPrice, feeBps, previewBuy, initialState } from './model.js';

const mix = parseAmount;
const params = { amount: MIN_BUY, pot: mix('100'), genesisPot: mix('100'), reserve: mix('500'), holders: 10, remaining: 8000 };

test('amounts retain wei precision and reject malformed inputs', () => {
  assert.equal(mix('0.000000000000000001'), 1n);
  assert.equal(mix('.005'), MIN_BUY);
  assert.equal(mix('1.'), mix('1'));
  for (const input of ['', 'NaN', 'Infinity', '-1', '1e9', '1,000', '0.0000000000000000001', '9'.repeat(1000)]) assert.equal(mix(input), 0n);
  assert.equal(formatAmount(mix('1000.123456'), 4), '1000.1234');
  assert.equal(formatAmount(mix('0.005')), '0.005');
  assert.equal(formatAmount(1n, 18), '0.000000000000000001');
});

test('ticket growth is linear and includes fractional mixETH', () => {
  assert.equal(ticketPrice(mix('100'), mix('100')), MIN_BUY);
  assert.equal(ticketPrice(mix('99'), mix('100')), MIN_BUY);
  assert.equal(ticketPrice(mix('200'), mix('100')), mix('0.0071'));
  assert.equal(ticketPrice(mix('1100'), mix('100')), mix('0.026'));
  assert.equal(ticketPrice(mix('100.5'), mix('100')), mix('0.0050105'));
});

test('fee scale meets both boundaries and the midpoint', () => {
  assert.equal(feeBps(mix('0')), 1000);
  assert.equal(feeBps(mix('900')), 1000);
  assert.equal(feeBps(mix('10450')), 625);
  assert.equal(feeBps(mix('20000')), 250);
  assert.equal(feeBps(mix('10000000')), 250);
});

test('each full ticket adds 69 seconds within the maximum clock', () => {
  assert.equal(previewBuy(params).timeAdded, 69);
  assert.equal(previewBuy({ ...params, amount: mix('.05') }).timeAdded, 690);
  assert.equal(previewBuy({ ...params, remaining: 248640 }).timeAdded, 20);
  assert.equal(previewBuy({ ...params, remaining: 248660 }).timeAdded, 0);
  assert.equal(previewBuy({ ...params, remaining: 0 }).tickets, 0n);
});

test('a valid sub-ticket buy pays fees but earns zero seats and time', () => {
  const result = previewBuy({ ...params, pot: mix('200') });
  assert.equal(result.tickets, 0n);
  assert.equal(result.seats, 0);
  assert.equal(result.timeAdded, 0);
  assert.equal(result.claim, 0n);
  assert.equal(result.fee, mix('.0005'));
  assert.equal(result.potAdded, mix('.000195'));
  assert.equal(previewBuy({ ...params, amount: MIN_BUY - 1n }).fee, 0n);
});

test('one buy uses the price before its own fee changes the pot', () => {
  const price = ticketPrice(mix('200'), mix('100'));
  const result = previewBuy({ ...params, pot: mix('200'), amount: price * 10n });
  assert.equal(result.price, price);
  assert.equal(result.tickets, 10n);
  assert.equal(result.seats, 10);
  assert.ok(ticketPrice(result.nextPot, mix('100')) > price);
});

test('partial ladders renormalize and payouts floor each seat separately', () => {
  const one = previewBuy({ ...params, holders: 0 });
  assert.equal(one.shareBps, 10000);
  assert.equal(one.claim, one.nextPot);
  const two = previewBuy({ ...params, amount: mix('.01'), holders: 1 });
  assert.equal(two.shareBps, Math.floor(43 * 10000 / 57));
  assert.equal(two.claim, two.nextPot * 25n / 57n + two.nextPot * 18n / 57n);
});

test('later seats shift ranks and evict all ten while holding the pot fixed', () => {
  const one = previewBuy({ ...params, laterSeats: 1 });
  assert.equal(one.shareBps, 2500);
  assert.equal(one.afterShareBps, 1800);
  assert.equal(one.afterClaim, one.nextPot * 18n / 100n);
  const evicted = previewBuy({ ...params, laterSeats: 10 });
  assert.equal(evicted.afterShareBps, 0);
  assert.equal(evicted.afterClaim, 0n);
  const full = previewBuy({ ...params, amount: mix('.05'), laterSeats: 3 });
  assert.equal(full.afterShareBps, 4300);
  assert.deepEqual(full.occupiedRanks, [1,2,3,4,5,6,7,8,9,10]);
});

test('large values remain finite and iteration is capped at ten seats', () => {
  const result = previewBuy({ ...params, amount: mix('10000000') });
  assert.equal(result.tickets, 2_000_000_000n);
  assert.equal(result.seats, 10);
  assert.equal(result.timeAdded, 240660);
  assert.equal(result.shareBps, 10000);
  assert.equal(WEIGHTS.reduce((sum, value) => sum + value, 0), 100);
});

test('sample state is fresh and its names and art match the visible trade entries', () => {
  const first = initialState();
  const second = initialState();
  assert.equal(first.board.length, 10);
  assert.equal(first.pot, mix('128.42'));
  assert.equal(first.remaining, 8078);
  assert.ok(first.board.every(entry => entry.pepe >= 0 && entry.pepe < 12));
  first.board[0].name = 'changed';
  assert.equal(second.board[0].name, 'bagholder');
  assert.equal(second.trades[0].name, second.board[0].name);
});

test('a repeated purchase includes surviving tickets from the previous purchase', () => {
  const userName = 'you';
  const original = Array.from({ length: 10 }, (_, index) => ({ name: `other ${index}` }));
  const first = previewBuy({ ...params, board: original, userName });
  assert.equal(first.shareBps, 2500);
  const board = [{ name: userName }, ...original].slice(0, 10);
  const second = previewBuy({ ...params, pot: first.nextPot, amount: ticketPrice(first.nextPot, params.genesisPot), board, userName });
  assert.equal(second.tickets, 1n);
  assert.deepEqual(second.occupiedRanks, [1]);
  assert.equal(second.shareBps, 4300);
  assert.equal(second.claim, second.nextPot * 25n / 100n + second.nextPot * 18n / 100n);
  assert.equal(second.afterClaim, second.claim);
});

test('old tickets shift and drop out when another purchase fills the ladder', () => {
  const board = Array.from({ length: 10 }, (_, index) => ({ name: index === 8 || index === 9 ? 'you' : 'other' }));
  const result = previewBuy({ ...params, board, userName: 'you', laterSeats: 1 });
  // The new ticket occupies rank 1. Old rank 9 survives at rank 10, then expires on the next purchase.
  assert.equal(result.shareBps, 2800);
  assert.equal(result.claim, result.nextPot * 25n / 100n + result.nextPot * 3n / 100n);
  assert.equal(result.afterShareBps, 1800);
  assert.equal(result.afterClaim, result.nextPot * 18n / 100n);
  const full = previewBuy({ ...params, amount: mix('.05'), board, userName: 'you', laterSeats: 10 });
  assert.equal(full.shareBps, 10000);
  assert.equal(full.afterShareBps, 0);
  assert.equal(full.afterClaim, 0n);
});

test('a sub-ticket purchase retains old claims and partial boards use their actual size', () => {
  const result = previewBuy({ ...params, pot: mix('200'), board: [{ name: 'you' }], userName: 'you', laterSeats: 1 });
  assert.equal(result.tickets, 0n);
  assert.deepEqual(result.occupiedRanks, []);
  assert.equal(result.shareBps, 10000);
  assert.equal(result.claim, result.nextPot);
  assert.equal(result.afterShareBps, Math.floor(18 * 10000 / 43));
  assert.equal(result.afterClaim, result.nextPot * 18n / 43n);
});

test('the curve PSP estimate subtracts trading fees and retains fractional PSP', () => {
  const whole = previewBuy({ ...params, amount: mix('1') });
  // Independent Decimal integration of the pre-boot exponential, after the 1bps shave.
  assert.ok(Math.abs(Number(whole.pspOut) / 1e18 - 29350.565572241365) < 1e-8);
  const fractional = previewBuy({ ...params, amount: mix('.01') });
  assert.ok(Math.abs(Number(fractional.pspOut) / 1e18 - 293.798487849986) < 1e-8);
  assert.equal(whole.quoteAvailable, true);
  assert.equal(fractional.quoteAvailable, true);
  assert.equal(initialState().bootReserve, 900);
});

test('a valid buy below the ticket price still receives PSP', () => {
  const result = previewBuy({ ...params, pot: mix('200') });
  assert.equal(result.tickets, 0n);
  assert.ok(Math.abs(Number(result.pspOut) / 1e18 - 146.89998389431872) < 1e-8);
  assert.equal(result.quoteAvailable, true);
});

test('the curve PSP estimate safely handles invalid input and an elapsed clock', () => {
  for (const amount of [0n, MIN_BUY - 1n, -1n, Infinity, NaN, '1', null, (1n << 256n)]) {
    const result = previewBuy({ ...params, amount });
    assert.equal(result.pspOut, 0n);
    assert.equal(result.quoteAvailable, true);
  }
  for (const bootReserve of [0, -1, Infinity, NaN, Number.MAX_VALUE, '900']) {
    const result = previewBuy({ ...params, bootReserve });
    assert.equal(result.pspOut, 0n);
    assert.equal(result.quoteAvailable, false);
  }
  assert.equal(previewBuy({ ...params, remaining: 0 }).pspOut, 0n);
});

test('unsupported large buys return unavailable quotes without unsafe BigInt conversion', () => {
  for (const amount of [mix('10000000'), (1n << 256n) - 1n]) {
    const result = previewBuy({ ...params, amount });
    assert.equal(result.pspOut, 0n);
    assert.equal(result.quoteAvailable, false);
  }
  for (const reserve of [mix('10000000'), Infinity, -1n, null]) {
    const result = previewBuy({ ...params, reserve });
    assert.equal(result.pspOut, 0n);
    assert.equal(result.quoteAvailable, false);
  }
});

test('quotes follow the round launch reserve and current reserve as the curve changes', () => {
  const base = { ...params, amount: mix('.01'), reserve: mix('1248.36') };
  const inferred = previewBuy(base);
  const explicit = previewBuy({ ...base, bootReserve: 900 });
  assert.equal(inferred.pspOut, explicit.pspOut);
  const smallerGenesis = previewBuy({ ...base, genesisPot: mix('50') });
  const smallerBoot = previewBuy({ ...base, bootReserve: 450 });
  assert.equal(smallerGenesis.pspOut, smallerBoot.pspOut);
  assert.ok(smallerBoot.pspOut < explicit.pspOut);
  assert.ok(previewBuy({ ...base, reserve: mix('9000') }).pspOut < explicit.pspOut);
  assert.equal(previewBuy({ ...base, genesisPot: 0n }).pspOut, explicit.pspOut);
});
