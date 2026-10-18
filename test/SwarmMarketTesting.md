# SwarmMarket test additions

Run `forge build` and `forge test` from the repository root. The added tests use the
existing vendored forge-std and require no installation or network. Production code,
configuration, and existing contributor tests are unchanged.

## Stateful accounting and liveness

`SwarmMarketInvariant.t.sol` runs 256 sequences of 96 handler calls, with unexpected
handler reverts treated as failures. Four funded actors can create up to 24 markets,
stake repeatedly on either side, donate to escrow or directly to the contract, change
the oracle price, advance time, resolve, deliver an oracle result, settle, abandon,
and claim in random order. Creators are also stakers. Market zero and calls in the
wrong phase are deliberately included; rejected calls must return the precise error.

The fixture uses the actual `AskSwarmRegistry` implementation with the existing
`PaymentToken` and `RecordingIntake` fixtures. Answers are signed with a local test
key and delivered with Intake's 200,000-gas allowance. Results include both valid
booleans, refusal, split, lost callbacks, a wrong signer, a tied panel, a wrong type,
a noncanonical boolean word, a short answer, and a panel below the minimum.

The answer window follows the signed `issuedAt`, not the settle time. A delivered answer's
`issuedAt` is the delivery time, the deadline (for a late delivery), or the second after the
deadline (allowed by the registry's five-minute tolerance). The model expects a decisive
answer issued within `ANSWER_WINDOW` to decide the market whenever settle runs. It expects
an answer issued later, or a request still pending after the window, to void. The
deterministic test pins both: a Yes signed one second late voids, and a Yes settled ten
days after the window still pays Yes.

Checks after every call cover:

- The contract balance equals outstanding liabilities, rounding dust, and direct
  donations. A separate cash journal reconciles deposits against claims, market
  fees, returned escrow, and oracle payments.
- Every actor's balance reconciles against its own debits and credits. No market
  can use another market's escrow to conceal an accounting shortfall.
- A void refunds both sides in full. Each winner retains its principal and receives
  the greatest integer reward below its exact fractional entitlement. Total dust is
  less than the number of actors; a void has none.
- Treasury fees are exact, oracle fees reach the payment recipient, and neither
  registry hop retains tokens or a spending allowance.
- Finished market records remain unchanged, claims cannot repeat, and stake
  ownership, request IDs, market counts, and lifecycle phases match the journal.

Every campaign starts with live positions, Yes/No/Void outcomes, an answered but
unsettled request, a pending request, donations, and completed claims. A deterministic
test checks this setup and rejects duplicate claims. After each random sequence,
`afterInvariant` advances time, unwinds every outstanding market and claims for all
actors. Only accounted donations and rounding dust may remain.

## Payment failures

`SwarmMarketPayments.t.sol` adds 1,000-run fuzz tests for unsuccessful, reverting,
short, and nonboolean token return data on pulls, approvals, and treasury transfers.
It checks rollback and a successful retry, including the first creator payment when
the subsequent treasury payment fails. Additional cases cover no-return pulls and
approvals, oracle-payment rollback when the creator's remainder transfer fails,
claim retry and isolation between winners, abandon refund rollback, and uint128
pool overflow with another market funded concurrently.

These are fault-injection tests of atomicity, not a claim that SwarmMarket supports
fee-on-transfer, rebasing, or malicious callback tokens. Its production asset is the
fixed IMD constructor argument.

## Optional live integration

`SwarmMarketLiveRegistry.t.sol` skips when no fork is active. A supplied fork must
be Ethereum mainnet and include code at the registry address.
To run it on a mainnet fork, supply `--fork-url` and `--fork-block-number` to
`forge test --match-path test/SwarmMarketLiveRegistry.t.sol`, using a block after
registry launch #2099. It reads no environment settings and embeds no RPC endpoint.

This suite deploys only SwarmMarket with the three requested production addresses.
It uses the existing registry, IMD and Intake without replacing their code. It checks
exact payment/request registration, a one-sided refund without an ask, and a refusal
delivered by an impersonated Intake writer. It does not impersonate the production
signer or manufacture a verified production answer.

The live fork run remains outstanding in this offline check. The existing deployment
rehearsal and protocol conformance vector are retained. No transaction is broadcast
by this test assignment.

## Local verification

`forge build` passed. `forge test` passed with 162 tests successful,
zero failures, and one skipped live-suite setup (its three integration tests require
an active mainnet fork). The new invariant campaign completed 256 runs and 24,576
calls with zero unexpected handler reverts. Both payment fuzz tests completed
1,000 cases. No new contract defect was confirmed by this work.
