import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import '@rainbow-me/rainbowkit/styles.css'
/* redesign font roles (B0): IBM Plex Sans = body, IBM Plex Mono = tabular data.
   DISPLAY stays GeistPixel (index.css); DSEG7 is self-hosted in tokens.css. */
import '@fontsource-variable/ibm-plex-sans'
import '@fontsource/ibm-plex-mono/400.css'
import '@fontsource/ibm-plex-mono/500.css'
import '@fontsource/ibm-plex-mono/600.css'
import './index.css'
import App from './App'

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App />
  </StrictMode>,
)
