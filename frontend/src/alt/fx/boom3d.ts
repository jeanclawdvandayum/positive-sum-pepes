// ─────────────────────────────────────────────────────────────────────────────
// boom3d: the detonation set-piece's pixel-3D nuke (PLAN Feature 4).
//
// Loaded lazily through boomLoader.ts, so three.js never reaches the entry
// bundle. DetonationSetPiece creates the scene at mount, which compiles the
// shaders and uploads the buffers during the alarm, starts the loop just
// before BLAST_MS, and disposes it on finish, skip or unmount. The loop rides
// the PhaseEngine frame bus — the app's one rAF loop (PLAN Ground rules).
// The canvas is appended on creation (a failed probe leaves no DOM) and stays
// invisible until start(), so no pre-blast warm-up frame can leak: the DOM
// pixel bomb owns the pre-blast frame, the ground and shell shaders also
// discard at t<0, and the ground lights only after the blast (dust skirt).
//
// Look: rendered at 1/4 (1/3 under 700px) of the viewport, upscaled in whole
// pixels with image-rendering: pixelated. Every surface is posterized to a
// 9-color palette read from the theme (--boom-* on .dtn-stage), with a
// Bayer dither only at the band edges. Opacity is dithered too
// (screen-door discard), so nothing is sorted or blended.
//
// Motion is analytic. Every puff's position, size and heat are pure
// functions of the blast clock, evaluated in the vertex shader, so the CPU
// only updates a few uniforms per frame and the scene always follows the
// set-piece's own CSS clock (paused and seeked animations included).
// Puffs, 1,651 instances in one draw call:
//   core   1     the ignition fireball, white-hot for ~150ms, shrinks into the cap
//   cap    1050  a toroidal vortex that rolls (in at the bottom, up the
//                inside, out over the top), rises and cools from white to
//                yellow, orange, red and then smoke; its underside keeps an ember glow
//   stem   300   a swirling column that rises into the cap, flared base and top
//   skirt  300   the base-surge dust ring, rolling outward along the ground
// plus the ground (flash glow + shockwave ring) and the condensation shell.
// ─────────────────────────────────────────────────────────────────────────────

import {
  IcosahedronGeometry,
  InstancedBufferAttribute,
  InstancedBufferGeometry,
  Mesh,
  PerspectiveCamera,
  PlaneGeometry,
  Scene,
  ShaderMaterial,
  SphereGeometry,
  Vector2,
  Vector3,
  WebGLRenderer,
} from 'three'
import { subscribeFrames } from '../../phase/PhaseEngine'

export type Rgb = [number, number, number]

/** Smoke ramp dark→light, then the fire ramp ember→white-hot. */
const PALETTE_VARS = [
  '--boom-smoke-0', '--boom-smoke-1', '--boom-smoke-2', '--boom-smoke-3',
  '--boom-ember', '--boom-red', '--boom-orange', '--boom-yellow', '--boom-hot',
] as const

export interface BoomOptions {
  /** Element the canvas is appended to (fills it). Also where --boom-* resolve. */
  host: HTMLElement
  /** Blast clock in ms (0 = ignition). May be negative before the blast. */
  clock: () => number
  /** Blast point height as a fraction of the viewport (0 top, 1 bottom). */
  groundFrac: number
  /**
   * The DOM pixel bomb the fireball bursts out of, in CSS px: its body
   * center's height above the blast point and its radius. The core fireball
   * ignites at exactly that center and size.
   */
  ignite: { up: number; radius: number }
}

export interface Boom {
  /** Start the render loop (idempotent). */
  start(): void
  /** Stop the loop, free every GPU resource, drop the context, remove the canvas. */
  dispose(): void
}

const CAP = 1050
const STEM = 420
const SKIRT = 300
const PUFFS = 1 + CAP + STEM + SKIRT
const PAL_SIZE = PALETTE_VARS.length

