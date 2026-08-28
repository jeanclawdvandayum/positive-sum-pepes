import StakeCard from '../components/StakeCard'
import CarpetBombCard from '../components/CarpetBombCard'
import ReferralCard from '../components/ReferralCard'

export default function Stake() {
  return (
    <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
      <StakeCard />
      <div className="space-y-4">
        <CarpetBombCard />
        <ReferralCard />
      </div>
    </div>
  )
}
