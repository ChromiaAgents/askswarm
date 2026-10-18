# SwarmWager custody and failure tests

These tests extend the accepted wager, registry integration, deployment, and protocol-conformance
tests. They run entirely offline with the existing vendored forge-std. Production contracts,
deployment scripts, dependencies, and Foundry configuration are unchanged.

- `SwarmWagerInvariant.t.sol` and `helpers/SwarmWagerHandler.sol` run 256 sequences of 128
  calls across four actors and up to 32 concurrent wagers. The handler exercises all seven
  state-changing wager functions, price changes, donations, time boundaries, and twelve oracle
  outcomes. It uses the actual registry source and its signature verification through the existing
  recording Intake fixture, including the 200,000-gas callback limit.
- Independent ghost accounting checks each participant's debits and credits, escrow liabilities,
  donations, exact oracle fees, fixed supply, zero residual allowances, and one request per
  successful resolution. Separate record checks cover immutable terms, correct winners,
  distinct request ids, and final states that never reopen. Expected failures are checked explicitly;
  unexpected handler reverts fail the campaign. A deterministic test reaches all twelve outcomes
  and every exit, so an idle handler cannot silently satisfy the suite.
- `afterInvariant` advances past all remaining deadlines and closes every wager without new
  funding, while oracle price queries are disabled. Only tracked unsolicited donations may remain.
  Donations are deliberately excluded from money owed to bettors.
- `SwarmWagerAtomicity.t.sol` covers 60 combinations of payment leg and token failure, plus
  1,000 fuzzed cases with stakes across the `uint96` range. False, reverting, short, and
  non-boolean token replies must roll back balances, approvals, counters, and wager records.
  This includes failures on the second stake refund, the last abandonment transfer, and the fee
  remainder after the oracle fee was forwarded. Each failed operation must succeed on retry;
  a concurrent wager's escrow stays intact. A separate lifecycle test covers empty return data.
- `SwarmWagerBoundaries.t.sol` covers unavailable and retired oracle pricing, oversized request
  bodies, exact/insufficient allowances, maximum stake plus maximum fee, a missing registry record,
  and two wagers sharing a question index but receiving opposite answers. Two 1,000-run properties
  cover the majority threshold through `uint16.max` and all non-bool answer type codes.

Run from the repository root:

```sh
forge build
FOUNDRY_FUZZ_SEED=0x6b6852a987bcbb3923cb72eb5907c55a8a87bacb6801e0db639b22d9ca8fc01e forge test
```

Fuzz and invariant budgets are inline in the Solidity test files. No RPC, new package,
configuration change, or shared environment mutation is required. The fault token is a test
instrument for rollback; it is not a claim that mainnet IMD has unusual transfer behavior.
Opaque bodies are transport fixtures, not production oracle questions. The tests retain the
approved trust in the registry, its signer, and the Intake writer's request/answer pairing.

Live Ethereum fork verification is still owed for this pass. The existing `SwarmWager.t.sol` and
`SwarmWagerLiveRegistry.t.sol` support a separately supplied fork; their offline fixtures do not
prove deployed bytecode or current live configuration. This assignment makes no mainnet deployment.
