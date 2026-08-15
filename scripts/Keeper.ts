/**
 * PSP Yield Reinvestment Keeper
 *
 * Monitors a RoundController and calls reinvestYield() when mixETH
 * has accrued enough yield to justify a tx. Designed to run as a
 * long-lived process or via cron.
 *
 * Usage:
 *   npx tsx scripts/Keeper.ts \
 *     --rpc https://mainnet.base.org \
 *     --key 0x... \
 *     --controller 0x... \
 *     [--interval 300] \
 *     [--min-yield-eth 0.001] \
 *     [--gas-multiplier 1.2] \
 *     [--max-retries 3]
 *
 * Env vars (alternative to flags):
 *   KEEPER_RPC_URL, KEEPER_PRIVATE_KEY, KEEPER_CONTROLLER_ADDRESS,
 *   KEEPER_INTERVAL_SEC, KEEPER_MIN_YIELD_ETH, KEEPER_GAS_MULTIPLIER
 */

import { createWalletClient, createPublicClient, http, formatEther, parseEther, type Address } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { parseArgs } from "node:util";

// ─── ABIs (minimal, only what we need) ───

const CONTROLLER_ABI = [
  {
    name: "getReinvestState",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [
      { name: "currentPrice", type: "uint256" },
      { name: "lastPrice", type: "uint256" },
      { name: "hookReserveETH", type: "uint256" },
      { name: "active", type: "bool" },
    ],
  },
  {
    name: "reinvestYield",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [],
    outputs: [],
  },
  {
    name: "hook",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
  },
  {
    name: "mode",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint8" }],
  },
] as const;

// ─── Types ───

interface KeeperConfig {
  rpcUrl: string;
  privateKey: `0x${string}`;
  controllerAddress: Address;
  intervalSec: number;
  minYieldEth: number;
  gasMultiplier: number;
  maxRetries: number;
}

interface ReinvestState {
  currentPrice: bigint;
  lastPrice: bigint;
  hookReserveETH: bigint;
  active: boolean;
}

// ─── Logging ───

const ts = () => new Date().toISOString();

function log(level: string, msg: string, data?: unknown) {
  const prefix = `[${ts()}] [${level.toUpperCase()}]`;
  if (data !== undefined) {
    console.log(prefix, msg, typeof data === "bigint" ? data.toString() : data);
  } else {
    console.log(prefix, msg);
  }
}

// ─── Config ───

function loadConfig(): KeeperConfig {
  const { values } = parseArgs({
    options: {
      rpc: { type: "string" },
      key: { type: "string" },
      controller: { type: "string" },
      interval: { type: "string" },
      "min-yield-eth": { type: "string" },
      "gas-multiplier": { type: "string" },
      "max-retries": { type: "string" },
    },
  });

  const rpcUrl = values.rpc ?? process.env.KEEPER_RPC_URL;
  const privateKey = (values.key ?? process.env.KEEPER_PRIVATE_KEY) as `0x${string}`;
  const controllerAddress = (values.controller ?? process.env.KEEPER_CONTROLLER_ADDRESS) as Address;

  if (!rpcUrl) throw new Error("Missing --rpc or KEEPER_RPC_URL");
  if (!privateKey) throw new Error("Missing --key or KEEPER_PRIVATE_KEY");
  if (!controllerAddress) throw new Error("Missing --controller or KEEPER_CONTROLLER_ADDRESS");

  return {
    rpcUrl,
    privateKey,
    controllerAddress,
    intervalSec: parseInt(values.interval ?? process.env.KEEPER_INTERVAL_SEC ?? "300"),
    minYieldEth: parseFloat(values["min-yield-eth"] ?? process.env.KEEPER_MIN_YIELD_ETH ?? "0.001"),
    gasMultiplier: parseFloat(values["gas-multiplier"] ?? process.env.KEEPER_GAS_MULTIPLIER ?? "1.2"),
    maxRetries: parseInt(values["max-retries"] ?? "3"),
  };
}

// ─── Core Logic ───

