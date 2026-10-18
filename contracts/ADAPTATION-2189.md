# SwarmWager launch adaptation

This Ethereum mainnet (chain id 1) contracts-only launch deploys exactly **SwarmWager** from
`src/SwarmWager.sol`. Constructor arguments, in order:

1. `registry`: `0x53e1e2f33f05086086adf618ca92c3cb0ab111cd` — the existing AskSwarmRegistry from #2099.
2. `imd`: `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` — the existing IMD payment and stake token.

The constructor already met the factory requirements and is unchanged: nonpayable, two static
address arguments, rejects zero addresses, makes no external call and requires no initialization.
There is no owner/admin argument or `$owner`, new token, minting, pause, upgrade, proxy, ETH
handling or application loop. AskSwarmRegistry and IIntake source are unchanged. Tests may deploy
or install registry fixtures; the production launch must not redeploy the registry.

No transaction was signed or broadcast. IMD's deployment service performs the eventual factory
launch. The manifest stage must name only SwarmWager with the two addresses above. No new
`launch.json` has been written.

## Reproduced audit findings and changes

### 35c0411f0762 — unreachable deadlines (medium): reproduced and fixed

The supplied proof was copied into `test/scratch/SwarmWagerUnwind.t.sol` without changing its
logic and run against the original source. It failed with
`matched wager can neither be resolved nor abandoned at any reachable time`: creation accepted
`resolveAfter = type(uint64).max`, matching escrowed both stakes, and neither exit worked even at
`type(uint64).max - 1`.

`src/SwarmWager.sol` now defines `MAX_TERM = 365 days` and rejects
`resolveAfter > block.timestamp + MAX_TERM` before quoting the fee or pulling tokens. The existing
`joinBy <= resolveAfter` rule also bounds `joinBy`. One year is a practical maximum for this simple
wager and preserves the existing cancellation/abandonment model without introducing an admin or
another exit mechanism. At the maximum accepted term, anyone can abandon strictly after day 368.
The limit is inclusive and applies relative to each wager's creation timestamp.

Delivered regressions in `test/SwarmWagerReview.t.sol` reject maximal timestamps, either deadline
beyond the horizon and the first second past the limit; accept the exact limit; and fuzz accepted
deadline pairs to prove that either cancellation or abandonment empties the escrow within that
bound. The supplied scratch proof passes after the fix.

### 9ca9f5e2c216 — registry price rise (low): reproduced and fixed

Before changing the contract, the review test reproduced a one-wei price increase: `resolve`
reverted `BadTerms`, all escrow remained, and `abandon` remained unavailable for three days.
`test_priceRiseRevertsWithoutSpendingStakesAndAbandonStillWorks` retains this no-top-up case.

`src/SwarmWager.sol` adds `topUpFee(uint256 id, uint96 amount)` and `FeeToppedUp`. Anyone may
explicitly add IMD while the wager is `Matched`. It refuses zero, overflow of the uint96 fee
escrow, and every other state. It credits the fee before pulling tokens; a failed pull reverts
both changes. Resolution still uses only that wager's escrow, approves exactly the current price
and calls `askAtMost(body, price)` once. No implicit payment is pulled from a resolver.

Contributions belong to the creator's fee escrow. All unused contributions are returned to the
creator on resolution or abandonment, even when someone else contributed. This preserves the
existing fee beneficiary and avoids new contributor accounting or loops; NatSpec and README make
the voluntary gift explicit. Regressions cover recovery after a rise, third-party contribution,
excess fee after a decrease, abandonment, events, invalid states, zero/overflow, failed approval
and false-return transfer rollback. Fuzzing covers fee conservation through resolution and
abandonment, including the maximum uint96 fee escrow.

### 905d4059dc0f — resolution caller chooses ask time (low): reproduced and documented

`test_resolveCallerChoosesAskTimeForRelativeWindows` demonstrates that delaying `resolve` changes
the wager's and registry's ask timestamps while the stored body is forwarded unchanged. The body
is opaque to SwarmWager, and the oracle resolves relative windows when it receives the request.
Thus moving-target wording can change the answer. This limitation reproduces; it is not rejected
as a false positive.

The suggested documentation remedy is applied in `src/SwarmWager.sol` NatSpec and `README.md`:
remove the unconditional claim that nobody can influence the outcome and require both parties to
review a fixed fact and explicit observation window before staking. The contract's interface,
opaque-body design and permissionless timing remain unchanged. There is no new `resolveBy`
restriction. Tests also preserve both orderings of late resolution versus abandonment.

### 6b92de10b6a1 — writer/question pairing (info): reproduced; accepted trust assumption

`test_writerPairingOfAnotherQuestionsAnswerIsTrusted` opens wager A and a separate registry request
B, then forwards B's valid, differently hashed attestation to A's callback. The registry verifies
it under its own domain and SwarmWager pays A. The pairing is the Intake writer's responsibility,
as the existing registry documents. Request ownership and single settlement do not prove the
question pairing.

This is the specified registry-as-source-of-truth design, not an authorization bypass introduced
by this adaptation. Pinning canonical question hashes would require a different request-building
interface and absolute windows. No such redesign is made. README and contract NatSpec now name
the writer, oracle signer and registry trust explicitly. There is no claim that hashing the raw
JSON body would reproduce the protocol's canonical question hash.

