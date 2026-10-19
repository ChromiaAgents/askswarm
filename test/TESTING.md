# AskSwarmRegistry test coverage

The tests run offline with the repository's existing forge-std dependency. Foundry configuration is
unchanged. Run `forge build` and `forge test` from the repository root. Any fuzz seed passes; the
second launch's verifier used:

```sh
FOUNDRY_FUZZ_SEED=0xd094d872360bfdb7dab18e96fc214e6614b324111bad9f9dd12ad8e4b5d75c41 forge test
```

- `AskSwarmRegistryPayments.t.sol` covers exact fee forwarding, changing prices, body limits,
  insufficient funds/approval, malformed or unsuccessful ERC20 calls, no-return tokens, Intake
  rejection before and after payment, donation isolation, and rejected ETH payments. Reverts must
  leave balances, approvals, request records, and counters unchanged.
- `AskSwarmRegistryCallbacks.t.sol` covers tampering with every signed field, wrong signers and
  domains, invalid signature lengths/recovery values, a valid false answer, distinct oracle/intake
  identifiers, byte-exact short answers, nonzero ABI padding, long-answer hashes and events, the
  4,096/4,097-byte boundary, both failure statuses, access checks, filtered reads, expiry transitions,
  and both dimensions of panel strength. Delivery uses a 200,000-gas call. From the second launch's
  audit: a settled ask refuses re-delivery on both hooks whatever Intake relays (including a status-0
  completion of another open request that names the settled id), `issuedAt` more than 5 minutes
  ahead of the chain clock is recorded `Unverified`, and records with no stored answer read back
  with a zero `answerHash`.
- `AskSwarmRegistryReview.t.sol` covers the independent review of the second launch: the index
  respects an answer's validity window and issue time (a 60-second equal-strength answer cannot
  evict a 30-day one, an older answer delivered later cannot displace a newer one, ties go to the
  later delivery), `reindex` as the fallback once a held answer expires (strict dominance among
  fallbacks, every ineligible record refused, the `Indexed` event), `askAtMost` as a price ceiling,
  and `markLost` for asks Intake completed without delivering (`Lost`, terminal, appended status code).
- `AskSwarmRegistryInvariant.t.sol` runs 256 sequences of 96 calls with three funded callers.
  Eleven handlers exercise successful and reverted asks, donations, signed/invalid/expired/oversized
  answers, refusals, time changes, unauthorized callbacks, transport retries, replays of a settled
  id through an open request, `reindex` on random records against the rule computed from the read
  API, and `markLost` on random asks. Ghost accounting tracks each caller's payments and donations.
  Checks cover conservation, exact fee forwarding, zero remaining Intake approval, request counts,
  immutable settled records under any writer behaviour, pending asks reading as unanswered, Lost
  only for undelivered completions, and coherent majority-only question indexes. Seeded setup
  reaches meaningful states even before random calls begin. Unexpected handler reverts fail the
  campaign.
- Existing `OracleConsumerConformance.t.sol` retains the independent protocol digest/signature
  vector. New signature tests complement that vector; signing the registry's own digest alone
  would not prove protocol compatibility.

