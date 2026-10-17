# ADAPTATION

AskSwarmRegistry ships in an `evm_contracts` launch on Ethereum (chain id 1). This file lists every
change made to the project for this launch, the file it touches, and the rule or audit finding that
required it. The earlier launch of this registry (launch #2088) and its adaptation notes are in
[contracts/ADAPTATION.md](contracts/ADAPTATION.md); the code here starts from the version that
launch accepted.

## What the launch deploys

One contract, `AskSwarmRegistry` (`src/AskSwarmRegistry.sol`), constructor
`(address intake, address imd, address signer)` =
(`0xa43e6f75ee006411f79ac1c84120606c2330de82`, `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`,
`0x5598aa9146215bc13eb26f2c692ad1461fd32982`), all from the brief. The constructor is nonpayable,
takes three static arguments, makes no external call and needs no contract to exist, so it deploys on
the launch's empty rehearsal chain. There is no owner, admin, initializer, proxy, upgrade path, ETH path
or loop, so `$owner` is not used. No DELEGATECALL, CALLCODE or SELFDESTRUCT; runtime about 10.2 KB
after the revision below (`forge build --sizes`: 10,226 bytes runtime, 10,743 initcode).
The Foundry project is at the repository root (`foundry.toml`, `src/`, `test/`, `script/`, vendored
forge-std under `contracts/lib/`), as the project arrived; `bytecode_hash = "none"` was already set.
No build configuration or dependency was changed.

## Changes

### 1. Forge build output is no longer tracked (repository, no source change)

- Files: `contracts/out/**`, `contracts/cache/**`, `contracts/broadcast/**` removed from the index
  (46 files). They were already listed in `.gitignore`; the tree tracked them anyway.
- Rule: the verifier rejected the previous attempt with `path_violation`: contracts are compiled from
  source, and a tree may not carry what forge would read in their place. Nothing else about the
  repository layout changed.

### 2. Audit finding 1b549341 (low), reproduced and fixed: a settled ask could be delivered again

- File: `src/AskSwarmRegistry.sol`, `onOracleResult` and `onFailure`.
- Reproduced with the audit's proof: after ask A was answered "CHF", the writer completed a second
  open ask B with arguments naming A and "EUR". The live Intake v2 binds a completion's arguments to
  its request id only for status 1 and 2, so the registry's `onOracleResult(A, …)` ran again,
  rewrote A's answer, and with an empty signature flipped A to `Unverified` while `latestFor` still
  pointed at it.
- Change: both hooks now revert `AlreadySettled(requestId)` unless the ask is `Pending`. The status
  shares the slot already loaded for the `UnknownAsk` check, so the callback's gas is unchanged
  within measurement noise. The header invariant now states what the contract enforces rather
  than what it assumed of Intake.
- Tests: `test_settledAskIsNotRewrittenByAnotherRequestsCompletion` (the audit's scenario and its
  zero-signature variant, through an Intake model that forwards status-0 arguments unchecked),
  `test_bothHooksRefuseEverySettledStatus` (Answered, Unverified, over-cap Unverified, Refused,
  NoResult, for both hooks, with the record byte-identical afterwards),
  `test_settledAskRefusesRedeliveryThroughAnotherOpenAsk` (through the mock etched at the real Intake
  address), and the invariant handler `replaySettledThroughOpenRequest`, which replays random settled
  ids through random open asks during the campaign and tracks the asks that Intake then leaves
  completed-but-undelivered.

### 3. Audit finding d8368ddd (low), reproduced and fixed: attestations issued in the future verified

- File: `src/AskSwarmRegistry.sol`, `onOracleResult` and the new constant `ISSUED_AT_TOLERANCE`.
- Reproduced: an attestation with `issuedAt` a year ahead and `expiresAt` a year and a day ahead was
  stored `verified` and indexed, locking the question for far longer than the plane's 30-day cap.
  The protocol's `OracleAttestationConsumer` refuses `issuedAt > block.timestamp + 5 minutes`.
- Change: `verified` additionally requires `a.issuedAt <= block.timestamp + ISSUED_AT_TOLERANCE`
  (5 minutes, the protocol consumer's value). A pre-dated delivery is recorded `Unverified` and never
  indexed, like an expired one.
- Tests: `test_issuedAtToleranceBoundary` (exactly 5 minutes ahead is verified, one second more is
  not, the audit's one-year case), `testFuzz_verifiedRequiresIssuedAtWithinTolerance`, and
  `testFuzz_indexedAnswersAreMajorities` now also fuzzes `issuedAt` ahead of the clock.

### 4. Audit finding 77599b52 (info), reproduced and fixed: unanswered records hashed as an empty answer

- File: `src/AskSwarmRegistry.sol`, `Stored.stored` and `_read`.
- Reproduced: `get(id)` for a Pending, Refused, NoResult or over-cap ask, and for an id never asked,
  returned `answerHash == keccak256("")`, indistinguishable from an answer that was empty bytes.
- Change: `Stored` gains a `stored` flag in the free bytes of its third slot (written in the same
  SSTORE, so no gas change; the three-slot layout is kept), and `_read` returns a zero `answerHash`
  and empty `answer` when nothing was stored. A stored empty answer still hashes as `keccak256("")`.
- Tests: `test_recordsWithoutAStoredAnswerReportZeroAnswerHash`, `test_unknownReadsDoNotLookAnswered`
  (now asserts the hash), and the invariant campaign asserts a zero hash for every Pending ask.

### 5. Audit finding f2768f2b (info): no code change

Each point was checked; none is a defect in the registry's own logic.

- Intake's owner can retire the action (`ask` reverts `NotSold`), lower the callback gas, or rotate
  the writer or signer. These are the trust assumptions the contract header states; the registry
  has no owner to react, by the requester's design, and a successor is a new deployment.
- `SIGNER` is compared by `ecrecover`, so a rotation to an ERC-1271 signer stops new answers
  verifying. Documented in the header; unchanged.
- `DOMAIN_SEPARATOR` is cached at construction with `block.chainid`. After a chain-id-changing fork
  answers fail to verify rather than being accepted. Unchanged.
- The one-argument `answerOf` returns the held answer unfiltered; readers that need freshness or a
  minimum panel use the three-argument overload or `isCurrent`. Documented; unchanged.
- The brief names `contracts/src/AskSwarmRegistry.sol`; the tree has `src/AskSwarmRegistry.sol` with
  `foundry.toml` at the root (`src = "src"`), as the previous launch accepted. Kept.
- The brief's "~105k gas" for the callback predates the review changes. Measured from the test frame
  in this tree: 146,342 gas for a bytes32 answer and 133,966 for a warm 352-byte answer, both under
  the 150k the test asserts and under Intake's 200k stipend. Delivery through the Intake model
  reports `delivered == true`, including the cold 4096-byte worst case.
- Launch-forbidden features: none found. IMD is an OpenZeppelin ERC-20 without transfer hooks, so
  `ask` is not reentrant and leaves zero allowance and balance.

## Revision after the independent review (17 Oct 2026)

The verifier accepted the changes above; an independent review then reopened the work with one
reproducible finding and three advisory ones. Each was reproduced before anything changed. The
answers to the reviewer are in `.imd-responses.json`.

### 6. Review finding a97feadf (medium), reproduced and fixed: the index ignored the validity window

- File: `src/AskSwarmRegistry.sol`, `onOracleResult`, the new `_mayDisplace`, `reindex` and the
  `Indexed` event.
- Reproduced with the reviewer's proof (`Proof_a97feadf8000.t.sol`): an 11-of-15 answer valid for
  30 days was evicted by an equal-strength 11-of-15 answer valid for 60 seconds, because the rule
  compared only `panelSize` and `agreed`. A minute later nothing was current and a 2-of-2 panel took
  the index for 30 days. Cost: two asks. The header invariant promised otherwise.
- Change: while the held answer is verified and unexpired, a delivery takes the index only if it is
  at least as strong (`panelSize`, `agreed`), at least as fresh (`issuedAt`) and valid at least as
  long (`expiresAt`). Equality on all four still lets the later delivery win, as before. This covers
  the reviewer's consequence (b) as well: an equal-strength answer delivered out of order with an
  older `issuedAt` no longer displaces the newer one.
- Consequence (a), which the reviewer left to the author: an answer that arrives while a stronger
  but shorter-lived one is current is not indexed, and once that one expires the index went dark
  although a verified answer was still valid, with no way to re-index it. The smallest fix is
  `reindex(requestId)`: anyone may point `latestFor` at an answer already on record, under exactly
  the delivery rule, except that it must beat the held answer on at least one count when that one
  is current (a tie cannot be flipped back and forth for free; ties are only settled by a paid
  delivery). It is a fallback: it never moves a current index to anything weaker, staler or
  shorter-lived, so the invariant holds whichever path moved the index. No owner, no loop.
- `Indexed(questionHash, requestId)` is emitted whenever the index moves, from either path, so a
  reader can follow the canonical answer without re-deriving the rule. The callback measures
  148,282 gas from the test frame for a bytes32 answer (was 146,342), under the suite's 150k
  assertion and Intake's 200k stipend.
- Tests: `test/AskSwarmRegistryReview.t.sol` (the proof's scenario, out-of-order and shorter-window
  deliveries, the tie rule, the fallback after expiry, strict dominance among fallbacks, every
  ineligible record, the `Indexed` event), `test_indexRespectsValidityWindowAndReindexRecovers`
  through the mock at the real Intake address, and the invariant handler `answer` now checks the
  four-count rule while a new `reindex` handler computes the expected outcome from the read API and
  calls it on random records. The reviewer's proof passes.

### 7. Review finding 7b194c37 (low, advisory), reproduced and fixed: no price ceiling on `ask`

- File: `src/AskSwarmRegistry.sol`, `askAtMost` and the internal `_ask`; `packages/imd/src/intake.ts`.
- Reproduced: with a standing allowance (the bot approves twenty asks at once), an Intake price
  change landing before the ask is mined is paid silently. `ask(bytes)` is specified to pull exactly
  Intake's price and keeps that behaviour.
- Change: `askAtMost(bytes body, uint256 maxPrice)` reverts `PriceAboveMax(price, maxPrice)` when
  the live price exceeds the ceiling; `ask(bytes)` forwards an unbounded ceiling. A distinct name
  rather than an overload keeps the bot's hand-written ABI and `abi.encodeCall(registry.ask, …)`
  in the tests unambiguous. The bot's registry path now calls `askAtMost` with the price it quoted.
- Tests: `test_askAtMostRefusesAPriceAboveTheCeiling`, `test_askWithoutCeilingStillPaysTheLivePrice`,
  `test_askAtMostAgainstTheQuotedPrice`.

### 8. Review finding 8f2c2abc (low, advisory), reproduced and fixed: an undelivered completion stayed Pending forever

- File: `src/AskSwarmRegistry.sol`, `Status.Lost` (appended as code 6, so existing readers keep
  their tables), `markLost`, the `Lost` event; `packages/imd/src/intake.ts` status names.
- Reproduced: the writer completes ask B with A's arguments; the registry refuses the replay (finding
  1b549341), Intake marks B completed and refuses any second completion, and B reads `Pending`
  indefinitely. The same holds for a callback that runs out of a lowered stipend or a failure
  completion with empty arguments.
- Change: `markLost(requestId)` moves a `Pending` ask to `Lost` once Intake's own record says the
  request is completed (`requests(id).completed`, read through the interface the project already
  declared; the live contract's verified ABI returns `(payer, callbackTarget, callbackSelector,
  completed)` and a real mainnet ask was read back `completed == true` while checking this). Anyone
  may call it; it touches no answer or index. There is deliberately no age-based deadline: a request
  Intake has not completed is still in flight at the protocol level, `Pending` is then the truthful
  status, and an age cut-off could refuse a late but real delivery. Nothing is locked meanwhile: the
  registry holds no IMD.
- Tests: `test_markLostSettlesAnAskIntakeCompletedWithoutDelivering` (the reviewer's scenario, the
  `StillOpen` refusal before completion, terminal afterwards for both hooks and a second call,
  unknown and settled ids), `test_markLostAfterAFailureCompletionWithEmptyArguments`,
  `test_statusCodesAreAppendedNotRenumbered`, `test_markLostReadsIntakeCompletionRecord` through the
  mock at the real address (whose `requests` getter has the live ABI's shape), and the invariant
  handler `markLost`, which expects success only for stranded asks and the right error otherwise.
  The test transport gained the `requests` getter.

### 9. Review finding 4b501391 (info), documentation corrected

- File: `src/AskSwarmRegistry.sol`, NatSpec of `latestFor`; `README.md`.
- The NatSpec called `questionHash` the hash of the normalized question. Per the oracle-consumer
  reference it also covers the resolved block window and the definitions, so asks with a relative
  window never share a key and only absolute-window asks repeat one. The NatSpec and README now say
  so. No code change: the contract indexes whatever key the plane signs.

### Not changed in this revision

- Findings 1b549341, d8368ddd and 77599b52 were fixed in the accepted round (sections 2 to 4); their
  proofs still pass. Finding f2768f2be is informational and needed no code change (section 5).
- The forge output under `contracts/out`, `contracts/cache` and `contracts/broadcast` is ignored and
  not tracked; the attempt that tracked it was rejected for that alone.

## Test and documentation changes

- `test/AskSwarmRegistryCallbacks.t.sol`: the five tests listed in sections 2 to 4; the retry test's
  comment no longer says the registry has no Pending guard.
- `test/AskSwarmRegistryReview.t.sol`: new, the tests listed in sections 6 to 8.
- `test/AskSwarmRegistry.t.sol`: the tests listed in sections 3, 6, 7 and 8 and the extended fuzz test.
- `test/AskSwarmRegistryInvariant.t.sol`: the `replaySettledThroughOpenRequest`, `reindex` and
  `markLost` handlers, a `stranded` flag on expected asks, a seeded Lost ask, and matching checks in
  `assertRecordsAndIndexes`.
- `test/helpers/RegistryTestSupport.sol`: the transport model's `requests` getter.
- `test/TESTING.md`, `README.md`: describe the new behaviour and this launch.
- `packages/imd/src/intake.ts`: the bot calls `askAtMost` with its quoted price and names `lost`.
- `contracts/launch.json` is the manifest the previous launch accepted and is left as it is; the
  manifest step writes this launch's own.

All 89 tests pass offline with the verifier's fuzz seed
(`FOUNDRY_FUZZ_SEED=0xd094d872360bfdb7dab18e96fc214e6614b324111bad9f9dd12ad8e4b5d75c41`); the four
proofs (three audit, one review) fail against the contract as it arrived at their round and pass
against this one. Before this revision the `test/AskSwarmRegistry.t.sol` suite was also run on a
mainnet fork against the live Intake v2 and IMD (public RPC, 17 Oct 2026, all 20 passed; callback
gas 146,366 for a bytes32 answer). In this revision the live Intake was only read (`priceOf`, the
`requests` record of a real ask, the verified ABI), not forked.
