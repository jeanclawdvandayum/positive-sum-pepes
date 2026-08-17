/*!
Copyright (c) 2023 Paul Miller (paulmillr.com)
The library paulmillr-qr is dual-licensed under the Apache 2.0 OR MIT license.
You can select a license of your choice.
Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/
/**
 * Methods for encoding (generating) QR code patterns.
 * Check out decode.ts for decoding (reading).
 * @module
 * @example
```js
import encodeQR from 'qr';
const txt = 'Hello world';
const ascii = encodeQR(txt, 'ascii'); // Not all fonts are supported
const terminalFriendly = encodeQR(txt, 'term'); // 2x larger, all fonts are OK
const gifBytes = encodeQR(txt, 'gif'); // Uncompressed GIF
const svgElement = encodeQR(txt, 'svg'); // SVG vector image element
const array = encodeQR(txt, 'raw'); // 2d array for canvas or other libs
// import decodeQR from 'qr/decode.js';
```
 */
/**
 * Bytes API type helpers for old + new TypeScript.
 *
 * TS 5.6 has `Uint8Array`, while TS 5.9+ made it generic `Uint8Array<ArrayBuffer>`.
 * We can't use specific return type, because TS 5.6 will error.
 * We can't use generic return type, because most TS 5.9 software will expect specific type.
 *
 * Maps typed-array input leaves to broad forms.
 * These are compatibility adapters, not ownership guarantees.
 *
 * - `TArg` keeps byte inputs broad.
 * - `TRet` marks byte outputs for TS 5.6 and TS 5.9+ compatibility.
 */
export type TypedArg<T> = T extends BigInt64Array ? BigInt64Array : T extends BigUint64Array ? BigUint64Array : T extends Float32Array ? Float32Array : T extends Float64Array ? Float64Array : T extends Int16Array ? Int16Array : T extends Int32Array ? Int32Array : T extends Int8Array ? Int8Array : T extends Uint16Array ? Uint16Array : T extends Uint32Array ? Uint32Array : T extends Uint8ClampedArray ? Uint8ClampedArray : T extends Uint8Array ? Uint8Array : never;
/** Maps typed-array output leaves to narrow TS-compatible forms. */
export type TypedRet<T> = T extends BigInt64Array ? ReturnType<typeof BigInt64Array.of> : T extends BigUint64Array ? ReturnType<typeof BigUint64Array.of> : T extends Float32Array ? ReturnType<typeof Float32Array.of> : T extends Float64Array ? ReturnType<typeof Float64Array.of> : T extends Int16Array ? ReturnType<typeof Int16Array.of> : T extends Int32Array ? ReturnType<typeof Int32Array.of> : T extends Int8Array ? ReturnType<typeof Int8Array.of> : T extends Uint16Array ? ReturnType<typeof Uint16Array.of> : T extends Uint32Array ? ReturnType<typeof Uint32Array.of> : T extends Uint8ClampedArray ? ReturnType<typeof Uint8ClampedArray.of> : T extends Uint8Array ? ReturnType<typeof Uint8Array.of> : never;
/** Recursively adapts byte-carrying API input types. See {@link TypedArg}. */
export type TArg<T> = T | ([TypedArg<T>] extends [never] ? T extends (...args: infer A) => infer R ? ((...args: {
    [K in keyof A]: TRet<A[K]>;
}) => TArg<R>) & {
    [K in keyof T]: T[K] extends (...args: any) => any ? T[K] : TArg<T[K]>;
} : T extends [infer A, ...infer R] ? [TArg<A>, ...{
    [K in keyof R]: TArg<R[K]>;
}] : T extends readonly [infer A, ...infer R] ? readonly [TArg<A>, ...{
    [K in keyof R]: TArg<R[K]>;
}] : T extends (infer A)[] ? TArg<A>[] : T extends readonly (infer A)[] ? readonly TArg<A>[] : T extends Promise<infer A> ? Promise<TArg<A>> : T extends object ? {
    [K in keyof T]: TArg<T[K]>;
} : T : TypedArg<T>);
/** Recursively adapts byte-carrying API output types. See {@link TypedArg}. */
export type TRet<T> = T extends unknown ? T & ([TypedRet<T>] extends [never] ? T extends (...args: infer A) => infer R ? ((...args: {
    [K in keyof A]: TArg<A[K]>;
}) => TRet<R>) & {
    [K in keyof T]: T[K] extends (...args: any) => any ? T[K] : TRet<T[K]>;
} : T extends [infer A, ...infer R] ? [TRet<A>, ...{
    [K in keyof R]: TRet<R[K]>;
}] : T extends readonly [infer A, ...infer R] ? readonly [TRet<A>, ...{
    [K in keyof R]: TRet<R[K]>;
}] : T extends (infer A)[] ? TRet<A>[] : T extends readonly (infer A)[] ? readonly TRet<A>[] : T extends Promise<infer A> ? Promise<TRet<A>> : T extends object ? {
    [K in keyof T]: TRet<T[K]>;
} : T : TypedRet<T>) : never;
/** Bidirectional codec interface. */
export interface Coder<F, T> {
    /**
     * Encodes a source value into the target representation.
     * @param from - Source value to encode.
     * @returns Encoded representation.
     */
    encode(from: F): T;
    /**
     * Decodes a target value back into the source representation.
     * @param to - Encoded representation to decode.
     * @returns Decoded source value.
     */
    decode(to: T): F;
}
declare function validateVersion(ver: Version): void;
declare function bin(dec: number, pad: number): string;
declare function fillArr<T>(length: number, val: T): T[];
declare function popcnt(n: number): number;
declare function best<T>(): {
    add(score: number, value: T): void;
    get: () => T | undefined;
    score: () => number;
};
/** Two-dimensional point. */
export type Point = {
    /** Horizontal coordinate. */
    x: number;
    /** Vertical coordinate. */
    y: number;
};
/** Width and height pair. */
export type Size = {
    /** Pixel height. */
    height: number;
    /** Pixel width. */
    width: number;
};
/** Raster image used by the encoder and decoder. */
export type Image = Size & {
    /** Row-major RGB or RGBA pixel data. */
    data: Uint8Array | Uint8ClampedArray | number[];
};
type DrawValue = boolean | undefined;
type DrawFn = DrawValue | ((c: Point, curr: DrawValue) => DrawValue);
type ReadFn = (c: Point, curr: DrawValue) => void;
/**
 * Mutable monochrome bitmap used as the internal QR representation.
 * @param size - Square edge length or explicit bitmap dimensions.
 * @param data - Optional row-major pixel matrix using `true`, `false`, or `undefined`.
 * @example
 * Create a bitmap, then scale it for display.
 * ```ts
 * import { Bitmap } from 'qr';
 * const bitmap = Bitmap.fromString('X \n X');
 * bitmap.scale(2);
 * ```
 */