/** Resolve a CSS color (any syntax the browser computes) to sRGB 0..1. */
function parseColor(css: string): Rgb {
  const n = (css.match(/-?[\d.]+(?:e-?\d+)?/g) ?? []).map(Number)
  if (css.startsWith('color(')) return [n[0] ?? 0, n[1] ?? 0, n[2] ?? 0]
  return [(n[0] ?? 0) / 255, (n[1] ?? 0) / 255, (n[2] ?? 0) / 255]
}

function readPalette(host: HTMLElement): Vector3[] {
  const probe = document.createElement('span')
  probe.style.display = 'none'
  host.appendChild(probe)
  const palette = PALETTE_VARS.map(name => {
    probe.style.color = `var(${name})`
    const [r, g, b] = parseColor(getComputedStyle(probe).color)
    return new Vector3(r, g, b)
  })
  probe.remove()
  return palette
}

// Shared GLSL: value noise, ordered dither, the posterized palette lookup.
const COMMON = /* glsl */ `
uniform float uT;
uniform float uFade;
uniform vec3 uPal[${PAL_SIZE}];
float hash13(vec3 p) {
  p = fract(p * 0.3183099 + 0.1);
  p *= 17.0;
  return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}
float noise3(vec3 x) {
  vec3 i = floor(x);
  vec3 f = fract(x);
  f = f * f * (3.0 - 2.0 * f);
  return mix(
    mix(mix(hash13(i), hash13(i + vec3(1, 0, 0)), f.x), mix(hash13(i + vec3(0, 1, 0)), hash13(i + vec3(1, 1, 0)), f.x), f.y),
    mix(mix(hash13(i + vec3(0, 0, 1)), hash13(i + vec3(1, 0, 1)), f.x), mix(hash13(i + vec3(0, 1, 1)), hash13(i + vec3(1, 1, 1)), f.x), f.y),
    f.z);
}
float easeOut(float x) { x = clamp(x, 0.0, 1.0); return 1.0 - (1.0 - x) * (1.0 - x) * (1.0 - x); }
float bayer2(vec2 a) { a = floor(a); return fract(dot(a, vec2(0.5, a.y * 0.75))); }
float bayer4(vec2 a) { return bayer2(0.5 * a) * 0.25 + bayer2(a); }
// Continuous level -> palette index in [lo, hi], rounded (callers add the
// Bayer offset so only the band edges dither).
vec3 pal(float level, float lo, float hi) {
  float i = clamp(floor(level + 0.5), lo, hi);
  vec3 c = uPal[0];
  for (int k = 1; k < ${PAL_SIZE}; k++) if (float(k) == i) c = uPal[k];
  return c;
}
`

