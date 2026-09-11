# Keeper

The keeper reveals one pre-committed value per epoch. It cannot choose values (the whole chain is
fixed at commit time) and gains nothing by withholding (a missed reveal fails the epoch for everyone,
including the keeper, and slashes its bond into the pot). It is an employee, not an authority.

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
reveal → tally → settle for every closed epoch, then `meltPool()` and `swapTax()` as fallbacks.
If the chain and the on-chain head ever disagree, it stops (exit 2) rather than burning gas.
