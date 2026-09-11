// The keeper bot. Every epoch: reveal the next chain value, then tally + settle so results
// show up immediately. Also calls meltPool()/swapTax() as the fallback cron.
//   RPC=... KEY=0x... SEED=0x... AGENT=0x... RACKS=0x... CHAIN=./chain.json node keeper.mjs
import { readFileSync, writeFileSync } from "node:fs";
import { ethers } from "ethers";

const { RPC, KEY, SEED, AGENT, RACKS, CHAIN = "./chain.json", STATE = "./keeper-state.json" } = process.env;
const provider = new ethers.JsonRpcProvider(RPC);
const wallet = new ethers.Wallet(KEY, provider);

const seedAbi  = ["function reveal(uint32 e, bytes32 preimage)", "function resolved(uint32 e) view returns (bool)",
                  "function remaining() view returns (uint256)", "function head() view returns (bytes32)"];
const agentAbi = ["function currentEpoch() view returns (uint32)", "function epochEnd(uint32 e) view returns (uint256)",
                  "function settled(uint32 e) view returns (bool)", "function settledThrough() view returns (uint32)",
                  "function tallied(uint32 e) view returns (bool)", "function tally(uint32 e, uint256 count)",
                  "function settle(uint32 e)"];
const racksAbi = ["function meltPool()", "function swapTax()"];

const seed  = new ethers.Contract(SEED,  seedAbi,  wallet);
const agent = new ethers.Contract(AGENT, agentAbi, wallet);
const racks = new ethers.Contract(RACKS, racksAbi, wallet);

const chain = JSON.parse(readFileSync(CHAIN, "utf8"));           // { length, chain[] }
let state = { nextIdx: chain.length - 1 };                         // reveal from the end backwards
try { state = JSON.parse(readFileSync(STATE, "utf8")); } catch {}
const save = () => writeFileSync(STATE, JSON.stringify(state));

async function tick() {
  const now = Math.floor(Date.now() / 1000);
  const cur = Number(await agent.currentEpoch());
  const from = Number(await agent.settledThrough());
  // reveal + settle every closed epoch that still lacks a seed
  for (let e = from; e < cur; e++) {
    if (!(await seed.resolved(e))) {
      const end = Number(await agent.epochEnd(e));
      if (now < end) continue;
      // sanity: the value we are about to reveal must hash to the on-chain head
      const pre = chain.chain[state.nextIdx];
      if (ethers.keccak256(pre) !== (await seed.head())) { console.error("chain out of sync at idx", state.nextIdx); process.exit(2); }
      console.log(`reveal epoch ${e} with chain[${state.nextIdx}]`);
      await (await seed.reveal(e, pre)).wait();
      state.nextIdx--; save();
    }
    if (!(await agent.tallied(e))) { console.log(`tally ${e}`); await (await agent.tally(e, 200)).wait(); continue; }
    if (!(await agent.settled(e))) { console.log(`settle ${e}`); await (await agent.settle(e)).wait(); }
  }
  // fallback cron for the token (bounties pay for these when they do something)
  try { await (await racks.meltPool()).wait(); } catch {}
  try { await (await racks.swapTax()).wait(); } catch {}
}

console.log(`keeper ${wallet.address} — next reveal idx ${state.nextIdx}`);
await tick();
setInterval(() => tick().catch(console.error), 5 * 60 * 1000);   // every 5 min; reveals land within minutes of an epoch end
