import { useId } from 'react'
import { parseAmountToWad, wadToExact } from '../lib/format'

export default function AmountSlider({ amount, maximum, onChange, disabled, label }: {
  amount: string
  maximum: bigint | undefined
  onChange: (amount: string) => void
  disabled?: boolean
  label: string
}) {
  const id = useId()
  const limit = maximum ?? 0n
  const value = parseAmountToWad(amount)
  const fraction = limit > 0n ? Number((value > limit ? limit : value) * 10000n / limit) : 0
  return <div className="sell-slider py-3">
    <label htmlFor={id} className="flex justify-between gap-3 text-xs">
      <span>{label}</span><output htmlFor={id}>{fraction / 100}%</output>
    </label>
    <input id={id} className="my-2 block w-full min-w-0 accent-current" type="range"
      min="0" max="10000" step="1" value={fraction}
      disabled={disabled || limit <= 0n}
      aria-valuetext={`${fraction / 100}%`}
      onChange={e => onChange(wadToExact(limit * BigInt(e.target.value) / 10000n))} />
    <div className="sell-slider-ends flex justify-between text-xs"><span>0%</span><span>100%</span></div>
  </div>
}
