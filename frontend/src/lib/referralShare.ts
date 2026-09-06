import { descriptorAbi, stakerAbi } from './abi.ts'

export const REFERRAL_QUIPS = [
  'my frog has a staking position and a pot problem. come make it worse.',
  'i came for the pixels. stayed to fight strangers over a pot.',
  'ten ladder spots. one pot. the group chat is about to get ugly.',
  'we put greed on a timer and gave it a frog.',
  'the chart has waves. the frogs have issues. the pot has my attention.',
  'buy the frog. feed the clock. fight for the pot.',
  'trade fees feed the stakers. the group chat feeds the chaos.',
  'fresh round. fresh chart. same questionable friends.',
  'brought a pepe to a knife fight. everyone else brought one too.',
  'frog jpeg. defi brain. group chat judgment.',
  'the clock is ticking and my pepe is getting ideas.',
  'the pot is public. the beef is personal.',
  'staking frogs and making terrible jokes. finally, a use for my skill set.',
  'attention span of a degen. life cycle of a phoenix. face of a frog.',
  'the chart waves. the clock ticks. the group chat loses composure.',
  'my pepe demands a place on the ladder. management has approved the request.',
  'launchpad slop had its turn. the frogs brought a timer.',
  'they gave crypto another ticker. we gave a frog a comeback arc.',
  'this frog runs on fees, pixels and profoundly unserious behaviour.',
  'the ladder has ten seats and my frog has main character syndrome.',
] as const

// Cosmetic randomness. Rerolling always gives a different line.
export function pickReferralQuip(previous = -1, random = Math.random): number {
  const hasPrevious = previous >= 0 && previous < REFERRAL_QUIPS.length
  const index = Math.floor(random() * (REFERRAL_QUIPS.length - Number(hasPrevious)))
  return hasPrevious && index >= previous ? index + 1 : index
}

export function referralPostText(quip: string, chainId: number): string {
  const network = chainId === 84532 ? 'Base Sepolia playtest'
    : chainId === 11155111 ? 'Sepolia playtest'
      : chainId === 31337 ? 'local playtest' : ''
  return `${quip}\n\npositive sum pepes${network ? ` · ${network}` : ''}`
}

export function referralXIntent(text: string, link: string): string {
  // Keep the entire hash-router URL, including the full uint256 NFT ID and
  // its registry/network scope. Web Intent does not support image uploads.
  return `https://x.com/intent/tweet?${new URLSearchParams({ text, url: link })}`
}

type Address = `0x${string}`
type Read = (to: Address, abi: readonly unknown[], name: string, args?: readonly unknown[]) => Promise<unknown>

export async function loadReferralPepe(staker: Address, tokenId: bigint, read: Read): Promise<string> {
  const [dna, descriptor] = await Promise.all([
    read(staker, stakerAbi, 'dnaOf', [tokenId]) as Promise<bigint>,
    read(staker, stakerAbi, 'descriptor') as Promise<Address>,
  ])
  // Minted art comes from the selected position's on-chain DNA and renderer.
  // Address-based previews and keccak(tokenId) may depict a different Pepe.
  return read(descriptor, descriptorAbi, 'renderSVG', [dna]) as Promise<string>
}

export async function referralPepePng(svg: string): Promise<Blob> {
  const source = URL.createObjectURL(new Blob([svg], { type: 'image/svg+xml' }))
  try {
    const image = new Image()
    image.src = source
    await image.decode()
    const canvas = document.createElement('canvas')
    canvas.width = canvas.height = 828 // Twelve pixels per on-chain art pixel.
    const context = canvas.getContext('2d')
    if (!context) throw new Error('Image export unavailable')
    context.imageSmoothingEnabled = false
    context.drawImage(image, 0, 0, canvas.width, canvas.height)
    return await new Promise<Blob>((resolve, reject) => canvas.toBlob(
      blob => blob ? resolve(blob) : reject(new Error('Image export unavailable')),
      'image/png',
    ))
  } finally {
    URL.revokeObjectURL(source)
  }
}
