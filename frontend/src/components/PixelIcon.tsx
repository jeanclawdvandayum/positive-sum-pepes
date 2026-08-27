/// Pixel-art icons — hand-drawn 24×24 grids in the pepe palette, rendered as
/// horizontal <rect> runs (same visual language as the on-chain RLE art).
/// shapeRendering="crispEdges" keeps every run pixel-sharp at any size.

type Grid = string[]

// letters are LOCAL to each grid — palettes below give them color
const ICONS: Record<string, Grid> = {
  // bonding curve: one connected log staircase, gold coin flush on the summit
  chart: [
    '........................',
    '................oooo....',
    '...............oYYYYo...',
    '..oo...........oYYYYo...',
    '..oo...........oyyyyo...',
    '..oo............oooo....',
    '..oo............sSSs....',
    '..oo............sSSs....',
    '..oo............sSSs....',
    '..oo........oooosSSs....',
    '..oo........sSSSSSSs....',
    '..oo........sSSSSSSs....',
    '..oo........sSSSSSSs....',
    '..oo....oooosSSSSSSs....',
    '..oo....sSSSSSSSSSSs....',
    '..oo....sSSSSSSSSSSs....',
    '..oo....sSSSSSSSSSSs....',
    '..oooooosSSSSSSSSSSs....',
    '..ooSSSSSSSSSSSSSSSs....',
    '..ooSSSSSSSSSSSSSSSs....',
    '..aaaaaaaaaaaaaaaaaaaa..',
    '..aaaaaaaaaaaaaaaaaaaa..',
    '........................',
    '........................',
  ],
  // predeposit: gold-framed pixel window, 4 sky panes, glint, sill
  window: [
    '........................',
    '........................',
    '........................',
    '........................',
    '....oooooooooooooooo....',
    '....oYYYYYYYYYYYYYYo....',
    '....oYSWSSSYYSSSSSYo....',
    '....oYSSWSSYYSSSSSYo....',
    '....oYSSSWSYYSSSSSYo....',
    '....oYSSSSSYYSSSSSYo....',
    '....oYYYYYYYYYYYYYYo....',
    '....oYYYYYYYYYYYYYYo....',
    '....oYSSSSSYYsssssYo....',
    '....oYSSSSSYYsssssYo....',
    '....oYSSSSSYYsssssYo....',
    '....oYSSSSSYYsssssYo....',
    '....oYYYYYYYYYYYYYYo....',
    '....oooooooooooooooo....',
    '...yyyyyyyyyyyyyyyyyy...',
    '...dddddddddddddddddd...',
    '........................',
    '........................',
    '........................',
    '........................',
  ],
  // stake & earn: symmetric faceted gem, shine streak + sparkles
  diamond: [
    '........................',
    '...................W....',
    '..................WWW...',
    '...................W....',
    '........................',
    '........................',
    '........oooooooo........',
    '.......oGgLLGGgGo.......',
    '......oGgLLGGGGgGo......',
    '.....oGgGGGGGGGGgGo.....',
    '....oGgGGGGGGGGGGgGo....',
    '.....oGGGGGddGGGGGo.....',
    '......oGGGGddGGGGo......',
    '.......oGGGddGGGo.......',
    '...W....oGGddGGo........',
    '..WWW....oGddGo.........',
    '...W......oddo..........',
    '...........oo...........',
    '........................',
    '........................',
    '........................',
    '........................',
    '........................',
    '........................',
  ],
  // carpet bomb: round black orb, steel glint, rope fuse, spark star
  bomb: [
    '........................',
    '........Y...............',
    '.......YWY..............',
    '........Yww.............',
    '..........ww............',
    '...........ww...........',
    '..........wwww..........',
    '..........wYYw..........',
    '..........wYYw..........',
    '.........ooooooo........',
    '........oookkkooo.......',
    '.......ookkkkkkkoo......',
    '......oollkkkkkkkoo.....',
    '......okllkkkkkkkko.....',
    '.....oollkkkkkkkkkoo....',
    '.....ookkkkkkkkkkkoo....',
    '.....ookkkkkkkkkkkoo....',
    '.....ookkkkkkkkkkkoo....',
    '......okkkkkkkkkkko.....',
    '......ookkkkkkkkkoo.....',
    '.......ookkkkkkkoo......',
    '........oookkkooo.......',
    '.........ooooooo........',
    '........................',
  ],
  // positive sum: two-tone green up arrow
  sum: [
    '........................',
    '........................',
    '...........Gg...........',
    '..........GGgg..........',
    '.........GGGggg.........',
    '........GGGGgggg........',
    '.......GGGGGggggg.......',
    '......GGGGGGgggggg......',
    '.....GGGGGGGggggggg.....',
    '....GGGGGGGGgggggggg....',
    '....GGGGGGGGgggggggg....',
    '....GGGGGGGGgggggggg....',
    '..........GGgg..........',
    '..........GGgg..........',
    '..........GGgg..........',
    '..........GGgg..........',
    '..........GGgg..........',
    '..........GGgg..........',
    '..........GGgg..........',
    '..........GGgg..........',
    '........................',
    '........................',
    '........................',
    '........................',
  ],
  // your keys: white chief, deep navy field, gold keyhole
  shield: [
    '........................',
    '........................',
    '........................',
    '......oooooooooooo......',
    '......oLLLLLLLLLLo......',
    '......oLLLLLLLLLLo......',
    '......osssssssssso......',
    '......osssssssssso......',
    '......osssYYYYssso......',
    '......osssYYYYssso......',
    '......osssYYYYssso......',
    '......ossssYYsssso......',
    '......ossssYYsssso......',
    '......ossssYYsssso......',
    '......osssssssssso......',
    '.......osssssssso.......',
    '........osssssso........',
    '.........osssso.........',
    '..........osso..........',
    '...........oo...........',
    '........................',
    '........................',
    '........................',
    '........................',
  ],
  // refresh: sky C-ring with a chunky arrowhead (randomize pepes)
  die: [
    '........................',
    '.....oooooooooooooo.....',
    '....owwwwwwwwwwwwwwo....',
    '....owwwwwwwwwwwwwwo....',
    '....owwppwwwwppwwwwo....',
    '....owwppwwwwppwwwwo....',
    '....owwwwwwwwwwwwwwo....',
    '....owwwwwwwwwwwwwwo....',
    '....owwwwwppwwwwwwwo....',
    '....owwwwwppwwwwwwwo....',
    '....owwwwwwwwwwwwwwo....',
    '....owwwwwwwwwwwwwwo....',
    '....owwppwwwwppwwwwo....',
    '....owwppwwwwppwwwwo....',
    '....owwwwwwwwwwwwwwo....',
    '....owwwwwwwwwwwwwwo....',
    '....oddddddddddddddo....',
    '.....oooooooooooooo.....',
    '........................',
    '........................',
    '........................',
    '........................',
    '........................',
    '........................',
  ],
  // withdraw: open padlock, lifted shackle, gold body
  unlock: [
    '........................',
    '........................',
    '........................',
    '.......wwwwwwwww........',
    '.......w.......w........',
    '.......w.......w........',
    '.......w.......ww.......',
    '.......w................',
    '.......w................',
    '.......w................',
    '.....oooooooooooooo.....',
    '....oyyyyyyyyyyyyyyyo...',
    '....oyyyyyyyyyyyyyyyo...',
    '....oyyyyyddddyyyyyo....',
    '....oyyyyyddddyyyyyo....',
    '....oyyyyyyddyyyyyyo....',
    '....oyyyyyyddyyyyyyo....',
    '....oyyyyyyddyyyyyyo....',
    '....oddddddddddddddo....',
    '.....oooooooooooooo.....',
    '........................',
    '........................',
    '........................',
    '........................',
  ],
}

