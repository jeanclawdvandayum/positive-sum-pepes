// Alt-only FX stage (PLAN Feature 3): a fixed, pointer-dead portal below the
// toast stack (9000 < 10000). Mounted once inside AltShell; the original UI
// never renders it, and actionFx stays a no-op without this subscriber.

import { useCallback, useEffect, useSyncExternalStore } from 'react'
import { createPortal } from 'react-dom'
import { actionFx, type FxEvent } from '../lib/actionFx'
import { FX_EFFECTS } from './fx/effects'
import DetonationSetPiece from './fx/DetonationSetPiece'

const HARD_STOP_MS = 4000

function ActiveFx({ event }: { event: FxEvent }) {
  const onDone = useCallback(() => actionFx.done(event.id), [event.id])
  useEffect(() => {
    const timer = setTimeout(onDone, HARD_STOP_MS)
    return () => clearTimeout(timer)
  }, [onDone])
  const { kind } = event
  if (kind === 'detonate') return <DetonationSetPiece onDone={onDone} />
  const Effect = FX_EFFECTS[kind]
  return <Effect event={event} onDone={onDone} />
}

export default function ActionFxLayer() {
  const events = useSyncExternalStore(actionFx.subscribe, actionFx.snapshot)
  return createPortal(
    <div className="fx-layer" aria-hidden="true">
      {events.map(event => <ActiveFx key={event.id} event={event} />)}
    </div>,
    document.body,
  )
}