const PUFF_VERT = /* glsl */ `
${COMMON}
attribute vec4 aP; // role, three uniforms in [0,1)
attribute vec4 aQ; // four more
varying vec3 vN;
varying vec3 vW;
varying float vHeat;
varying float vOcc;
varying float vGlow;
varying float vShade; // per-puff brightness variety breaks up flat bands
varying float vFireW; // how strongly this role takes the core's warm light
uniform vec2 uIgnite; // the pixel bomb's body: center height, radius (world units)
void main() {
  float t = max(uT, 0.0);
  float role = aP.x;
  // Cloud envelope: the cap's ring height H, ring radius R, tube radius r.
  float H = 1.2 + 6.6 * easeOut(t / 2.0) + 0.35 * max(t - 2.0, 0.0);
  float R = 0.7 + 3.0 * easeOut(t / 1.8) + 0.25 * max(t - 1.8, 0.0);
  float r = 0.9 + 1.2 * easeOut(t / 1.5) + 0.1 * max(t - 1.5, 0.0);
  float cool = exp(-t / 1.0);
  vec3 center;
  float size;
  float heat;
  float occ = 1.0;
  vec3 squash = vec3(1.0);
  vShade = 1.0;
  vFireW = 1.0;
  if (role < 0.5) {
    // core fireball: ignites filling the pixel bomb's body (same center, same
    // size), flashes out to r=2.7 in ~120ms, lifts to ride up with the cap
    // and shrinks into it as the vortex takes over
    center = vec3(0.0, mix(uIgnite.x, max(H * 0.72, 1.1), easeOut(t / 0.3)), 0.0);
    size = mix(uIgnite.y, 2.7, easeOut(t / 0.12)) * mix(1.0, 0.78, smoothstep(0.12, 0.5, t))
      * (1.0 - smoothstep(0.8, 1.8, t)) * mix(1.0, 0.7, smoothstep(0.4, 1.2, t));
    // the incandescent core lingers under the cap as it rolls, cooling in place
    heat = max(1.3 - 0.75 * t, 0.2);
  } else if (role < 1.5) {
    float th = aP.y * 6.2831853 + 0.25 * sin(aQ.w * 6.28 + t * 0.7) / max(R, 1.0);
    float phi = aP.z * 6.2831853 - 2.2 * log(1.0 + 1.3 * t);
    float rr = sqrt(aP.w);
    vec3 radial = vec3(cos(th), 0.0, sin(th));
    center = radial * R + vec3(0.0, H, 0.0) + r * rr * (cos(phi) * radial + vec3(0.0, 0.72 * sin(phi), 0.0));
    // internal churn
    vec3 q = vec3(aQ.xyz * 13.0 + t * 0.8);
    center += (vec3(noise3(q), noise3(q + 7.1), noise3(q + 3.7)) - 0.5) * (0.35 + 0.4 * t);
    size = mix(0.5, 1.0, aQ.x) * mix(0.75, 1.15, rr) * (0.3 + 0.7 * easeOut(t / 0.45));
    // hot gas enters bottom-inside (phi ~ 3.9) and cools as it rolls up the
    // inside, over the top and down the outside; the outer shell cools first
    float age = fract((3.9 - phi) / 6.2831853);
    heat = 1.1 * exp(-t / 1.6) * (1.0 - 0.65 * rr * smoothstep(0.2, 1.2, t))
      + 0.6 * (1.0 - age) * (1.0 - age) * exp(-t / 1.3) * (1.0 - 0.5 * rr)
      + 0.1 * exp(-t / 3.0);
    occ = mix(0.5, 1.0, rr);
    // the donut's hole: puffs near the axis sit in the cap's own shadow,
    // which is what makes the rolled underside read
    occ *= mix(0.22, 1.0, smoothstep(R * 0.35, R * 1.0, length(center.xz)));
    // large-scale form: puffs on the cloud's lit side (upper-left) are
    // brighter as a whole — per-puff sphere shading is sub-pixel at this size
    occ *= 0.7 + 0.35 * max(dot(normalize(center - vec3(0.0, H * 0.55, 0.0)), normalize(vec3(-0.5, 0.72, 0.55))), 0.0);
    vShade = 0.95 + 0.3 * aQ.z;
    vFireW = 1.0;
  } else if (role < 2.5) {
    // stem: puffs ride up a twisting column from the ground into the
    // underside of the cap. The column thickens as the cap rolls, flares at
    // its foot and into a collar under the cap, and churns as it climbs.
    float top = max(H - r * 0.35, 0.4);
    float u = fract(aP.y + t * 0.5);
    float thick = 0.4 + 0.8 * easeOut(t / 1.6) + 0.1 * max(t - 1.6, 0.0);
    float shape = 1.0 + 0.8 * (1.0 - smoothstep(0.0, 0.2, u)) + 1.2 * smoothstep(0.6, 1.0, u);
    float th = aP.z * 6.2831853 + t * (1.1 + aQ.y) + u * 2.4;
    float rr = sqrt(aP.w);
    center = vec3(cos(th), 0.0, sin(th)) * thick * shape * rr + vec3(0.0, u * top, 0.0);
    vec3 q = vec3(aQ.xyz * 11.0 + vec3(0.0, -t * 1.3, t * 0.4));
    center += (vec3(noise3(q), noise3(q + 5.3), noise3(q + 9.1)) - 0.5) * vec3(0.7 * thick, 0.6, 0.7 * thick);
    // hot where it feeds the cap and in its core; the foot and the outer
    // column cool to dust first, so the column reads as banded smoke
    heat = 1.15 * exp(-t / 0.9) * (0.25 + 0.75 * u) + 0.5 * exp(-t / 1.6) * u * u * (1.0 - rr) + 0.04;
    // pops in at the foot (inside the skirt), grows toward the collar
    size = mix(0.45, 0.8, aQ.x) * (0.75 + 0.45 * thick) * smoothstep(0.0, 0.05, u) * smoothstep(0.0, 0.12, t)
      * mix(0.85, 1.15, rr) * (0.9 + 0.45 * smoothstep(0.6, 1.0, u));
    // dust-laden and sunlit: a band brighter than the cap's own smoke so the
    // column never sinks into the dimmed page behind it
    vShade = 1.2 + 0.35 * aQ.z;
    vFireW = 1.0;
    // the top of the collar dips into the cap's shadow: a dark socket where
    // the stem enters the cap
    occ *= mix(0.55, 1.0, smoothstep(0.75, 0.97, u));
    // column-scale form: the side facing the light (front-left) reads a band
    // or two brighter than the far side, so the stem reads round
    occ *= 0.6 + 0.75 * max(dot(normalize(vec3(center.x, 0.35, center.z)), normalize(vec3(-0.5, 0.72, 0.55))), 0.0);
  } else {
    // skirt: base-surge dust rolling out along the ground
    float front = 1.0 + 8.5 * easeOut((t - 0.08) / 2.2);
    float k = sqrt(aP.z);
    float rho = front * mix(0.3, 1.0, k);
    float th = aP.y * 6.2831853;
    size = mix(0.6, 1.15, aQ.x) * mix(0.55, 1.2, k) * smoothstep(0.08, 0.45, t);
    // the leading edge rolls taller, and the dust slowly lifts
    float lift = aP.w * 0.4 * k * k + smoothstep(0.75, 1.0, k) * 0.35 + t * 0.1 * aP.w;
    center = vec3(cos(th) * rho, size * 0.25 + lift, sin(th) * rho);
    squash = vec3(1.3, 0.6, 1.3);
    // lit hot by the fireball at first, cooling to dust
    vShade = 0.85 + 0.3 * aQ.y;
    vFireW = 1.7;
    // hot dust glows on its own for a while before it cools
    heat = 1.0 * exp(-t / 1.1) * (1.0 - 0.45 * k) + 0.25 * exp(-t / 2.2) * (1.0 - k);
  }
  // lumpy silhouettes
  float lump = 1.0 + (noise3(normal * 1.9 + aQ.yzw * 17.0 + t * 0.9) - 0.5) * 0.55;
  vec3 world = center + position * size * lump * squash;
  vN = normalize(normal / squash);
  vW = world;
  vHeat = heat;
  vOcc = occ;
  vGlow = 1.4 * exp(-t / 2.2) * (role > 2.5 ? 0.4 : 1.0);
  gl_Position = uT < 0.0 ? vec4(2.0, 2.0, 2.0, 1.0) : projectionMatrix * viewMatrix * vec4(world, 1.0);
}
`