// letter -> fill, per icon (deep shades — icons sit on bright gradient tiles)
const PALETTES: Record<string, Record<string, string>> = {
  chart: { o: '#0F172A', a: '#14532D', S: '#7DD3FC', s: '#0369A1', Y: '#FDE68A', y: '#D97706' },
  window: { o: '#7C5A16', Y: '#FDE68A', y: '#E8B93E', d: '#8C6A1D', S: '#BAE6FD', s: '#38BDF8', W: '#FFFFFF' },
  diamond: { o: '#134E4A', G: '#0D9488', g: '#0F766E', d: '#115E59', L: '#5EEAD4', W: '#FFFFFF' },
  bomb: { o: '#0B0F14', k: '#2A3138', l: '#9AA7B8', w: '#8C6A1D', Y: '#FDE68A', y: '#F59E0B', W: '#FFFFFF' },
  sum: { G: '#6EE7B7', g: '#059669' },
  shield: { o: '#0F172A', L: '#F8FAFC', s: '#075985', Y: '#FDE68A' },
  die: { o: '#334155', w: '#F8FAFC', p: '#1E293B', d: '#CBD5E1' },
  unlock: { o: '#7C5A16', y: '#E8B93E', d: '#8C6A1D', w: '#94A3B8' },
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
      runs.push({ x, y, w, fill: pal[ch] ?? '#f0f' })
      x += w
    }
  })
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      shapeRendering="crispEdges"
      aria-hidden="true"
      className="inline-block shrink-0 align-[-0.28em]"
    >
      {runs.map((r, i) => (
        <rect key={i} x={r.x} y={r.y} width={r.w} height={1} fill={r.fill} />
      ))}
    </svg>
  )
}
