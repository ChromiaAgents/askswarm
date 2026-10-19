# ADAPTATION: AskSwarm on Robinhood Chain (chain id 4663)

This `evm_contracts` launch deploys the three AskSwarm contracts, already audited and deployed on
Ethereum through launches #2099 (AskSwarmRegistry), #2190 (SwarmMarket) and #2189 (SwarmWager), on
Robinhood Chain in one launch. The brief is `contracts/LAUNCH-RH.md`; the earlier rounds' notes are
`contracts/ADAPTATION.md`, `contracts/ADAPTATION-2099.md`, `contracts/ADAPTATION-2190.md` and
`contracts/ADAPTATION-2189.md`. This file lists every change made for this launch and why.

## What the launch deploys

In this order, each from its bytecode as built, with static arguments only:

| # | contract | constructor | arguments |
|---|---|---|---|
| 1 | `AskSwarmRegistry` (`src/AskSwarmRegistry.sol`) | `(address intake, address imd, address signer)` | `0xa43e6f75ee006411f79ac1c84120606c2330de82`, `0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127`, `0x5598aa9146215bc13eb26f2c692ad1461fd32982` |
| 2 | `SwarmMarket` (`src/SwarmMarket.sol`) | `(address registry, address imd, address treasury)` | `$contract:AskSwarmRegistry`, `0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127`, `0x571e17b13d8f6492bbc372a160520b20bfda320c` |
| 3 | `SwarmWager` (`src/SwarmWager.sol`) | `(address registry, address imd)` | `$contract:AskSwarmRegistry`, `0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127` |

All values are from the brief. Intake v2 and the oracle attester have the same address on Ethereum
and Robinhood Chain; `0x5f7b…` is IMD on Robinhood Chain (the oracle-consumer reference's table
agrees). The treasury is AskSwarm's operating wallet, named in the brief, which is also the launch's
`$owner`; it receives only SwarmMarket's half of the 2% fee and holds no power over any contract.

Every constructor is nonpayable, takes 2 or 3 address arguments, rejects the zero address, makes no
external call and creates no contract, so each can run on the launch's empty rehearsal chain. No
contract has an owner, admin, initializer, proxy, upgrade path, DELEGATECALL, CALLCODE, SELFDESTRUCT,
ETH handling, minting, pausing, freezing or blacklisting; `$owner` is therefore not an argument of
any of them. There is no launch token: this is a contracts-only launch and none was added. Runtime
sizes are well under EIP-170 (`forge build --sizes`: registry 10,226 bytes, market 9,524 bytes,
wager 8,059 bytes). No
library is linked. `foundry.toml` already has `bytecode_hash = "none"`; no build configuration,
dependency or protected path was touched. No `launch.json` was written: the manifest step writes it.

## Contract changes

### 1. `src/SwarmMarket.sol`: `MAX_TERM` bounds `resolveAfter` (audit finding f8ec801b0e44, medium)

**Reproduced.** The supplied proof was copied unchanged to `test/scratch/` and run against the
source as it arrived. It failed with `market with resolveAfter beyond any reachable time can neither
be resolved nor abandoned; stakes are trapped`: `open` accepted `resolveAfter = type(uint64).max`,
two stakers deposited 200 IMD, and at `closeAt`, a year later, a thousand years later and at
`type(uint64).max - 1`, `resolve` and `abandon` both reverted `TooEarly`, `settle` reverted
`WrongPhase(Open)` and nothing was claimable. The contract's own invariant ("a market can always be
unwound") did not hold, and SwarmWager had already fixed the identical defect with `MAX_TERM` in
launch #2189.

**Change.** `SwarmMarket` now has `uint64 public constant MAX_TERM = 365 days`, and `open` reverts
`BadTerms` when `uint256(resolveAfter) > block.timestamp + MAX_TERM`, before reading the price or
pulling the fee escrow. Because `closeAt <= resolveAfter` was already required, `closeAt` is bounded
too. The limit is inclusive and relative to the opening block, exactly as in SwarmWager; at the
maximum term anyone can `abandon` strictly after `MAX_TERM + RESOLVE_WINDOW`. The value matches
SwarmWager's so the two contracts share one horizon; it is a named constant and listed in the README.
No storage layout, event, error, selector or other rule changed. The NatSpec invariant and the
`open` comment were updated to state the bound.

**Tests** (`test/SwarmMarketReview.t.sol`, all failing on the original source and passing now, except
the fuzz over accepted terms, which documents the guarantee the bound creates):