export declare class Bitmap {
    private static size;
    static fromString(s: string): Bitmap;
    private defined;
    private value;
    private tailMask;
    private words;
    private fullWords;
    height: number;
    width: number;
    constructor(size: Size | number, data?: DrawValue[][]);
    point(p: Point): DrawValue;
    isInside(p: Point): boolean;
    size(offset?: Point | number): {
        height: number;
        width: number;
    };
    private xy;
    /**
     * Return pixel bit index
     */
    private wordIndex;
    private bitIndex;
    isDefined(x: number, y: number): boolean;
    get(x: number, y: number): boolean;
    private maskWord;
    set(x: number, y: number, v: DrawValue): void;
    private fillRectConst;
    private rectWords;
    rect(c: Point | number, size: Size | number, fn: DrawFn): this;
    rectRead(c: Point | number, size: Size | number, fn: ReadFn): this;
    hLine(c: Point | number, len: number, value: DrawFn): this;
    vLine(c: Point | number, len: number, value: DrawFn): this;
    border(border: number | undefined, value: DrawValue): Bitmap;
    embed(c: Point | number, src: Bitmap): this;
    rectSlice(c: Point | number, size?: Size | number): Bitmap;
    transpose(): Bitmap;
    negate(): Bitmap;
    scale(factor: number): Bitmap;
    clone(): Bitmap;
    assertDrawn(): void;
    countPatternInRow(y: number, patternLen: number, ...patterns: number[]): number;
    getRuns(y: number, fn: (len: number, value: boolean) => void): void;
    popcnt(): number;
    countBoxes2x2(y: number): number;
    toString(): string;
    toRaw(): DrawValue[][];
    toASCII(): string;
    toTerm(): string;
    toSVG(optimize?: boolean): string;
    toGIF(): Uint8Array;
    toImage(isRGB?: boolean): Image;
}
/** Error correction mode. low: 7%, medium: 15%, quartile: 25%, high: 30%. */
export declare const ECMode: readonly ['low', 'medium', 'quartile', 'high'];
/** Error correction mode name. */
export type ErrorCorrection = (typeof ECMode)[number];
/** QR Code version in the `[1..40]` range. */
export type Version = number;
/** QR Code mask index. */
export type Mask = (0 | 1 | 2 | 3 | 4 | 5 | 6 | 7) & keyof typeof PATTERNS;
/**
 * QR payload compaction mode names recognized by the type/validator.
 * `kanji` and `eci` are spec modes, but `encodeQR` currently rejects them until implemented.
 */
