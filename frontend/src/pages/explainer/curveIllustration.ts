// Display-only phase math. Never use illustration coordinates for trade quotes.
export function illustrationLogMultiplier(phase: number): number {
  const tilted = phase - Math.sin(2 * Math.PI * phase) / (2 * Math.PI)
  const root = Math.cbrt(1 + Math.abs(tilted))
  const softened = tilted / (root * root + root + 1)
  return Math.log(1000) / (Math.cbrt(11) - 1) * softened
}

// The thumbnail shows the first two waves on a logarithmic price axis.
export function illustrationPoint(phase: number): { x: number; y: number } {
  return {
    x: 28 + 182 * phase,
    y: 210 - 180 * illustrationLogMultiplier(phase) / illustrationLogMultiplier(2),
  }
}

export const illustrationFrames = Array.from({ length: 81 }, (_, i) => {
  const { x, y } = illustrationPoint(i / 40)
  return `${i * 1.25}% { transform: translate(${x.toFixed(2)}px, ${y.toFixed(2)}px); }`
}).join('\n')
