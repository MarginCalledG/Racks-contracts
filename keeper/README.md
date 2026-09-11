# Keeper

The keeper reveals one pre-committed value per epoch — at the epoch's START, so it is public while
attacks are placed and decides nothing on its own (reveal-then-play). The seed is that value combined
with a block hash captured after the epoch closed, which no player controls. The keeper therefore never
knows a result before attacks are closed, cannot choose values (the chain is fixed at commit time), and
gains nothing by withholding: a missed reveal fails the epoch for everyone, keeper included, and slashes
max(floor, current pot) from its bond into the pot. Attacks are refused while the bond is below cover.

**chain.json is a pot-sized secret.** Anyone holding it can act as keeper; treat it like the keeper key.

Residual trust (documented, not solved): the post-close block hash is produced by Robinhood's
sequencer, which has no stake in the game. Removing even that is the CCIP upgrade path (proposeVrf).

## One-time setup
1. `npm i ethers ethereum-cryptography`
2. `node generate-chain.mjs 100000 > chain.json` — **keep chain.json secret, back it up offline**.
   The command prints the chain END; that is the only value that goes on-chain.
3. Multisig: `HashChainSeed.setKeeper(<bot address>)`.
4. Keeper: `HashChainSeed.commit(<chain end>, 100000)`, then `depositBond(<RACKS>)`
   (bond must stay ≥ one `slashPerMiss`; fund the bot address with gas).
5. Multisig: `IRSAgent.setPaused(false)` — only now, and only after this contract has been audited.

## Run
`RPC=... KEY=... SEED=... AGENT=... RACKS=... node keeper.mjs`
Run two instances on two machines with the same chain.json and a shared state file if you want
redundancy: the second one just sees "resolved" and skips. Monitor `Failed` events on the seed
contract — each one is a missed reveal and a slashed bond.

## What it does every tick
reveal the current epoch at its start; for closed epochs capture → tally → settle; then `meltPool()` and `swapTax()` as fallbacks.
Bond: must stay ≥ the current pot; the bot warns when it is not.
If the chain and the on-chain head ever disagree, it stops (exit 2) rather than burning gas.