const PUFF_FRAG = /* glsl */ `
${COMMON}
varying vec3 vN;
varying vec3 vW;
varying float vHeat;
varying float vOcc;
varying float vGlow;
varying float vShade;
varying float vFireW;

void main() {
  float b = bayer4(gl_FragCoord.xy);
  if (noise3(vW * 0.85 + 3.1) * 0.7 + b * 0.3 < uFade) discard;
  float d = (b - 0.5) * 0.5; // dither only near band edges
  float db = (b - 0.5) * 0.34; // tighter band at the fire/smoke crossover
  vec3 n = normalize(vN);
  // silhouette falloff: puff edges read cooler (fire) or darker (smoke)
  float rim = 1.0 - max(dot(n, normalize(cameraPosition - vW)), 0.0);
  rim *= rim;
  float churn = noise3(vW * 1.6 + vec3(0.0, -uT * 1.4, uT * 0.3));
  // the cloud is lit from its own fire first, the sky second: surfaces
  // facing the hot core (cap underside, skirt inner edge, stem) glow warm
  float fireL = max(dot(n, normalize(vec3(0.0, 3.0 + uT, 0.0) - vW)), 0.0) * vFireW * 1.15 * exp(-max(uT, 0.0) / 1.15);
  // the fire also floods its neighborhood sideways (skirt inner lip, stem)
  float ambient = exp(-length(vW.xz) / 5.5) * exp(-max(uT, 0.0) / 1.4) * vFireW;
  float lit = (pow(max(dot(n, normalize(vec3(-0.5, 0.72, 0.55))), 0.0), 1.5) * 0.78 + 0.15) * vOcc * vShade;
  // the cap casts a contact shadow down the top of the stem (a short band
  // under the cap, so the column below keeps its light); the cap's upper
  // half climbs back out of it toward the sky light
  float capBottom = 1.2 + 6.6 * easeOut(max(uT, 0.0) / 2.0) - 1.2 * easeOut(max(uT, 0.0) / 1.5);
  float shadow = smoothstep(capBottom - 1.8, capBottom, vW.y) * (1.0 - 0.55 * smoothstep(capBottom + 0.6, capBottom + 2.6, vW.y));
  lit *= 1.0 - 0.62 * shadow;
  // fire under the cap lights its underside
  float under = max(-n.y, 0.0) * vGlow;
  float heat = vHeat + (churn - 0.5) * 0.28 + under * 0.3 + fireL * 0.5 + ambient * 0.35 - rim * 0.25 - shadow * 0.12;
  float fire = heat * 5.0 - 0.7 + (lit - 0.42) * 3.0 * smoothstep(0.15, 0.55, heat);
  vec3 c = fire + db >= 0.5
    ? pal(fire + 3.0 + d, 4.0, 8.0)
    : pal(lit * 3.4 + 0.35 + (churn - 0.5) * 0.5 + under * 0.7 + fireL * 1.5 + ambient * 0.9 - rim * 1.0 + d, 0.0, 3.0);
  gl_FragColor = vec4(c, 1.0);
}
`