export declare const Encoding: readonly ['numeric', 'alphanumeric', 'byte', 'kanji', 'eci'];
/** QR payload encoding name. */
export type EncodingType = (typeof Encoding)[number];
declare const PATTERNS: readonly ((x: number, y: number) => boolean)[];
declare function interleave(ver: Version, ecc: ErrorCorrection): TRet<Coder<Uint8Array, Uint8Array>>;
declare function drawTemplate(ver: Version, ecc: ErrorCorrection, maskIdx: Mask, test?: boolean): TRet<Bitmap>;
declare function zigzag(tpl: TArg<Bitmap>, maskIdx: Mask, fn: (x: number, y: number, mask: boolean) => void): void;
declare function detectType(str: string): EncodingType;
/**
 * Encode a string as UTF-8 bytes.
 * @param str - Text to encode into UTF-8.
 * @returns UTF-8 bytes for the provided string.
 * @throws If the input is not a string. {@link Error}
 * @example
 * Encode a string as UTF-8 bytes.
 * ```ts
 * const bytes = utf8ToBytes('abc'); // new Uint8Array([97, 98, 99])
 * ```
 */
export declare function utf8ToBytes(str: string): TRet<Uint8Array>;
declare function encode(ver: Version, ecc: ErrorCorrection, data: string, type: EncodingType, encoder?: TArg<(value: string) => Uint8Array>): TRet<Uint8Array>;
declare function drawQR(ver: Version, ecc: ErrorCorrection, data: TArg<Uint8Array>, maskIdx: Mask, test?: boolean): TRet<Bitmap>;
declare function penalty(bm: TArg<Bitmap>): number;
/** QR Code generation options. */
export type QrOpts = {
    /** Error-correction level to encode into the symbol. */
    ecc?: ErrorCorrection | undefined;
    /** Explicit payload encoding, otherwise detected from the input text. */
    encoding?: EncodingType | undefined;
    /**
     * Custom text encoder used for `byte` payloads.
     *
     * Receives the text payload and returns the encoded byte sequence.
     * @param text - Text payload to encode.
     * @returns Encoded byte sequence for the payload.
     */
    textEncoder?: TArg<(text: string) => Uint8Array>;
    /** Explicit QR version to use instead of auto-fitting. */
    version?: Version | undefined;
    /** Explicit mask pattern to apply instead of choosing the best one. */
    mask?: number | undefined;
    /** Quiet-zone border width in modules. */
    border?: number | undefined;
    /** Output scale multiplier for raster formats. */
    scale?: number | undefined;
};
/** SVG-specific QR output options. */
export type SvgQrOpts = {
    /**
     * Controls how cells are generated within the SVG.
     *
     * If `true`:
     *   - Cells are drawn using a single `path` element.
     *   - Pro: significantly reduces the size of the QR code (`70%` smaller than
     *     unoptimized).
     *   - Con: less flexible with visually customizing cell shapes.
     *
     * If `false`:
     *   - Each cell is drawn with its own `rect` element.
     *   - Pro: allows more flexibility with visually customizing cells shapes.
     *   - Con: significantly increases the QR code size (`230%` larger than
     *     optimized).
     *
     * Default is `true`.
     */
    optimize?: boolean | undefined;
};
/** Supported encoder outputs. */
export type Output = 'raw' | 'ascii' | 'term' | 'gif' | 'svg';
/**
 * Encodes (creates / generates) QR code.
 * @param text - Text payload that should be encoded into the QR symbol.
 * @param output - Output format to generate: raw matrix, ASCII, terminal ANSI, GIF, or SVG.
 * @param opts - Encoding and rendering options. See {@link QrOpts} and {@link SvgQrOpts}.
 * @returns Encoded QR data in the format selected by `output`.
 * @throws If the payload, options, QR capacity, or output format are invalid. {@link Error}
 * @example
 * Encode one text payload into several QR output formats.
 * ```ts
 * const txt = 'Hello world';
 * const ascii = encodeQR(txt, 'ascii'); // Not all fonts are supported
 * const terminalFriendly = encodeQR(txt, 'term'); // 2x larger, all fonts are OK
 * const gifBytes = encodeQR(txt, 'gif'); // Uncompressed GIF
 * const svgElement = encodeQR(txt, 'svg'); // SVG vector image element
 * const array = encodeQR(txt, 'raw'); // 2d array for canvas or other libs
 * ```
 */
