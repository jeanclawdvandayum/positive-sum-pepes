import { useEffect, useMemo, useRef, useState } from 'react'

/**
 * Dice3D — a crisp pseudo-3D die for the "refresh suspects" button.
 *
 * Static face on mount; whenever `seed` changes (a re-roll click) the cube
 * tumbles through the other faces and lands on a random pip face.
 * Pure CSS 3D (no canvas), respects prefers-reduced-motion.
 */

// pip grid positions [row, col] on a 3×3 grid, per face value
const PIPS: Record<number, [number, number][]> = {
  1: [[2, 2]],
  2: [[1, 3], [3, 1]],
  3: [[1, 3], [2, 2], [3, 1]],
  4: [[1, 1], [1, 3], [3, 1], [3, 3]],
  5: [[1, 1], [1, 3], [2, 2], [3, 1], [3, 3]],
  6: [[1, 1], [1, 3], [2, 1], [2, 3], [3, 1], [3, 3]],
}

// cube rotation that brings each face to the front
const FACE_TURN: Record<number, { x: number; y: number }> = {
  1: { x: 0, y: 0 },
  2: { x: -90, y: 0 },
  3: { x: 0, y: -90 },
  4: { x: 0, y: 90 },
  5: { x: 90, y: 0 },
  6: { x: 0, y: 180 },
}

// which value lives on which cube face
const FACE_PLACEMENT: { value: number; transform: (half: number) => string }[] = [
  { value: 1, transform: h => `translateZ(${h}px)` },
  { value: 6, transform: h => `rotateY(180deg) translateZ(${h}px)` },
  { value: 3, transform: h => `rotateY(90deg) translateZ(${h}px)` },
  { value: 4, transform: h => `rotateY(-90deg) translateZ(${h}px)` },
  { value: 2, transform: h => `rotateX(90deg) translateZ(${h}px)` },
  { value: 5, transform: h => `rotateX(-90deg) translateZ(${h}px)` },
]

const CSS = `
.d3d-scene{display:inline-block;perspective:calc(var(--d3d-size) * 7);width:var(--d3d-size);height:var(--d3d-size);vertical-align:middle}
.d3d-cube{display:block;width:100%;height:100%;position:relative;transform-style:preserve-3d;transition:transform 1.05s cubic-bezier(.18,.7,.22,1)}
.d3d-face{position:absolute;inset:0;border-radius:22%!important;background:#F6F2E7;border:1px solid #1d2732;display:grid;grid-template-rows:repeat(3,1fr);grid-template-columns:repeat(3,1fr);padding:14%}
.d3d-pip{border-radius:50%!important;background:#1d2732;align-self:center;justify-self:center;width:62%;height:62%}
@media (prefers-reduced-motion: reduce){.d3d-cube{transition:none}}
`

export default function Dice3D({ size = 20, seed = 0 }: { size?: number; seed?: number }) {
  const [face, setFace] = useState(() => 1 + Math.floor(Math.random() * 6))
  const [turn, setTurn] = useState(() => ({ spins: 0, ...FACE_TURN[face] }))
  const first = useRef(true)

  useEffect(() => {
    if (first.current) { first.current = false; return }
    // tumble: 2 full spins plus a fresh random landing face
    const landed = 1 + Math.floor(Math.random() * 6)
    setFace(landed)
    setTurn(t => ({
      spins: t.spins + 2,
      x: FACE_TURN[landed].x + (Math.random() < 0.5 ? 0 : 360),
      y: FACE_TURN[landed].y,
    }))
  }, [seed])

  const faces = useMemo(() => FACE_PLACEMENT.map(({ value, transform }) => (
    <div className="d3d-face" key={value} style={{ transform: transform(size / 2) }}>
      {PIPS[value].map(([r, c], i) => (
        <span key={i} className="d3d-pip" style={{ gridRow: r, gridColumn: c }} />
      ))}
    </div>
  )), [size])

  return (
    <span className="d3d-scene" style={{ ['--d3d-size' as string]: `${size}px` }} aria-hidden="true">
      <style>{CSS}</style>
      <span
        className="d3d-cube"
        style={{ transform: `rotateX(${turn.spins * 360 + turn.x}deg) rotateY(${turn.spins * 360 + turn.y}deg)` }}
      >
        {faces}
      </span>
    </span>
  )
}