### 4c5e78393e82 — missing edge and live-registry coverage (info): reproduced and covered

The original wager suite's 15 tests used a fresh registry and failed during `setUp` with plain
offline `forge test`, because IMD and Intake had no code. `test/SwarmWager.t.sol` now installs the
existing MockIntake/MockERC20 fixtures only when Intake has no code, just as the existing registry
suite does. The original 15 tests and their behavior assertions are retained. Shared helpers live
in an abstract base so the live-address tests can reuse them; result delivery also asserts the
registry callback actually landed. No dependency or build configuration changed.

`test/SwarmWagerReview.t.sol` uses the unchanged registry source plus the existing configurable
payment transport. It covers every listed missing edge: price decrease/increase, invalid
signature and expired delivery (`Unverified`), callback failure followed by `markLost`, wrong bool
lengths, canonical word/majority fuzzing, the exact join/resolve boundary and a gap between those
deadlines. It records both orderings of late answer versus timeout settlement, and late resolve
versus abandonment. The original settlement semantics are preserved: a late answer already on
record may pay; a timeout refund already paid is final. A valid-at-delivery registry record is
historical; settlement does not require it to be unexpired at the later payout transaction.

`test/SwarmWagerLiveRegistry.t.sol` attaches to the existing #2099 registry on a mainnet fork,
asserts its Intake, IMD and signer dependencies, exercises the actual `price`, `askAtMost` and
`get` ABI, and refunds both Unverified and Lost outcomes. Its offline mode explicitly installs
the accepted source as a fixture at that address; it does not claim offline fixtures alone verify
live bytecode. No production signer is needed or used: test-key signatures are deliberately
Unverified against the live registry. The positive payout paths remain tested with fixture keys
and the project's existing independent oracle conformance vector remains unchanged.

### c6095a644437 — stale registry manifest (info): reproduced and removed

`contracts/launch.json` contained the prior launch's AskSwarmRegistry deployment and no SwarmWager.
It is removed so it cannot be mistaken for this launch's manifest. The historical adaptation
reports remain as records of their own launches. Only the later manifest stage writes the new
manifest.

`script/Deploy.s.sol` also still deployed a registry, so it now deploys only SwarmWager using the
exact launch dependencies, refuses non-mainnet chain ids and makes no dependency read after
construction. It returns the simulated deployment for testing. The worker has not broadcast it.

All six reports were reproduced as defects, limitations, trust assumptions or coverage/handoff
gaps as classified above; none was dismissed as non-reproducible.

## Other changed files and launch checks

- `README.md`: adds the launch's sole contract, constructor values, maximum term, fee top-up
  semantics, exact boundary behavior, oracle trust, timing races and offline/fork test usage.
- `test/SwarmWagerDeployment.t.sol`: rehearses CREATE2 from a factory on an empty dependency chain
  with the exact static arguments and no external constructor calls; verifies immutable addresses,
  zero initial wagers, no owner selector, runtime/init-code size limits, no forbidden runtime
  opcodes, zero-address and native-value rejection, and both paths of the updated project script.
- `ADAPTATION.md`: this launch's change rationale, audit dispositions and verification record.

The existing configuration, dependencies and all other production contracts are unchanged.
No wallet keys, account settings, environment files or deployment credentials were accessed.

## Verification

All test commands used
`FOUNDRY_FUZZ_SEED=0x6b6852a987bcbb3923cb72eb5907c55a8a87bacb6801e0db639b22d9ca8fc01e`.

- `forge build`: passed with the repository's own configuration. SwarmWager runtime is 7,387 bytes;
  creation bytecode plus both static arguments is 7,700 bytes, with no unlinked libraries.
  Foundry emits advisory lints about timestamps, casts and events after token calls; these are not
  build failures. The timestamp bounds are deliberate and the payment dependency is the fixed IMD.
- `forge test`: **142 passed, 0 failed, 0 skipped** offline, including the existing registry fuzz/invariant and
  protocol conformance tests. The delivered wager suites contain 47 passing tests, including four
  fuzz properties. The scratch copy of the supplied unwind proof also passes and is not delivered.
- Mainnet fork at block **26,221,915**:
  `forge test --fork-url https://rpc.flashbots.net --fork-block-number 26221915 --match-contract '^(SwarmWagerTest|SwarmWagerLiveRegistryTest)$' -vv`
  passed **17/17**: the original 15 payout/lifecycle tests against real IMD and Intake, plus both
  live-registry integration tests. A fork is a local simulation, not a deployment or signed call.
- Free `POST https://api.imd.fun/requests/check` for the existing test question
  "Did Argentina win the 2022 FIFA World Cup?", panelSize 15, evidence panel: HTTP 200,
  `judged: true`, `blockers: []`, `suggestions: []`. The response proposed bool, panel, quorum 11
  and the same relative 24-hour window. SwarmWager embeds no production question; users supply it.
- No Slither/Mythril campaign or real oracle purchase was run. These checks do not establish the
  operational trustworthiness of the writer, signer, panel or arbitrary user-supplied questions.

The next launch stage must produce a manifest naming SwarmWager alone, with the registry and IMD
addresses in constructor order. Factory deployment, attestation and explorer verification belong
to IMD's deployment handoff.