async function checkAndReinvest(
  publicClient: ReturnType<typeof createPublicClient>,
  walletClient: ReturnType<typeof createWalletClient>,
  account: ReturnType<typeof privateKeyToAccount>,
  config: KeeperConfig,
  chain: ReturnType<typeof getChain>
): Promise<boolean> {
  // Read current state
  const state = (await publicClient.readContract({
    address: config.controllerAddress,
    abi: CONTROLLER_ABI,
    functionName: "getReinvestState",
  })) as unknown as ReinvestState;

  if (!state.active) {
    log("info", "Round not active, skipping");
    return false;
  }

  // Estimate yield: if mixETH share price increased, the hook's reserves
  // are worth more ETH than accounted for. The delta is the yield.
  // yieldDelta ≈ hookReserveETH * (currentPrice - lastPrice) / currentPrice
  if (state.currentPrice <= state.lastPrice) {
    log("debug", "No yield accrued", {
      currentPrice: state.currentPrice,
      lastPrice: state.lastPrice,
    });
    return false;
  }

  const priceDelta = state.currentPrice - state.lastPrice;
  const yieldEstimate =
    (state.hookReserveETH * priceDelta) / state.currentPrice;
  const yieldEth = Number(formatEther(yieldEstimate));

  log("info", `Yield available: ${yieldEth.toFixed(6)} ETH`, {
    reserve: formatEther(state.hookReserveETH),
    priceDelta: formatEther(priceDelta),
  });

  if (yieldEth < config.minYieldEth) {
    log("info", `Yield below threshold (${config.minYieldEth} ETH), skipping`);
    return false;
  }

  // Estimate gas
  const gasEstimate = await publicClient.estimateContractGas({
    address: config.controllerAddress,
    abi: CONTROLLER_ABI,
    functionName: "reinvestYield",
    account: account.address,
  });

  const gasPrice = await publicClient.getGasPrice();
  const adjustedGasPrice = BigInt(Math.floor(Number(gasPrice) * config.gasMultiplier));
  const txCost = Number(formatEther(gasEstimate * adjustedGasPrice));

  log("info", `TX cost estimate: ${txCost.toFixed(6)} ETH`, {
    gasLimit: gasEstimate.toString(),
    gasPrice: adjustedGasPrice.toString(),
  });

  // Don't reinvest if gas costs more than the yield
  if (txCost > yieldEth * 0.5) {
    log("warn", `Gas cost (${txCost.toFixed(6)}) > 50% of yield (${yieldEth.toFixed(6)}), skipping`);
    return false;
  }

  // Send tx
  log("info", "Sending reinvestYield tx...");

  const hash = await walletClient.writeContract({
    address: config.controllerAddress,
    abi: CONTROLLER_ABI,
    functionName: "reinvestYield",
    chain,
    account,
    gas: gasEstimate,
    gasPrice: adjustedGasPrice,
  });

  log("info", `TX sent: ${hash}`);

  // Wait for receipt
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (receipt.status === "success") {
    log("info", `TX confirmed in block ${receipt.blockNumber}`, {
      gasUsed: receipt.gasUsed.toString(),
    });
    return true;
  } else {
    log("error", `TX reverted in block ${receipt.blockNumber}`);
    return false;
  }
}

// ─── Chain Detection ───

function getChain(chainId: number) {
  // Import the right chain from viem/chains
  // For now, return a minimal chain config
  return {
    id: chainId,
    name: "unknown",
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [] } },
  };
}

// ─── Main Loop ───

async function main() {
  const config = loadConfig();
  log("info", "PSP Keeper starting", {
    controller: config.controllerAddress,
    interval: `${config.intervalSec}s`,
    minYield: `${config.minYieldEth} ETH`,
  });

  const account = privateKeyToAccount(config.privateKey);
  const publicClient = createPublicClient({ transport: http(config.rpcUrl) });

  // Detect chain
  const chainId = await publicClient.getChainId();
  const chain = getChain(chainId);
  log("info", `Connected to chain ${chainId}`);

  const walletClient = createWalletClient({
    account,
    chain,
    transport: http(config.rpcUrl),
  });

  log("info", `Keeper wallet: ${account.address}`);

  let consecutiveErrors = 0;

  while (true) {
    try {
      const reinvested = await checkAndReinvest(publicClient, walletClient, account, config, chain);
      if (reinvested) {
        log("info", "✓ Yield reinvested successfully");
      }
      consecutiveErrors = 0;
    } catch (err) {
      consecutiveErrors++;
      log("error", `Check failed (${consecutiveErrors}/${config.maxRetries})`, (err as Error).message);

      if (consecutiveErrors >= config.maxRetries) {
        log("error", "Max consecutive errors reached, backing off 30 min");
        await sleep(1800);
        consecutiveErrors = 0;
      }
    }

    log("debug", `Sleeping ${config.intervalSec}s...`);
    await sleep(config.intervalSec);
  }
}

function sleep(sec: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, sec * 1000));
}

// ─── CLI Entry ───

main().catch((err) => {
  log("fatal", "Keeper crashed", (err as Error).message);
  process.exit(1);
});
