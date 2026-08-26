import SwapCard from '../components/SwapCard'
import CurveChart from '../components/CurveChart'
import StatsPanel from '../components/StatsPanel'

export default function Trade() {
  return (
    <div className="space-y-4">
      <div className="grid grid-cols-1 gap-4 lg:grid-cols-5">
        <div className="lg:col-span-2">
          <SwapCard />
        </div>
        <div className="lg:col-span-3">
          <CurveChart />
        </div>
      </div>
      <StatsPanel />
    </div>
  )
}