- `test_openRejectsResolveAfterBeyondMaxTerm`: `type(uint64).max`, `MAX_TERM + 1` and the same
  values as `closeAt` are refused with nothing pulled and no market counted; `MAX_TERM` equals
  SwarmWager's.
- `test_openAcceptsExactMaxTermAndMarketStillUnwinds`: exactly `MAX_TERM` is accepted and resolves
  at the last second of its window.
- `test_maxTermMarketAbandonsAfterResolveWindow`: a maximum-term market abandons one second after
  the window, both stakes and the unspent escrow come back, the contract holds nothing.
- `testFuzz_acceptedTermsAlwaysUnwindWithinHorizon`: for every accepted `(closeAt, resolveAfter)`
  pair, with the registry's price zero, reverting or unchanged, `abandon` succeeds by
  `MAX_TERM + RESOLVE_WINDOW + 1` and every token leaves the contract.
- `testFuzz_openRejectsEveryResolveAfterPastMaxTerm`: every `resolveAfter` from `MAX_TERM + 1` to
  `type(uint64).max` is refused.

The supplied proof also passes against the fixed contract (it is a scratch file and not delivered).
The existing market invariant suite opens markets with `closeAt = resolveAfter <= now + 6 hours`, so
its model needed no change.

### 2. `src/SwarmMarket.sol` and `src/SwarmWager.sol`: a blocked third party cannot freeze others' funds (review findings ad6653d75214 and d4e9fc2df017, medium)

**Reproduced.** Robinhood Chain's IMD, unlike the Ethereum token the earlier audits saw, is an
owner-controlled OFT whose `setBlocked(address,bool)` makes any transfer to or from that address
revert. Both supplied proofs (copied unchanged into `test/scratch/`) failed on the tree as it was:
in SwarmMarket, `_void` (reached from `abandon`, a one-sided `resolve` and every voiding `settle`)
pushed the escrow to the creator, and `settle` pushed the fee halves to the creator and the treasury,
before any stake could be claimed. One blocked creator or a blocked treasury reverted the whole call,
so nobody's stake could be claimed (`95e18 != 100e18`, "winner cannot be paid while the creator / treasury is
blocked"). In SwarmWager, `_refund` and `abandon` pushed both stakes in one call, so a blocked party
froze the other's refund (`97e18 != 100e18`).

**Change.** Both contracts gain `mapping(address => uint256) public owed`, `withdraw()`, and events
`Owed`/`Withdrawn` (SwarmWager also gains error `NothingOwed`; SwarmMarket reuses `NothingToClaim`).
Every push to a third party now goes through `_pushOrCredit`: the transfer is tried and, **if the
token reverts**, the amount is added to `owed[to]` and the call goes on. That covers SwarmMarket's
creator remainder in `resolve`, both fee halves in `settle` and the escrow in `_void`, and
SwarmWager's creator remainder in `resolve`, both legs of `_refund` and all three legs of `abandon`.
A reply of `false`, or a malformed one, still reverts the whole call as before: it cannot show
whether tokens moved, so crediting it could pay twice (the project's fault-injection token moves the
balance and then returns `false`). A market `claim`, a wager's winner payout and `cancel` stay
ordinary pushes, because each moves only the recipient's own money. `withdraw` is an ordinary push
too, and a failed one reverts and keeps the credit. Conservation now reads: the contract's balance
equals open stakes and escrows plus the sum of `owed` (plus rounding dust in markets). No fee, amount,
recipient, phase rule or deadline changed.

**Tests.**
- `test/BlockedThirdParty.t.sol` (new, with `test/mocks/BlockableIMD.sol`, a blocklisting token):
  a market abandons, and settles, with the creator blocked and separately with the treasury blocked;
  it resolves with the creator blocked and credits the remainder. A wager refunds the counterparty on
  timeout and on abandon with the other party blocked, and resolves with the creator blocked. Each
  test checks the credit, that `withdraw` fails while blocked and succeeds after, and that the
  contract ends empty.
- `test/SwarmMarketPayments.t.sol`: three tests encoded the old rule that a failed third-party
  push undoes the whole call. They are replaced, saying why, by
  `test_refusedRemainderRefundIsCreditedAndAskStands`,
  `test_malformedRemainderReplyRollsBackAlreadyPaidOracle` (a `false` reply still rolls back),
  `testFuzz_treasuryFeeTransferFailure` (a revert is credited; false, short or non-boolean replies
  roll back), `test_refusedAbandonRefundIsCreditedAndStakersClaim` and `test_failedWithdrawKeepsCredit`.
