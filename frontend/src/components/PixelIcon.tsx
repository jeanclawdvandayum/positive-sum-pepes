/// Pixel-art card icons — hand-drawn 16×16 grids in the pepe palette,
/// rendered as horizontal <rect> runs: the same visual style as the
/// on-chain renderSVG output (byte-pair RLE art). shapeRendering=
/// "crispEdges" keeps every run pixel-sharp at any size.

type Grid = string[]

// letters are LOCAL to each grid — palettes below give them color
const ICONS: Record<string, Grid> = {
  // bonding curve: dark axes, sky stair up-right, gold node at the top
  chart: [
    '................',
    '.a...........yy.',
    '.a...........yy.',
    '.a..........s...',
    '.a..........s...',
    '.a.......sss....',
    '.a.......ss.....',
    '.a.....ss.......',
    '.a.....ss.......',
    '.a...ss.........',
    '.a...ss.........',
    '.a.ss...........',
    '.ass............',
    '.aaaaaaaaaaaaaa.',
    '................',
    '................',
  ],
  // predeposit: two stacked gold coins (one shifted, one waiting)
  coin: [
    '................',
    '................',
    '................',
    '..dddddddddddd..',
    '..dllggggggggd..',
    '..dggggggggggd..',
    '..dddddddddddd..',
    '................',
    '...dddddddddddd.',
    '...dllggggggggd.',
    '...dggggggggggd.',
    '...dddddddddddd.',
    '................',
    '................',
    '................',
    '................',
  ],
  // stake & earn: diamond with light glint (pepe diamond-skin ramp)
  diamond: [
    '................',
    '................',
    '.....dddddd.....',
    '...ddglggggdd...',
    '..dgllgggggggd..',
    '.dggllggggggggd.',
    '..dggggggggggd..',
    '...dggggggggd...',
    '....dggggggd....',
    '.....dggggd.....',
    '......dggd......',
    '.......dd.......',
    '................',
    '................',
    '................',
    '................',
  ],
  // carpet bomb: shades-black bomb, steel glint, rope fuse, red spark
  bomb: [
    '............ry..',
    '...........yr...',
    '..........ww....',
    '.........ww.....',
    '........ww......',
    '.....kkkkkk.....',
    '...kkkkkkkkkk...',
    '..kllkkkkkkkkk..',
    '..kllkkkkkkkkk..',
    '..kkkkkkkkkkkk..',
    '..kkkkkkkkkkkk..',
    '..kkkkkkkkkkkk..',
    '...kkkkkkkkkk...',
    '....kkkkkkkk....',
    '......kkkk......',
    '................',
  ],
  // positive sum: sky + emerald arrows chasing around the loop
  recycle: [
    '................',
    '...sss..........',
    '..ss..ssss..gg..',
    '.ss.......ssggg.',
    '.ss........sgg..',
    '.s.........sg...',
    '.s.........sg...',
    '.s.........sg...',
    '.s.........sg...',
    '.ss.......ss....',
    '.sss.....sss....',
    '..sssssssss.....',
    '................',
    '................',
    '................',
    '................',
  ],
  // your keys: shield with a gold keyhole
  shield: [
    '................',
    '................',
    '...dddddddddd...',
    '..dssssssssssd..',
    '..dssssssssssd..',
    '..dssssyyssssd..',
    '..dssssyyssssd..',
    '..dssyyyyyyssd..',
    '..dssyyyyyyssd..',
    '..dssssssssssd..',
    '...dssssssssd...',
    '....dssssssd....',
    '.....dssssd.....',
    '.......dd.......',
    '................',
    '................',
  ],
}

// letter -> fill, per icon (deep shades — icons sit on bright gradient tiles)
const PALETTES: Record<string, Record<string, string>> = {
  chart: { a: '#2D5034', s: '#0369A1', y: '#B45309' },
  coin: { d: '#8C6A1D', l: '#F7E7A8', g: '#E8B93E' },
  diamond: { d: '#2E6E74', g: '#5FE3B0', l: '#D8FBF3' },
  bomb: { k: '#23282D', l: '#C2C8D4', w: '#8C6A1D', r: '#D0483E', y: '#F0DA7B' },
  recycle: { s: '#0369A1', g: '#15803D' },
  shield: { d: '#075985', s: '#38BDF8', y: '#E8B93E' },
}

export function PixelIcon({ name, size = 22 }: { name: string; size?: number }) {
  const rows = ICONS[name]
  const pal = PALETTES[name]
  if (!rows || !pal) return null
  const runs: { x: number; y: number; w: number; fill: string }[] = []
  rows.forEach((row, y) => {
    let x = 0
    while (x < row.length) {
      const ch = row[x]
      if (ch === '.') {
        ++x
        continue
      }
      let w = 1
      while (x + w < row.length && row[x + w] === ch) ++w
      runs.push({ x, y, w, fill: pal[ch] })
      x += w
    }
  })
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 16 16"
      shapeRendering="crispEdges"
      aria-hidden="true"
    >
      {runs.map((r, i) => (
        <rect key={i} x={r.x} y={r.y} width={r.w} height={1} fill={r.fill} />
      ))}
    </svg>
  )
}