export declare function encodeQR(text: string, output: 'raw', opts?: TArg<QrOpts>): boolean[][];
export declare function encodeQR(text: string, output: 'ascii' | 'term', opts?: TArg<QrOpts>): string;
export declare function encodeQR(text: string, output: 'svg', opts?: TArg<QrOpts & SvgQrOpts>): string;
export declare function encodeQR(text: string, output: 'gif', opts?: TArg<QrOpts>): TRet<Uint8Array>;
/**
 * Default export alias for {@link encodeQR}.
 * @param text - Text payload that should be encoded into the QR symbol.
 * @param output - Output format to generate: raw matrix, ASCII, terminal ANSI, GIF, or SVG.
 * @param opts - Encoding and rendering options. See {@link QrOpts} and {@link SvgQrOpts}.
 * @returns Encoded QR data in the format selected by `output`.
 * @throws If the payload, options, QR capacity, or output format are invalid. {@link Error}
 * @example
 * Encode text into the default export from the package root.
 * ```ts
 * import encodeQR from 'qr';
 * encodeQR('Hello world', 'ascii');
 * ```
 */
export default encodeQR;
/**
 * Low-level helpers used by the encoder and test suite.
 * Exports the shared helper tables/functions through a frozen container.
 * @example
 * Read low-level QR metadata tables.
 * ```ts
 * import { utils } from 'qr';
 * const size = utils.info.size.encode(1); // 21
 * ```
 */
export declare const utils: {
    best: typeof best;
    bin: typeof bin;
    popcnt: typeof popcnt;
    drawTemplate: typeof drawTemplate;
    fillArr: typeof fillArr;
    info: {
        size: Coder<Version, number>;
        sizeType: (ver: Version) => number;
        alignmentPatterns(ver: Version): number[];
        ECCode: Record<ErrorCorrection, number>;
        formatMask: number;
        formatBits(ecc: ErrorCorrection, maskIdx: Mask): number;
        versionBits(ver: Version): number;
        alphabet: {
            numeric: Coder<number[], string[]> & {
                has: (char: string) => boolean;
            };
            alphanumerc: Coder<number[], string[]> & {
                has: (char: string) => boolean;
            };
        };
        lengthBits(ver: Version, type: EncodingType): number;
        modeBits: {
            numeric: string;
            alphanumeric: string;
            byte: string;
            kanji: string;
            eci: string;
        };
        capacity(ver: Version, ecc: ErrorCorrection): {
            words: number;
            numBlocks: number;
            shortBlocks: number;
            blockLen: number;
            capacity: number;
            total: number;
        };
    };
    interleave: typeof interleave;
    validateVersion: typeof validateVersion;
    zigzag: typeof zigzag;
};
export declare const _tests: {
    Bitmap: typeof Bitmap;
    info: {
        size: Coder<Version, number>;
        sizeType: (ver: Version) => number;
        alignmentPatterns(ver: Version): number[];
        ECCode: Record<ErrorCorrection, number>;
        formatMask: number;
        formatBits(ecc: ErrorCorrection, maskIdx: Mask): number;
        versionBits(ver: Version): number;
        alphabet: {
            numeric: Coder<number[], string[]> & {
                has: (char: string) => boolean;
            };
            alphanumerc: Coder<number[], string[]> & {
                has: (char: string) => boolean;
            };
        };
        lengthBits(ver: Version, type: EncodingType): number;
        modeBits: {
            numeric: string;
            alphanumeric: string;
            byte: string;
            kanji: string;
            eci: string;
        };
        capacity(ver: Version, ecc: ErrorCorrection): {
            words: number;
            numBlocks: number;
            shortBlocks: number;
            blockLen: number;
            capacity: number;
            total: number;
        };
    };
    detectType: typeof detectType;
    encode: typeof encode;
    drawQR: typeof drawQR;
    penalty: typeof penalty;
    PATTERNS: readonly ((x: number, y: number) => boolean)[];
};
//# sourceMappingURL=index.d.ts.map