- `test/SwarmWagerAtomicity.t.sol`: the all-legs fault matrix now expects a reverted refund or
  remainder leg (resolve's remainder, abandon, a refused-answer refund) to succeed and be credited.
  Each credited party withdraws, and the same final reconciliation of every balance runs. Every other
  fault still has to roll the call back completely.
- Both supplied proofs pass.

### 3. `src/SwarmWager.sol`: `MAX_BODY_BYTES` at create (review finding 8510f4de65d9, low)

**Reproduced.** `create` accepted a 16,385-byte body that Intake refuses (`BodyTooLong`). Such a
wager could be joined but never resolved, so the counterparty waited for `abandon`. SwarmMarket already
refuses such a body. **Change:** `uint256 public constant MAX_BODY_BYTES = 16_384` and `create`
reverts `BadTerms` above it. `test_oversizedBodyRejectedByTransportLeavesFeeAndStakesRefundable` in
`test/SwarmWagerBoundaries.t.sol` encoded the old lock, so it is replaced by
`test_oversizedBodyRejectedAtCreate` (16,385 refused with nothing pulled, 16,384 accepted).

### 4. `src/SwarmWager.sol`: `cancel` and `abandon` zero `fee` (review finding 9bcb33ce3798, info)

**Reproduced.** After returning the escrow, `wagers(id).fee` still read 0.5 IMD. **Change:** both now
zero it before paying, as `resolve` already did. Tested in
`test_wagerFeeFieldZeroedOnCancelAndAbandon` and `test_wagerAbandonRefundsCounterpartyWhileOtherBlocked`.
The wager invariant handler's model (`test/helpers/SwarmWagerHandler.sol`) zeroes its fee at the
same points.

### 5. `src/AskSwarmRegistry.sol`: unchanged

Reviewed for the chain move and left as it is:

- The registry caches its EIP-712 domain separator at construction from `block.chainid` and its own
  address, so deployed on 4663 it verifies attestations signed for `(4663, registry)`, which is what
  the plane signs for a same-chain callback. A signature for the same address under Ethereum's domain
  is recorded `Unverified`. Tested in `test/RobinhoodChainLaunch.t.sol`.
- Nothing in `src/` reads `block.number`, `blockhash` or `prevrandao`, so Robinhood Chain's
  Arbitrum-style block numbering (`block.number` is an L1 number there) changes nothing. All deadlines
  use `block.timestamp`.
- The registry's `price()` reads `Intake.priceOf(ACTION, IMD)` at call time, so it follows the
  Robinhood price (0.5 IMD today) and any later change; nothing about the price is baked in.
- Intake's callback stipend, the attestation struct, the type string and the callback selector are
  the protocol's and chain-independent; the existing conformance test still pins them.

## Audit finding e842ddc10fde (info): the Ethereum manifest in `contracts/launch.json`

**Reproduced by inspection and test.** `contracts/launch.json` was launch #2099's accepted manifest:
one contract, with the Ethereum IMD `0xd34a…`, and notes saying "on Ethereum mainnet". On Robinhood
Chain that IMD has no code and Intake quotes no price for it, so a registry built from that file
would have `price() == 0`, every `ask` would revert `NotSold`, `SwarmMarket.open` and
`SwarmWager.create` would revert `BadTerms`, and the deployment would be inert.

**Change.** The file is renamed, byte for byte, to `contracts/launch-2099.json`, so it reads as the
historical record it is and cannot be mistaken for this launch's manifest. No new `launch.json` was
written anywhere: the manifest step writes the root one from the brief, with the three contracts
above and the Robinhood IMD. `test_mainnetImdWouldMakeTheRegistryInertOnChain4663` in
`test/RobinhoodChainLaunch.t.sol` shows the failure mode with the wrong IMD and the working price
with the right one, so the mistake would fail a test rather than a deployment.

## New test: `test/RobinhoodChainLaunch.t.sol`

The launch rehearsal for this chain, offline:

- `test_factoryDeploysAllThreeInOrderOnEmptyChain4663`: on chain id 4663 with no code at Intake,
  IMD, the signer or the treasury, a probe factory deploys the three init codes with CREATE2 and zero
  value in one call, in the launch's order, with `$contract:AskSwarmRegistry` resolved to the first
  address. It asserts zero calls to every dependency during construction, the predicted addresses,
  no child contract, every immutable and constant, runtime within EIP-170, no
  DELEGATECALL/CALLCODE/SELFDESTRUCT and no `owner()`.
- `test_deploymentSendsNoValueAndRejectsEth`: every constructor is nonpayable and no contract
  accepts ETH afterwards.
- `test_registryDomainIsChain4663AndItsOwnAddress`: the registry's digest equals an independently
  computed EIP-712 digest under `("IdentityMD Oracle", "2", 4663, registry)` and differs from the
  chain-1 and other-contract domains.
- `test_marketAndWagerLifecycleOnChain4663`: with mocks etched at the real Intake and Robinhood IMD
  addresses, a market and a wager run end to end: the registry pays exactly 0.5 IMD per ask, the
  callback lands under 200k gas, the market settles with the 2% fee split creator/treasury, the wager
  pays the pot. A test key stands in for the attester.
- `test_signatureUnderAnotherChainsDomainIsUnverified`: an Ethereum-domain signature leaves the ask
  `Unverified` and the market voids with no fee.
- `test_mainnetImdWouldMakeTheRegistryInertOnChain4663`: see the finding above.

The existing deployment suites (`test/SwarmMarketDeployment.t.sol`, `test/SwarmWagerDeployment.t.sol`)
still rehearse the Ethereum launches with the mainnet registry address; they are historical and
unchanged.

## Other files

- `README.md`: a "Robinhood Chain" section with the launch's order and constructor values, the
  domain note, and `MAX_TERM` for markets.
- `script/*.s.sol`: the project's own deploy scripts, kept as they are. IMD deploys this launch
  through its factory; the scripts are not part of it.

## Review findings left for the requester (not changed)

- **f5712afab2f2 (low), SwarmMarket's 1-hour `RESOLVE_WINDOW` on a sequencer chain.** The analysis
  is right: if Robinhood Chain's sequencer produced no block during a market's window, the market
  could then only be abandoned. But the brief states the window ("1h resolve window"), and resizing
  it changes the market's economics. That is the requester's call, so it is left at one hour and
  recorded here.
- **bcc1e38a0539 (low), SwarmWager's `resolve` has no upper bound and overlaps `abandon`.** This is
  the documented #2189 design ("the first of resolve or abandon wins", tested by the #2189 suite).
  Closing the overlap needs a new window, which brings back the liveness trade-off above. Left for the
  requester to decide.
- **779c9c20e1b2 (low), SwarmWager has no `issuedAt` bound and no `MIN_PANEL`.** Both are documented
  #2189 choices: the "race to settlement" NatSpec and its two ordering tests, and a panel both parties
  see in the body. Mirroring SwarmMarket would change which answers pay out. Left as is.
- **21899ff13b28 (info), rounding dust.** Winners' shares round down, so under one wei per winning
  address per market stays in the contract. That is by design and harmless; it is now stated in
  SwarmMarket's invariants NatSpec, and no sweep was added.

## Reviewed, not changed

- `_call` in all three contracts treats a call to an address with no code as success. On Robinhood
  Chain IMD `0x5f7b…` has code (the audit's `priceOf` read on the public RPC confirms Intake sells
  `oracle.request` for it), and the registry's `price()` reverts first if Intake has none.
- The writer/question pairing, the `MIN_PANEL = 7` floor, the resolver-chosen ask time within the
  one-hour window and the `Pending`-forever ask with no refund are the trust assumptions and
  decisions recorded in the earlier rounds; the chain move does not change them.
- The treasury receives the protocol half of the market fee and nothing else. It is the brief's
  address and the launch's `$owner`; it is not an owner of anything.

## Verification

With the repository's own configuration:

```sh
forge build
FOUNDRY_FUZZ_SEED=0x2f3d7c16d2b603b56fb1770d932e136dd9bb2d188416439503efa76c1965fc99 forge test
```

`forge build` succeeds (the compiler's advisory lints about timestamps and casts are unchanged from
the earlier rounds). `forge test` reports **230 passed, 0 failed, 1 skipped** across the delivered
suites, plus the six supplied proof tests in `test/scratch/`, which all pass (236 in the local run).
The skip is the pre-existing fork-only `SwarmMarketLiveRegistry` test. Runtime sizes after this round:
registry 10,226 bytes, market 9,524 bytes, wager 8,059 bytes.
No tool other than Foundry was run; no transaction was signed or broadcast, no key or environment was
read, and no network call was made by the tests.
