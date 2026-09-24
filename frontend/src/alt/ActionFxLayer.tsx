// Alt-only FX stage (PLAN Feature 3): a fixed, pointer-dead portal below the
// toast stack (9000 < 10000). Mounted once inside AltShell; the original UI
// never renders it, and actionFx stays a no-op without this subscriber.
// The hatch reveal is an interactive modal, so it gets its own portal outside
// the aria-hidden layer and ends only when the user dismisses it.

import { useCallback, useEffect, useSyncExternalStore } from 'react'
import { createPortal } from 'react-dom'
import { actionFx, type FxEvent } from '../lib/actionFx'
import { FX_EFFECTS } from './fx/effects'
import DetonationSetPiece from './fx/DetonationSetPiece'
import HatchModal from './fx/HatchModal'

const HARD_STOP_MS = 4000
/** The set-piece runs ~5.6s; its own timer ends it, this is the backstop. */
const DETONATE_HARD_STOP_MS = 7000

function ActiveFx({ event }: { event: FxEvent }) {
  const onDone = useCallback(() => actionFx.done(event.id), [event.id])
  const { kind } = event
  useEffect(() => {
    const timer = setTimeout(onDone, kind === 'detonate' ? DETONATE_HARD_STOP_MS : HARD_STOP_MS)
    return () => clearTimeout(timer)
  }, [onDone, kind])
  if (kind === 'detonate') return <DetonationSetPiece onDone={onDone} />
  if (kind === 'claimPredeposit') return null
  const Effect = FX_EFFECTS[kind]
  return <Effect event={event} onDone={onDone} />
}

export default function ActionFxLayer() {
  const events = useSyncExternalStore(actionFx.subscribe, actionFx.snapshot)
  // One hatch at a time; a second claim's reveal waits for the first to close.
  const hatch = events.find(event => event.kind === 'claimPredeposit')
  const onHatchDone = useCallback(() => { if (hatch) actionFx.done(hatch.id) }, [hatch])
  return <>
    {createPortal(
      <div className="fx-layer" aria-hidden="true">
        {events.filter(event => event.kind !== 'claimPredeposit').map(event => <ActiveFx key={event.id} event={event} />)}
      </div>,
      document.body,
    )}
    {hatch && <HatchModal key={hatch.id} event={hatch} onDone={onHatchDone} />}
  </>
}
