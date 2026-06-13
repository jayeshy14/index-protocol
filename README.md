# Index Protocol

A pooled, autonomous, market-cap-weighted index vault for Ethereum mainnet. Holders deposit and redeem in a single asset, USDC, and receive an ERC-20 share that represents a pro-rata claim on the underlying basket. The vault computes its own target weights on-chain from float-adjusted market cap, applies real index-provider methodology (iterative capping, a minimum-weight floor, and reconstitution buffering), and is designed to rebalance through CoW Swap batch auctions rather than naive DEX swaps.

The differentiator is not the vault plumbing, which is commodity. It is the autonomous on-chain methodology engine and the honesty of the supply-oracle trust model that makes autonomous weighting safe to rely on.

## The problem

Most on-chain indices get the finance wrong in one of three ways.

They let a human or a governor set the target weights. That is a discretionary fund wearing an index label, and it carries exactly the trust and key-person risk an index is supposed to remove.

They weight by raw market cap with no cap. A pure market-cap weighting of the top crypto assets is roughly seventy percent Bitcoin plus Ether, which is not diversification, it is a leveraged bet on two names with extra steps. Real index providers apply a per-asset cap and redistribute the overflow, iterated to convergence. Almost no on-chain index does this correctly.

They weight by total or fully-diluted supply rather than free float, so locked, vesting, treasury, and foundation tokens inflate the weight of names whose tradable supply is a fraction of the headline number.

And they conflate rebalancing with reconstitution. Recomputing the weights of the existing members is a different event from changing which assets are members, and treating them as one produces needless turnover at the membership boundary.

This protocol takes the index methodology seriously and moves the discretionary surface off-chain only where it genuinely cannot live on-chain, then names that residual trust precisely rather than pretending it away.

## How it works

### The vault: two-lane asynchronous liquidity

`IndexVault` is an ERC-7540 asynchronous vault, a superset of ERC-4626. Net asset value is computed from the oracle USD value of the basket constituents plus the idle USDC buffer, expressed in USDC units, and any stale price feed makes value-sensitive operations revert rather than transact on bad data.

The vault holds a target idle buffer of USDC, sized as a band around five percent of NAV, so that ordinary retail flow does not force a trade on every interaction. Liquidity then runs in two lanes:

- A synchronous lane for flows small enough to keep the buffer inside its band. These settle immediately at the current NAV per share, exactly like a standard ERC-4626 deposit or redeem.
- An asynchronous lane for flows that would push the buffer outside its band. These route through ERC-7540 request and claim. Requests queue into a settlement epoch, a keeper batch-settles the epoch at one NAV, and users claim their shares or USDC afterwards.

Pending value sits in an isolated `PendingSilo` so that unsettled deposits, escrowed redemption shares, and claimable balances never contaminate the vault's NAV. The exclusion is structural, not a bookkeeping subtraction.

Two protections matter. Pending redemptions are priced at settlement time, not request time, which is fairer to the holders who remain in the vault. And a request can never be settled in the same block it was created, which closes the flash-loan and same-block oracle-manipulation vector.

### The methodology engine

`MarketCapMethodology` maps a constituent set to target weights behind a pluggable `IMethodology` interface, so the weighting scheme can be swapped without touching the vault or the rebalancer. It composes three standard index stages, all of which live in the pure `WeightMath` library with exact, enforced invariants.

- Float-adjusted market cap. Each constituent's weight starts from `freeFloatSupply * price`, using free-float circulating supply rather than total or fully-diluted supply.
- Iterative capping. A hard per-asset cap (twenty-five percent by default) is applied, the overflow is redistributed pro-rata across the uncapped names, and the process iterates because redistribution can push a previously-uncapped name over the cap. The library guarantees the output sums to exactly 1e18, that no weight exceeds the cap, and that an infeasible configuration reverts rather than silently degrading.
- A minimum-weight floor. Positions too small to justify their rebalance gas and slippage are pruned to zero and their weight is redistributed across the survivors.

Membership uses a buffer rule that keeps reconstitution distinct from reweighting. An incumbent is dropped only when it falls below rank N plus a buffer, and a non-member is added only when it rises above rank N minus that buffer, so the index does not churn its membership on every transient crossing of the boundary rank.

### The supply oracle: the part that is actually hard

Autonomous market-cap weighting is only as trustworthy as its circulating-supply input. Whoever controls that number can move the target weights and front-run the resulting rebalance. Circulating supply also cannot be made fully trustless, because for most tokens it is an off-chain fact that does not entirely exist on-chain. So the goal is not to pretend otherwise. The goal is to minimize the off-chain surface to its smallest core, secure that residual, and contain the damage if it is ever corrupted. The design leans on one structural fact: supply is slow-moving, which means security can be bought with latency in a way that would be impossible for a price feed.

The oracle is built in three layers behind the `ISupplyOracle` seam.

