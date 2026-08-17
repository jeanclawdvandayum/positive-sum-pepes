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
 * Optional DOM related utilities. Some utilities, useful to decode QR from camera:
 * - draw overlay: helps user to position QR code on camera
 * - draw bitmap: useful for debugging (what decoder sees)
 * - draw result: show scanned QR code
 * The code is fragile: it is easy to make subtle errors, which will break decoding.
 * @module
 */
import type { TArg, TRet } from './index.ts';
/**
 * Read rendered element dimensions from computed CSS.
 * @param elm - Element whose computed width and height should be parsed.
 * @returns Pixel width and height parsed from computed styles.
 * @example
 * Read rendered element dimensions from computed CSS.
 * ```ts
 * import { getSize } from 'qr/dom.js';
 * if (typeof document !== 'undefined') {
 *   const video = document.querySelector('video')!;
 *   void getSize(video);
 * }
 * ```
 */
export declare const getSize: (elm: HTMLElement) => {
    width: number;
    height: number;
};
/** `QRCanvas` drawing and decode options. */
export type QRCanvasOpts = {
    /** Pixel scale used when painting the decoded QR preview. */
    resultBlockSize: number;
    /** Fill color for the detected QR quadrilateral. */
    overlayMainColor: string;
    /** Fill color for the detected finder patterns. */
    overlayFinderColor: string;
    /** Fill color for the cropped side bars around the preview. */
    overlaySideColor: string;
    /** Time in milliseconds to keep the overlay visible after the last detection. */
    overlayTimeout: number;
    /** Crop incoming frames to a centered square before decoding. */
    cropToSquare: boolean;
    /**
     * Custom byte-to-text decoder used for byte segments.
     *
     * Receives the byte segment and, when needed, the active ECI designator.
     * ISO/IEC 18004:2024 §7.4.3.4 keeps ECIs active "until the end of
     * the encoded data or a change of ECI"; `QRCanvas` forwards this into
     * `decodeQR()`, so keep the same optional ECI argument here.
     * @param bytes - Byte segment payload to decode.
     * @param eci - Active ECI designator for the byte segment.
     * @returns Decoded text for the byte segment.
     */
    textDecoder?: TArg<(bytes: Uint8Array, eci?: number) => string>;
};
/** Optional output canvases used by `QRCanvas`. */
export type QRCanvasElements = {
    /** Canvas used to draw the overlay polygon and finder boxes. */
    overlay?: HTMLCanvasElement;
    /** Canvas used to show the bitmap fed into the decoder. */
    bitmap?: HTMLCanvasElement;
    /** Canvas used to show the successfully decoded QR image. */
    resultQR?: HTMLCanvasElement;
};
/**
 * Handles canvases for QR code decoding.
 * @param elements - Optional output canvases. See {@link QRCanvasElements}.
 * @param opts - Drawing and decode options for the helper canvases. See {@link QRCanvasOpts}.
 * @example
 * Create a `QRCanvas` that paints overlay highlights onto a DOM canvas.
 * ```ts
 * import { QRCanvas } from 'qr/dom.js';
 * if (typeof document !== 'undefined') {
 *   const overlay = document.createElement('canvas');
 *   const canvas = new QRCanvas({ overlay });
 *   void canvas;
 * }
 * ```
 */
export declare class QRCanvas {
    private opts;
    private lastDetect;
    private main;
    private overlay?;
    private bitmap?;
    private resultQR?;
    constructor(elements?: QRCanvasElements, opts?: Partial<QRCanvasOpts>);
    private setSize;
    private drawBitmap;
    private drawResultQr;
    private drawOverlay;
    drawImage(image: CanvasImageSource, height: number, width: number): string | undefined;
    clear(): void;
}
declare class QRCamera {
    private stream;
    private player;
    constructor(stream: MediaStream, player: HTMLVideoElement);
    private setStream;
    /**
     * Returns list of cameras
     * NOTE: available only after first getUserMedia request, so cannot be additional method
     */
    listDevices(): Promise<{
        deviceId: string;
        label: string;
    }[]>;
    /**
     * Change stream to different camera
     * @param deviceId - devideId from '.listDevices'
     */
    setDevice(deviceId: string): Promise<void>;
    readFrame(canvas: QRCanvas, fullSize?: boolean): string | undefined;
    stop(): void;
}
/**
 * Creates new QRCamera from frontal camera
 * @param player - HTML Video element
 * @returns Camera wrapper backed by the selected media stream.
 * @example
 * Create a camera helper and read frames into a `QRCanvas`.
 * ```ts
 * import { QRCanvas, frontalCamera } from 'qr/dom.js';
 * if (typeof document !== 'undefined') {
 *   const player = document.querySelector('video')!;
 *   const canvas = new QRCanvas();
 *   const camera = await frontalCamera(player);
 *   camera.readFrame(canvas);
 *   camera.stop();
 * }
 * ```
 */
export declare function frontalCamera(player: HTMLVideoElement): Promise<TRet<QRCamera>>;
/**
 * Run callback in a loop with requestAnimationFrame.
 * @param cb - Callback invoked for each requested animation frame.
 * @returns Canceller that stops the scheduled loop.
 * @example
 * Run a callback on every animation frame until cancelled.
 * ```ts
 * import { frameLoop } from 'qr/dom.js';
 * if (typeof requestAnimationFrame !== 'undefined') {
 *   const cancel = frameLoop(() => {});
 *   cancel();
 * }
 * ```
 */
export declare function frameLoop(cb: FrameRequestCallback): () => void;
/**
 * Convert an SVG string into a PNG data URL in browser environments.
 * @param svgData - SVG markup to rasterize.
 * @param width - Output PNG width in pixels.
 * @param height - Output PNG height in pixels.
 * @returns Promise that resolves to a PNG `data:` URL.
 * @example
 * Convert an SVG string into a PNG data URL in browser environments.
 * ```ts
 * import { svgToPng } from 'qr/dom.js';
 * const svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1 1"><rect width="1" height="1"/></svg>';
 * if (typeof DOMParser !== 'undefined' && typeof document !== 'undefined') {
 *   const pngUrl = await svgToPng(svg, 256, 256);
 *   void pngUrl;
 * }
 * ```
 */
export declare function svgToPng(svgData: string, width: number, height: number): Promise<string>;
/**
 * Convert GIF bytes into a PNG blob in browser environments.
 * @param gifBytes - GIF file contents.
 * @returns Promise that resolves to a PNG blob.
 * @throws If the browser cannot create an image bitmap or rendering context for the GIF. {@link Error}
 * @example
 * Convert GIF bytes into a PNG blob in browser environments.
 * ```ts
 * import { gifToPng } from 'qr/dom.js';
 * if (typeof window !== 'undefined') {
 *   const gif = new Uint8Array(await (await fetch('/qr.gif')).arrayBuffer());
 *   const png = await gifToPng(gif);
 *   void png;
 * }
 * ```
 */
export declare function gifToPng(gifBytes: TArg<Uint8Array>): Promise<Blob>;
export {};
//# sourceMappingURL=dom.d.ts.map