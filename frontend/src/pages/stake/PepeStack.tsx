import { usePepeDnaVersion } from '../../lib/usePepeDnaVersion'
import { useState } from 'react'
import { usePepeDna } from '../../lib/usePepeDna'
import { renderPepeSvg } from '../../lib/pepeRender'

function Face({ id, staker }: { id: bigint; staker?: `0x${string}` }) {
  const version = usePepeDnaVersion(staker)
  const { data, isError } = usePepeDna(staker, id)
  return data === undefined || version === undefined
    ? <span className="text-xs text-text-lo">{isError ? 'art unavailable' : 'loading pepe…'}</span>
    : <span className="block h-full w-full [&>svg]:h-full [&>svg]:w-full" dangerouslySetInnerHTML={{ __html: renderPepeSvg(data, version) }} />
}

export default function PepeStack({ ids, staker }: { ids: bigint[]; staker?: `0x${string}` }) {
  const [selected, setSelected] = useState<string>()
  const [shuffle, setShuffle] = useState(0)
  const top = ids.find(id => id.toString() === selected) ?? ids[0]
  const ordered = [top, ...ids.filter(id => id !== top)].filter((id): id is bigint => id !== undefined)
  // Keep every NFT selectable, including large collections, without widening the panel.
  const visible = ordered.slice(0, 6)
  function choose(id: bigint) { setSelected(id.toString()); setShuffle(n => n + 1) }
  return <div className="min-w-0">
    <div className="st-pepe-deck" aria-label="your pepe card stack">
      {visible.map((id, depth) => <button key={id.toString()} type="button"
        className={`st-pepe-card ${depth === 0 ? 'st-pepe-card--top' : ''}`}
        style={{ zIndex: visible.length - depth, transform: `translate(${depth * Math.min(24, 40 / Math.max(1, visible.length - 1))}px, ${depth * 7}px) rotate(${depth === 0 ? -2 : depth * 3}deg)` }}
        aria-label={depth === 0 ? 'Show next pepe' : `Bring pepe ${id} to the top`}
        onClick={() => choose(depth === 0 ? ordered[1] ?? id : id)}>
        <span key={depth === 0 ? shuffle : 'back'} className={depth === 0 && shuffle > 0 ? 'st-pepe-shuffle block h-full w-full' : 'block h-full w-full'}>
          <Face id={id} staker={staker} />
        </span>
      </button>)}
    </div>
    {ids.length > 1 && <div className="mt-3 flex flex-wrap items-center gap-2">
      <p className="text-xs text-text-lo">{ids.length} pepes · tap a card to shuffle</p>
      {ids.length > 6 && <button type="button" className="text-xs text-accent underline" onClick={() => {
        const index = ids.findIndex(id => id === top)
        choose(ids[(index + 1) % ids.length])
      }}>next pepe</button>}
    </div>}
  </div>
}
