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
 * Methods for decoding (reading) QR code patterns.
 * @module
 */
import type { Image, Point, TArg, TRet } from './index.ts';
import { Bitmap } from './index.ts';
type Point4 = [Point, Point, Point, Point];
/** Finder and alignment points returned by the detector. */
export type FinderPoints = [Pattern, Pattern, Point, Pattern];
/**
 * Convert to grayscale. The function is the most expensive part of decoding:
 * it takes up to 90% of time.
 *
 * Binarization pipeline:
 * 1. Convert RGB/RGBA image to one luma byte per pixel.
 * 2. Split the image into 8x8 blocks and collect per-block mean/min/max.
 * 3. Build a 5x5 neighborhood mean over those block means.
 * 4. Turn each 8x8 block into bitmap bits using a local cut derived from:
 *    - the neighborhood mean,
 *    - the current block statistics,
 *    - a cheap whole-image color-spread estimate,
 *    - and, on risky scenes, a local variance field over block means.
 *
 * Instead of producing "best looking" thresholding: we produce a
 * bitmap where finder patterns survive perspective / blur / highlights while
 * keeping false dark regions low enough for downstream finder selection.
 */
declare function toBitmap(img: TArg<Image>): TRet<Bitmap>;
type Pattern = Point & {
    moduleSize: number;
    count: number;
};
declare function findFinder(b: TArg<Bitmap>): {
    bl: Pattern;
    tl: Pattern;
    tr: Pattern;
};
declare function findAlignment(b: TArg<Bitmap>, est: Pattern, allowanceFactor: number): Pattern;
declare function detect(b: TArg<Bitmap>): TRet<{
    bits: Bitmap;
    points: FinderPoints;
}>;
declare function transform(b: TArg<Bitmap>, size: number, from: Point4, to: Point4): TRet<Bitmap>;
declare function decodeBitmap(b: TArg<Bitmap>, decoder?: TArg<(bytes: Uint8Array, eci: number) => string>): string;
/** QR decoding hooks and image preprocessing options. */
export type DecodeOpts = {
    /** Crop rectangular inputs to a centered square before decoding. */
    cropToSquare?: boolean;
    /**
     * Custom byte-to-text decoder used for byte segments.
     *
     * Receives the byte segment and, when needed, the active ECI designator.
     * ISO/IEC 18004:2024 §7.4.3.4 keeps ECIs active "until the end of
     * the encoded data or a change of ECI", so callers need the active
     * designator to apply their own charset policy.
     * @param bytes - Byte segment payload to decode.
     * @param eci - Active ECI designator for the byte segment.
     * @returns Decoded text for the byte segment.
     */
    textDecoder?: TArg<(bytes: Uint8Array, eci?: number) => string>;
    /**
     * Callback invoked with finder/alignment points after detection succeeds.
     *
     * Receives finder and alignment points returned by the detector.
     * @param points - Finder and alignment points returned by the detector.
     */
    pointsOnDetect?: (points: FinderPoints) => void;
    /**
     * Callback invoked with the grayscale bitmap that the detector sees.
     *
     * Receives the grayscale image generated during bitmap conversion.
     * @param img - Grayscale image generated during bitmap conversion.
     */
    imageOnBitmap?: (img: Image) => void;
    /**
     * Callback invoked with the perspective-corrected QR image.
     *
     * Receives the perspective-corrected QR image.
     * @param img - Perspective-corrected QR image.
     */
    imageOnDetect?: (img: Image) => void;
    /**
     * Callback invoked with the final decoded QR image.
     *
     * Receives the final QR image used to decode the payload.
     * @param img - Final QR image used to decode the payload.
     */
    imageOnResult?: (img: Image) => void;
};
/**
 * Decode text from a QR image.
 * @param img - RGB or RGBA image data that contains a QR code.
 * @param opts - Decoder hooks and image preprocessing options. See {@link DecodeOpts}.
 * @returns Decoded QR payload as a string.
 * @throws If the image, decoder options, or QR contents are invalid. {@link Error}
 * @example
 * Decode text from a QR image.
 * ```ts
 * import encodeQR, { Bitmap } from 'qr';
 * import decodeQR from 'qr/decode.js';
 * const bits = encodeQR('Hello world', 'raw', { scale: 4 });
 * const bm = new Bitmap({ width: bits[0].length, height: bits.length }, bits);
 * const text = decodeQR(bm.toImage());
 * ```
 */
export declare function decodeQR(img: TArg<Image>, opts?: TArg<DecodeOpts>): string;
/**
 * Default export alias for {@link decodeQR}.
 * @param img - RGB or RGBA image data that contains a QR code.
 * @param opts - Decoder hooks and image preprocessing options. See {@link DecodeOpts}.
 * @returns Decoded QR payload as a string.
 * @throws If the image, decoder options, or QR contents are invalid. {@link Error}
 * @example
 * Decode a rendered QR image via the default decoder export.
 * ```ts
 * import encodeQR, { Bitmap } from 'qr';
 * import decodeQR from 'qr/decode.js';
 * const bits = encodeQR('Hello world', 'raw', { scale: 4 });
 * const bm = new Bitmap({ width: bits[0].length, height: bits.length }, bits);
 * decodeQR(bm.toImage());
 * ```
 */
export default decodeQR;
export declare const _TESTS: {
    findAlignment: typeof findAlignment;
    transform: typeof transform;
};
export declare const _tests: {
    toBitmap: typeof toBitmap;
    decodeBitmap: typeof decodeBitmap;
    findFinder: typeof findFinder;
    detect: typeof detect;
};
//# sourceMappingURL=decode.d.ts.map