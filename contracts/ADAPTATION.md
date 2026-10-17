# ADAPTATION

AskSwarmRegistry ships in an `evm_contracts` launch on Ethereum (chain id 1). This file lists every
change made to the project as it arrived, and why each one was needed.

The deployed contract is `AskSwarmRegistry`, constructor
`(intake, imd, signer)` = (`0xa43e6f75ee006411f79ac1c84120606c2330de82`,
`0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`, `0x5598aa9146215bc13eb26f2c692ad1461fd32982`), all from
the brief. The constructor is nonpayable, takes 3 address arguments, and has no owner or admin, so
`$owner` is not used. The contract has no DELEGATECALL, CALLCODE or SELFDESTRUCT, no proxy and no
upgrade path, and its runtime is about 8.2 KB.

## Contract changes (`src/AskSwarmRegistry.sol`)

1. **The constructor no longer calls IMD.** It used to call `imd.approve(intake, type(uint256).max)`.
   - Rule: launch constructors run on an empty chain and must not call another contract.
   - Change: `ask` now approves Intake for exactly the price `p` just before `requestWithFailure`.
     Intake pulls exactly `p`, so the allowance is back to zero after each ask. The contract still
     holds nothing between calls, and there is no longer a standing unlimited allowance.
   - Cost: one extra warm `approve` per `ask`.
   - Test: `test_constructorMakesNoCallsAndAskLeavesNoAllowance`.

2. **Audit finding c2c8fea2 (low), reproduced and fixed.** An attestation that had already expired
   when it arrived was stored with `verified = true` and status `Answered`.
   - Why it is a defect: the brief says "requires agreed >= quorum and not expired", the README says
     `verified` needs it to be unexpired, and the protocol's `_verifyAttestation` refuses expired
     attestations.
   - Change: `ok` now also requires `block.timestamp <= a.expiresAt`. An expired delivery is recorded
     as `Unverified` and is still stored for the record. Delivery exactly at `expiresAt` is still valid.
   - Test change: `test_expiredAtDeliveryAndAnswerBoundaries` used to assert `verified == true` for
     an expired delivery. That is the behaviour the brief rules out, so it now asserts `false`, status
     `Unverified`, and that the delivery still succeeds.
   - New tests: `test_expiryBoundaryAtDelivery` and the fuzz test below.

3. **Audit finding ddc3dd9c (medium), reproduced and fixed.** "Strength" was absolute panel size and
   absolute agreement only, and the asker chooses both `panelSize` and `quorum` at a flat price.
   - Reproduced: hold 11/15 (quorum 11). Then deliver 11 of 100 (quorum 2). Before the fix the second
     answer took `latestFor`.
   - Change: an answer is indexed only if a strict majority of its own panel agreed on it
     (`agreed * 2 > panelSize`). The existing displacement rule (panel and agreement both at least as
     large) is kept.
   - Why a majority gate rather than a pure ratio comparison (the audit's other suggestion): a pure
     ratio would let a cheap 2-of-2 answer lock a question against a 99-of-100 one until it expires.
   - What is unchanged: a minority answer is still stored and still `verified` (signed, quorum met,
     unexpired), so the full record survives. It just never becomes the canonical `answerOf` /
     `isCurrent` answer.
   - Tests: `test_minorityOfLargePanelCannotDisplaceSupermajority` (the audit's exact scenario),
     `test_minorityAnswerNotIndexedEvenWhenNothingHeld` (10 of 20 is not a majority, 11 of 20 is),
     and `testFuzz_indexedAnswersAreMajorities`.

All five new or changed tests fail against the original contract and pass against this one.

Comments that describe these rules (the invariants header and `Stored.verified`) were updated to match.
No other behaviour changed: storage layout, events, errors, selectors, read functions, signature
handling and the 4096-byte answer cap are as they were.

## Test changes (`test/`)

- **`test/AskSwarmRegistry.t.sol` now runs without a network.** The suite was fork-only, and the
  verifier runs with no network, so plain `forge test` failed.
  - When no code is found at the Intake address, `setUp` etches the mocks in
    `test/mocks/IntakeMocks.sol` at the real Intake and IMD addresses, and sets chain id 1 and a
    mainnet-like block and timestamp.
  - With `--fork-url` the original fork path runs against the real contracts. All 19 tests passed
    both ways, on a mainnet fork via a public RPC and offline.
  - Fork gas for `onOracleResult` measured from the test frame: 145,434 before and 145,779 after the
    change, with the bytes32 answer. Delivery through the real `Intake.complete` reports
    `delivered == true` under the 200k stipend.
  - New tests: `test_failureHookStatusesAndUnknownIds` (status 1 records `Refused`; unknown ids are
    refused on both hooks), plus the tests listed above.
- **`test/mocks/IntakeMocks.sol`**: a mock Intake v2 (price, `requestWithFailure` pulling exactly the
  amount, `requests`, `writer`, `complete` calling the callback or failure hook once under a 200k gas
  stipend and emitting `Completed`) and a minimal ERC-20 for IMD.
- **`test/OracleConsumerConformance.t.sol`**: the oracle-consumer skill's conformance test, adapted.
  It checks that the registry, deployed at the vector's address on the vector's chain, reproduces
  the protocol's digest. It also checks that the callback selector is the canonical one, and that it
  accepts the protocol's own signature delivered through a mock Intake, as well as a fresh signature
  from the vector key. The `IntakeDelivery` case is dropped because this is a same-chain consumer.

## Docs

- `README.md`: the `ask` approval, the majority rule for indexing, and how to run the tests offline
  or on a fork.

## Reviewed, not changed

- The DOMAIN_SEPARATOR is cached at deployment: it is correct on chain 1. If the chain ever forked,
  the separator on the new chain would be stale, but answers there would then fail to verify rather
  than be accepted.
- `_call` treats a call to an address with no code as success. On mainnet IMD is a fixed address
  with code, and `price()` reverts first if Intake has none.
- `a.requestId` (the oracle's UUID) is not consumed. The brief pairs answers by the Intake request
  id, and Intake delivers each request once. Only asks this contract made are accepted (`UnknownAsk`
  otherwise).
- There is no deadline-based clearing of `Pending` asks. The registry moves no value on a result or
  a failure, and refunds nothing, so a stuck `Pending` ask only means "never answered".
- `script/Deploy.s.sol` is the project's own deploy script, kept as is. IMD deploys this launch
  through its factory, not through this script.