const GROUND_VERT = /* glsl */ `
varying vec3 vW;
void main() {
  vec4 w = modelMatrix * vec4(position, 1.0);
  vW = w.xyz;
  gl_Position = projectionMatrix * viewMatrix * w;
}
`

const GROUND_FRAG = /* glsl */ `
${COMMON}
varying vec3 vW;
void main() {
  if (uT < 0.0) discard; // the ground lights AT the blast, never before it
  float t = uT;
  float d = length(vW.xz);
  float b = bayer4(gl_FragCoord.xy);
  // ground lit by the fireball, then a lingering glow under the stem
  float flash = 3.2 * exp(-t / 0.22) / (1.0 + d * d * 0.05);
  float glow = 1.1 * exp(-t / 1.5) / (1.0 + d * d * 0.22);
  // shockwave ring racing out along the ground
  float rs = 0.8 + 34.0 * easeOut(t / 1.15);
  float w = 0.35 + 1.4 * t;
  float ring = (1.0 - smoothstep(0.0, w, abs(d - rs))) * (1.0 - smoothstep(0.25, 1.15, t)) * 1.35;
  float ringN = ring * (0.75 + 0.5 * noise3(vec3(vW.xz * 0.9, t * 2.0)));
  float level = (flash + glow + ringN) * 4.2 * (1.0 - uFade);
  float dd = (b - 0.5) * 0.8;
  if (level + dd < 1.0) discard;
  gl_FragColor = vec4(pal(level + 3.0 + dd, 4.0, 8.0), 1.0);
}
`

const SHELL_VERT = /* glsl */ `
varying vec3 vN;
varying vec3 vV;
void main() {
  vec4 w = modelMatrix * vec4(position, 1.0);
  vN = normalize(mat3(modelMatrix) * normal);
  vV = normalize(cameraPosition - w.xyz);
  gl_Position = projectionMatrix * viewMatrix * w;
}
`

