import StakeCard from '../components/StakeCard'
import CarpetBombCard from '../components/CarpetBombCard'

export default function Stake() {
  return (
    <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
      <StakeCard />
      <CarpetBombCard />
    </div>
  )
}
