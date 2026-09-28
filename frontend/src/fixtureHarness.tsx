// Isolated visual-verification harness entry — mounts the REAL app unchanged.
// Data comes from src/fixtureRpc.ts via the vite.fixture.config alias:
// an ACTIVE round with a 10-seat ladder and a 137.5 mixETH pot. Read-only
// fixtures; no chain, no signing. Served on port 4181 only.
import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import App from './App'
import './index.css'

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App />
  </StrictMode>,
)