- Minimize (`ExcludedAddressRegistry`). Circulating supply is derived directly on-chain as `totalSupply - Σ balanceOf(excludedAddress)`. This converts "trust a number" into "trust a list of addresses," where every excluded entry is a falsifiable public claim (this is a vesting contract, this is the team multisig, this is a burn sink) that anyone can audit. `totalSupply` itself is a free, trustless upper bound. Every change to the excluded set is timelocked, so it is visible on-chain before it can take effect.
- Secure (`SupplyOracle`). The irreducible residual, the share of on-chain-circulating supply whose lock status is not on-chain visible, is expressed as a free-float factor in the range zero to one. Independent reporters push factor values, and a commit takes their median and requires a quorum to agree within tolerance. If the sources diverge, the constituent freezes at its last-good value rather than acting on disputed data. Because the factor is capped at one, free-float can never exceed the on-chain floor by construction.
- Contain (`SupplyOracle`). A committed factor moves toward the median by at most a bounded step per commit, so a correct-but-large change is approached gradually over several commits and a malicious spike cannot move the index more than one step before a human can react. A hard staleness ceiling fails reads closed if every reporter goes silent for too long, and a guardian can pause all reads outright.

The interface is shaped so that an optimistic oracle can later replace the reporter-median residual on a per-constituent basis without the methodology engine ever noticing.

### Rebalancing

Execution is designed around CoW Swap. The rebalancer expresses desired trades as Composable CoW conditional orders that solvers settle in batch auctions, which gives uniform clearing prices, batch-auction MEV resistance, and crucially moves settlement gas off the vault and onto the solver. Each order's minimum-out is anchored to the oracle price with a slippage haircut, so a solver cannot fill the vault at an arbitrarily bad price, and orders are partially fillable so a deep index with illiquid tail names can rebalance as an eventually-consistent process. NAV is always read from actual current balances, never from intended post-rebalance balances, so a partial fill simply leaves the vault closer to target. This layer is the next build and is not yet implemented.

## Design decisions worth defending

- Settle-time pricing for pending redemptions. Valuing escrowed redemption shares at the settlement NAV rather than the request NAV is fairer to remaining holders, who would otherwise absorb the difference if the basket moved between request and settlement.
- The cap does security work, not only diversification. A constituent pinned at the cap has a weight that is independent of its exact supply, so supply-oracle precision is irrelevant for the largest names and matters only for the mid and long tail, where both the dollar amounts and the value at risk from manipulation are smaller.
- Freeze versus revert. Because supply is the slow input and price the fast one, a quiet or diverging supply source freezes the constituent at its last-good value rather than halting the index. A revert is reserved for genuine hard failures: a paused oracle, an uninitialized constituent, or a value past the hard staleness ceiling.
- The supply rate-limit clamps rather than rejects. Rejecting a too-large commit would never converge, because every commit re-sees the full target. Clamping the move toward the target by one step per commit is what actually realizes "approached gradually."
- No role can move funds to an arbitrary address. The only asset outflows are user redemptions at NAV and, once the rebalancer lands, solver-settled trades bounded by a per-order minimum-out. The guardian's powers are pause-only.

## Trust model and limitations

Supply is a bounded trust assumption, not a trustless one, and the protocol is designed to state that precisely rather than overclaim. The on-chain derivation and the timelocked excluded-address registry shrink the trusted surface to a residual free-float factor; the multi-source median, divergence freeze, rate-limit, staleness ceiling, and guardian pause bound what a corrupted residual can do. Price feeds are trusted Chainlink oracles with per-feed heartbeats and round-health checks. The intended execution venue depends on CoW's solver network being live and liquid on mainnet, which is the reason the protocol targets mainnet rather than an L2.

This is a research-stage codebase. It is not audited and it is not deployed. The vault, methodology engine, and supply oracle are implemented and tested; the CoW rebalancer, the fee module, the governance timelocks, and a mainnet-fork end-to-end pass are not yet built.

## Repository layout

```
src/
  IndexVault.sol              ERC-7540 two-lane vault, NAV, settlement
  PendingSilo.sol             isolated holder of in-flight value
  ComponentRegistry.sol       constituents and health-checked Chainlink feeds
  methodology/
    MarketCapMethodology.sol  float-adjusted capped market-cap weighting
  libraries/
    WeightMath.sol            pure capping, floor, and buffer-rule math
  oracle/
    ExcludedAddressRegistry.sol  Layer 1 on-chain circulating derivation
    SupplyOracle.sol             Layers 2 and 3 residual, freeze, containment
  interfaces/
    IERC7540.sol  IMethodology.sol  ISupplyOracle.sol
test/
```

## Build and test

Built with Foundry on Solidity 0.8.28 and OpenZeppelin v5.

```
forge build
forge test
```

The suite covers the full asynchronous request, settle, and claim lifecycle, buffer-band gating of the synchronous lanes, oracle fail-closed behavior, settlement liveness and flash-loan guards, property fuzzing of the capping algorithm against its exact invariants, and adversarial supply-oracle scenarios including the divergence freeze, rate-limit convergence, timelocked exclusions, and guardian pause, with an end-to-end test that drives the methodology through the real layered supply oracle.
