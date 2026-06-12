# Index Protocol

Pooled, autonomous, market-cap-weighted index vault on Ethereum mainnet. Users enter and exit in USDC, the vault computes its own target weights on-chain from float-adjusted market cap with real index methodology (iterative capping, minimum-weight floor, reconstitution buffering), and rebalancing executes through CoW Swap batch auctions. The full design rationale lives in [docs/SPEC.md](docs/SPEC.md).

## Status

Phases 1 and 2 of the six-phase build plan (SPEC Section 13) are implemented and tested.

| Phase | Scope | Status |
|-------|-------|--------|
| 1 | Core vault: ERC-7540 async superset of ERC-4626, NAV, buffer, PendingSilo, settle | Done |
| 2 | Methodology engine: market-cap weighting, iterative capping, floor, buffer rule | Done |
| 3 | Layered supply oracle (on-chain derivation, median with freeze, containment) | Next |
| 4 | Rebalancer and Composable CoW order handler | Planned |
| 5 | Fees, timelocks, guardian pause | Planned |
| 6 | Mainnet-fork end-to-end at index-10 | Planned |

## Architecture

- `IndexVault` is the ERC-7540 vault with two-lane liquidity. Flows that keep the idle USDC buffer inside its band (3 to 8 percent of NAV) settle synchronously at oracle NAV. Larger flows queue into per-epoch requests that a keeper batch-settles, with a permissionless backstop after three days so users can never be stranded. Pending redemptions are priced at settle time, and settlement cannot occur in the same block as a request.
- `PendingSilo` isolates in-flight value (unsettled deposit USDC, escrowed shares, claimable balances) so the vault's NAV is structurally clean rather than corrected by bookkeeping.
- `ComponentRegistry` holds constituents with per-feed Chainlink heartbeats. Every price read is health-checked and stale data makes price-sensitive operations revert.
- `MarketCapMethodology` implements `IMethodology`: float-adjusted market cap weighting with a hard per-asset cap redistributed iteratively to convergence, plus a minimum-weight floor that prunes dust positions. The capping math lives in the pure `WeightMath` library with exact invariants: weights sum to exactly 1e18, no weight exceeds the cap, and infeasible configurations revert instead of degrading.
- `ISupplyOracle` is the seam for the Phase 3 layered supply oracle, which is the protocol's central risk and is specified in SPEC Section 8.

## Development

Built with Foundry on Solidity 0.8.28 and OpenZeppelin v5.

```
forge build
forge test
```

The test suite covers the full async request, settle, and claim lifecycle, buffer-band gating of the sync lanes, oracle staleness fail-closed behavior, settlement liveness and flash-loan guards, and property fuzzing of the capping algorithm.