const SHELL_FRAG = /* glsl */ `
${COMMON}
varying vec3 vN;
varying vec3 vV;
void main() {
  if (uT < 0.0) discard; // the condensation shell is a blast-frame ring
  float b = bayer4(gl_FragCoord.xy);
  float rim = 1.0 - abs(dot(normalize(vN), vV));
  float life = 1.0 - smoothstep(0.05, 0.5, uT);
  float level = pow(rim, 3.0) * 5.5 * life + (b - 0.5) * 0.8;
  if (level < 1.1) discard;
  gl_FragColor = vec4(pal(level + 3.0, 4.0, 8.0), 1.0);
}
`

function puffAttributes(): { p: Float32Array; q: Float32Array } {
  // deterministic so QA frames repeat exactly
  let s = 0x9e3779b9
  const rand = () => ((s = (s * 1664525 + 1013904223) >>> 0) / 4294967296)
  const p = new Float32Array(PUFFS * 4)
  const q = new Float32Array(PUFFS * 4)
  for (let i = 0; i < PUFFS; i++) {
    const role = i === 0 ? 0 : i <= CAP ? 1 : i <= CAP + STEM ? 2 : 3
    p.set([role, rand(), rand(), rand()], i * 4)
    q.set([rand(), rand(), rand(), rand()], i * 4)
  }
  return { p, q }
}

/**
 * Build the scene, compile its programs and upload its buffers. Throws when
 * WebGL2 is unavailable (the caller keeps the CSS cloud).
 */