The new `helpers/RegistryTestSupport.sol` models the external payment token and Intake. Intake's
body-size checks, forwarding, request-id construction, failure-argument binding, and one-shot
callback behavior were checked against its
[verified Ethereum source](https://eth.blockscout.com/address/0xa43e6F75ee006411F79Ac1C84120606C2330DE82?tab=contract).
The model intentionally exposes test controls for price changes and payment failures. It does not
model offchain JSON screening, panel formation, or the operational signer. Opaque test bodies are
transport fixtures, not production oracle questions.

The existing `AskSwarmRegistryTest` also passed against the live Intake and IMD on an Ethereum
fork at block 26,213,316. It remains offline by default; a separately supplied RPC can enable its
fork path. No endpoint or credential is embedded in the new tests.

The findings that campaign reported (settled-record overwrite through another request's completion,
future issuance beyond the canonical clock tolerance) are fixed in the contract and covered by the
tests above; see `ADAPTATION.md` at the repository root. The cached domain after a chain-id-changing
fork is unchanged: answers on the forked chain would fail to verify rather than be accepted.

## Third pass: hostile inputs and index transitions

- `AskSwarmRegistryAdversarial.t.sol`:
  - Answers from 4,097 bytes up to 64 KiB settle `Unverified` inside the 200k stipend and never move the index.
  - A 4,096-byte verified majority displaces a held answer with every slot cold.
  - Callback gas is measured by a probe at the Intake address making the 200k call. Against the revised contract, a one-word answer to a fresh question costs about 118.6k and the 4,096-byte cap about 156.2k. The brief quotes ~105k.
  - Any failure status from 1 to 255 settles the ask once.
  - One fuzzed attestation drives every verification condition (signer, domain, quorum, expiry, issuance tolerance) on both sides.
  - Also covered: the high-s twin, 0/1 recovery ids, a contract as the asker (not `tx.origin`), repeated identical bodies, and reads of keys nothing touched.
- `AskSwarmRegistryIndexInvariant.t.sol`:
  - Runs 192 sequences of 64 calls. Honest and hostile deliveries (wrong key, other registry's domain, high-s, 64-byte signature, oversized answer, a field changed after signing, issuance up to 10 minutes ahead or up to a day behind) mix with failures of any status, replays of settled ids, empty failure completions that strand an ask, `markLost` and `reindex` from any caller on any record, direct hook calls from every non-Intake caller, and time jumps.
  - After every call, whichever handler made it, an index move must go to an `Answered`, verified, strict-majority answer of the same question. While the held answer is current, the new one must be at least as large a panel, as much agreement, as fresh (`issuedAt`) and as long-lived (`expiresAt`), and strictly better on one of those when `reindex` made the move.
  - `markLost` settles exactly the asks Intake completed without delivering, as `Lost` with no answer. It refuses open asks with `StillOpen` and settled ones with `AlreadySettled`.
  - Settled records are byte-identical to their snapshot, and Intake completed every settled ask. The registry holds no IMD, ETH or Intake allowance, and every fee reaches Intake's recipient.
  - `test_handlersReachLostAndReindexMoves` checks that the handlers actually reach a `Lost` ask and a `reindex` move. Dropping the `expiresAt` leg from `_mayDisplace` makes the campaign fail.

The second launch's revision fixed three of this pass's earlier reports: shorter-lived answers evicting current ones, asks stuck `Pending`, and `ask` having no price ceiling. `AskSwarmRegistryReview.t.sol` covers those fixes.

Reported in `.imd-findings.json`, not asserted:
- After the held answer expires, a weaker fallback answer that was issued later can take the index. A stronger valid answer already on record then cannot take it back (low, with a failing proof).
- The callback's gas cost is above the brief's figure but still under the stipend (info).

The live-fork run against Intake v2 and IMD on Ethereum is still owed for this pass. Everything here runs offline against the transport model.

## Robinhood Chain launch: the three contracts as one system

- `RobinhoodSystemInvariant.t.sol` deploys AskSwarmRegistry, SwarmMarket and SwarmWager in one call (CREATE2, registry first, chain 4663) and drives all three through one shared registry: 128 sequences of 80 calls from four actors over open/stake/top-up/resolve/abandon/settle/claim, create/join/cancel/top-up/resolve/abandon/settle, writer deliveries in eleven modes (yes, no, panel of 5, issued near the deadline, non-canonical bool, wrong answer type, wrong key, no strict majority, refused, no result, stranded then `markLost`), price changes, time jumps, and whole-lifecycle steps so decided markets appear in every run. Reverts fail the campaign; each expected revert is asserted with its error.
- Each settlement is checked against the outcome computed from what was delivered (decided only by a verified canonical bool from a strict majority, panel >= 7 and issued by the deadline for the market; any verified strict-majority bool for the wager), including the 2% fee split creator/treasury and the parimutuel claim rule written from ghost stakes.
- Invariants: each consumer holds exactly what it owes from ghost accounting (escrow + open stakes - fees - claims); claims never exceed what a market holds (dust < 1 wei per staker); finished markets and wagers never reopen; the registry keeps no IMD or allowance, the consumers leave no allowance; one Intake payment per resolve; token supply conserved.
- SwarmWager now zeroes `fee` on cancel/abandon (reported last round). The invariant asserts that every finished wager has a zero fee escrow.
- `BlockedPartyInvariant.t.sol` runs the real registry, market and wager on a stand-in for Robinhood Chain's blockable IMD. It does 96 sequences of 64 calls, and the four actors and the treasury are blocked and unblocked at random between lifecycle calls, deliveries and `withdraw`. Each push is predicted from the brief:
  - A push to a third party (creator remainder, fee halves, abandon/void/refund stakes) lands, or is credited to `owed` while the receiver is blocked.
  - The caller's own payout (claim, a paid wager's pot, cancel, withdraw) reverts and stays open while the caller is blocked.
  - Pulls from a blocked address revert.
  - Invariants: per-party `owed` equals the prediction on both contracts. Each contract's balance equals its open books plus all `owed`. Supply is conserved, finished markets and wagers never reopen, and Intake is paid once per ask.
  - `test_handlerReachesCreditsAndWithdrawals` and a probe of the random campaign both show the credit, blocked-withdraw, withdraw, blocked-claim, blocked-winner and settle-past-blocked-party paths are reached.
- Reported in `.imd-findings.json` (info): SwarmWager does not apply SwarmMarket's MIN_PANEL or issuedAt deadline. SwarmMarket's rounding dust cannot be recovered. A blocked winner's own payout waits until the token unblocks it.
- Still owed: a fork run against Intake v2 and IMD on Robinhood Chain (no RPC here).
