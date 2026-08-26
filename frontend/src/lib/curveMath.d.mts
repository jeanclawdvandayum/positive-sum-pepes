/// Types for curveMath.mjs (kept JS so `node` can referee-test the identical
/// file the vite app imports).
export interface Zone {
  startSupply: bigint
  endSupply: bigint
  rate: bigint
  isExponential: boolean
}
export interface CurveConfig {
  P0: bigint
  zones: Zone[]
}
export declare function mulWad(x: bigint, y: bigint): bigint
export declare function divWad(x: bigint, y: bigint): bigint
export declare function expWad(x: bigint): bigint
export declare function lnWad(x: bigint): bigint
export declare function marginalPrice(S: bigint, cc: CurveConfig): bigint
export declare function curveIntegral(S1: bigint, S2: bigint, cc: CurveConfig): bigint
export declare const MAX_SUPPLY_WAD: bigint
export declare const UINT256_MAX: bigint
export declare function makeConfig(
  p0: bigint,
  bounds: bigint[],
  rates: bigint[],
  exps: boolean[],
): CurveConfig