export function createBoom({ host, clock, groundFrac, ignite }: BoomOptions): Boom {
  const canvas = document.createElement('canvas')
  canvas.className = 'dtn-boom-canvas'
  // Probe the context ourselves: a missing (or software-only) WebGL2 throws
  // quietly here instead of three logging an error, and the caller keeps
  // the CSS cloud.
  const context = canvas.getContext('webgl2', {
    alpha: true,
    antialias: false,
    depth: true,
    stencil: false,
    powerPreference: 'high-performance',
    failIfMajorPerformanceCaveat: true,
  })
  if (!context) throw new Error('boom3d: no hardware WebGL2')
  const renderer = new WebGLRenderer({ canvas, context })
  renderer.setPixelRatio(1)
  renderer.setClearColor(0x000000, 0)
  // Past the probe: the canvas goes live. Until it is in the DOM the scene
  // renders off-screen and the stage shows no cloud at all.
  host.appendChild(canvas)

  const uniforms = {
    uT: { value: -1 },
    uFade: { value: 0 },
    uPal: { value: readPalette(host) },
    uIgnite: { value: new Vector2() },
  }

  const base = new IcosahedronGeometry(1, 1)
  const puffGeo = new InstancedBufferGeometry().copy(base as unknown as InstancedBufferGeometry)
  base.dispose()
  const { p, q } = puffAttributes()
  puffGeo.setAttribute('aP', new InstancedBufferAttribute(p, 4))
  puffGeo.setAttribute('aQ', new InstancedBufferAttribute(q, 4))
  puffGeo.instanceCount = PUFFS
  const puffMat = new ShaderMaterial({ uniforms, vertexShader: PUFF_VERT, fragmentShader: PUFF_FRAG })
  const puffs = new Mesh(puffGeo, puffMat)
  puffs.frustumCulled = false

  const groundGeo = new PlaneGeometry(90, 90)
  groundGeo.rotateX(-Math.PI / 2)
  const groundMat = new ShaderMaterial({ uniforms, vertexShader: GROUND_VERT, fragmentShader: GROUND_FRAG, depthWrite: false })
  const ground = new Mesh(groundGeo, groundMat)
  ground.renderOrder = -1

  const shellGeo = new SphereGeometry(1, 28, 14, 0, Math.PI * 2, 0, Math.PI / 2)
  const shellMat = new ShaderMaterial({ uniforms, vertexShader: SHELL_VERT, fragmentShader: SHELL_FRAG, depthWrite: false })
  const shell = new Mesh(shellGeo, shellMat)

  const scene = new Scene()
  scene.add(ground, puffs, shell)
  const camera = new PerspectiveCamera(36, 1, 0.5, 240)

  // Framing: the blast point sits at groundFrac of the viewport and the
  // grown cap tops out near 22% from the top, under the knocked-back clock.
  // Narrow screens pull the camera back until the cap's width fits.
  let pixel = 4
  let baseDist = 34
  const camY = 2.4
  const layout = () => {
    const vw = window.innerWidth
    const vh = window.innerHeight
    pixel = vw < 700 ? 3 : 4
    const w = Math.ceil(vw / pixel)
    const h = Math.ceil(vh / pixel)
    renderer.setSize(w, h, false)
    canvas.style.width = `${w * pixel}px`
    canvas.style.height = `${h * pixel}px`
    camera.aspect = w / h
    camera.updateProjectionMatrix()
    const tanV = Math.tan((camera.fov * Math.PI) / 360)
    // the cap tops out (~10.5 units) 34% from the top, tucked just under the
    // knocked-back clock; the cap's ~7.5-unit half-width (plus margin) must
    // fit the width
    const span = groundFrac - 0.34
    baseDist = Math.max(10.5 / (2 * span * tanV), 8.2 / (tanV * camera.aspect))
    // CSS px per world unit at the blast point, to size the ignition to the
    // DOM pixel bomb (the push-in starts from 1 at the blast)
    const unitPx = (h * pixel) / (2 * tanV * Math.hypot(baseDist, camY))
    uniforms.uIgnite.value.set(ignite.up / unitPx, ignite.radius / unitPx)
  }
  layout()
  window.addEventListener('resize', layout)

  const frame = (ms: number) => {
    const t = ms / 1000
    uniforms.uT.value = t
    uniforms.uFade.value = Math.min(Math.max((t - 2.15) / 0.75, 0), 1)
    shell.scale.setScalar(1 + 17 * (1 - Math.pow(1 - Math.min(Math.max(t, 0) / 0.5, 1), 3)))
    shell.visible = t < 0.55
    // slow push-in, then the blast shake: roll + pitch jolts over ~800ms,
    // riding on top of the DOM shake that already moves the whole canvas
    const push = 1 - 0.08 * (1 - Math.pow(1 - Math.min(Math.max(t, 0) / 2.6, 1), 3))
    const dist = baseDist * push
    const tanV = Math.tan((camera.fov * Math.PI) / 360)
    const pitch = Math.atan((1 - 2 * (1 - groundFrac)) * tanV) - Math.atan(camY / dist)
    const shake = t > 0 && t < 0.8 ? (1 - t / 0.8) ** 2 : 0
    camera.position.set(0, camY, dist)
    camera.rotation.set(
      pitch + shake * 0.012 * Math.sin(t * 97),
      0,
      shake * 0.02 * Math.sin(t * 61 + 1.3),
    )
    renderer.render(scene, camera)
  }
  frame(-1000)

  let stopFrames: (() => void) | undefined
  let disposed = false
  return {
    start() {
      if (disposed || stopFrames) return
      // One rAF loop for the whole app (PLAN Ground rules): ride the
      // PhaseEngine frame bus. Its Date.now() callback timestamp is wall
      // time, not the blast clock, so the clock is polled per frame. Only a
      // started boom may show: the DOM bomb prop owns the pre-blast frame.
      canvas.dataset.running = 'true'
      stopFrames = subscribeFrames(() => frame(clock()))
    },
    dispose() {
      if (disposed) return
      disposed = true
      stopFrames?.()
      window.removeEventListener('resize', layout)
      puffGeo.dispose()
      puffMat.dispose()
      groundGeo.dispose()
      groundMat.dispose()
      shellGeo.dispose()
      shellMat.dispose()
      // dispose() unhooks three's context-lost listener, so dropping the
      // context right after logs nothing; it frees the GPU context at once
      // instead of waiting for GC (browsers cap live contexts)
      renderer.dispose()
      renderer.forceContextLoss()
      canvas.remove()
    },
  }
}
