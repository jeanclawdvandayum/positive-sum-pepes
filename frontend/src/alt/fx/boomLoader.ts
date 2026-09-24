// Lazy entry for the detonation's 3D scene (boom3d.ts + three.js, its own
// chunk). The armed alt detonate button starts the fetch early and the
// set-piece awaits the same promise; a failed fetch clears it so the next
// attempt retries (the set-piece falls back to the CSS cloud meanwhile).

import type * as Boom3d from './boom3d'

let pending: Promise<typeof Boom3d> | null = null

export function loadBoom3d(): Promise<typeof Boom3d> {
  pending ??= import('./boom3d').catch((error: unknown) => {
    pending = null
    throw error
  })
  return pending
}
