import { defineConfig, loadEnv } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'

// Dev RPC proxy: the browser talks same-origin to /rpc and vite forwards to
// the real provider server-side. Kills CORS entirely in dev — including the
// opaque "no Access-Control-Allow-Origin" console errors that providers emit
// on rate-limit responses (their error pages ship without CORS headers).
//
//   .env.local:  VITE_RPC_URL=/rpc
//                VITE_RPC_PROXY_TARGET=https://eth-sepolia.g.alchemy.com/v2/<key>
//
// A production build with VITE_RPC_URL set to a full https URL skips the
// proxy and talks to the provider directly (CORS is fine there when the
// provider isn't erroring).
export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), '')
  const target = env.VITE_RPC_PROXY_TARGET || ''
  const proxy =
    target.startsWith('http') && new URL(target).pathname.length > 1
      ? {
          '/rpc': {
            target: new URL(target).origin,
            rewrite: () => new URL(target).pathname,
            changeOrigin: true,
          },
        }
      : undefined

  return {
    plugins: [react(), tailwindcss()],
    server: proxy ? { proxy } : undefined,
  }
})
