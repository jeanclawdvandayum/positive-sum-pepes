/// the mix token mark — round badge, peach ring, grayscale ETH diamond.
/// default: sized against surrounding text (1.3em); pass px for a fixed size
/// (inline style wins over the tailwind default, so chips can go bigger).
/// dark: subtle halo lifts the navy disc off dark panels.
export default function MixLogo({ px, className = '' }: { px?: number; className?: string }) {
  return (
    <img
      src="/tokens/mixeth.svg"
      alt="mixETH"
      draggable={false}
      style={px ? { height: px, width: px } : undefined}
      className={`inline-block h-[1.3em] w-[1.3em] shrink-0 align-[-0.32em] dark:drop-shadow-[0_0_1px_rgba(255,255,255,0.55)] ${className}`}
    />
  )
}
