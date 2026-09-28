// Isolated visual-verification harness config — NEVER used for production or
// the normal dev server. Serves fixture-harness.html with `lib/rpc` aliased
// to typed read fixtures so the real components render an ACTIVE round with
// a 10-seat ladder and a pot. Read-only: no chain, no signing.
import { defineConfig, loadEnv } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'
import { fileURLToPath } from 'node:url'

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), '')
  const target = env.PSP_RPC_PROXY_TARGET || env.VITE_RPC_PROXY_TARGET || ''
  const proxy =
    target.startsWith('http')
      ? {
          '/rpc': {
            target: new URL(target).origin,
            rewrite: () => new URL(target).pathname + new URL(target).search,
            changeOrigin: true,
          },
        }
      : undefined

  return {
    plugins: [react(), tailwindcss()],
    resolve: {
      alias: [
        {
          // every relative import of lib/rpc (./, ../, ../../) reroutes to
          // the fixture module; the app code itself is untouched
          find: /^(?:\.\.\/|\.\/)+(?:lib\/)?rpc$/,
          replacement: fileURLToPath(new URL('./src/fixtureRpc.ts', import.meta.url)),
        },
      ],
    },
    server: {
      port: 4181,
      strictPort: true,
      proxy,
    },
  }
})
