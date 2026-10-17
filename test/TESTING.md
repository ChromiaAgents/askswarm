# AskSwarmRegistry test coverage

The submitted tests run offline with the repository's existing forge-std dependency. Production
contracts and Foundry configuration are unchanged. Run `forge build` and `forge test` from the
repository root. The assignment's reproducible fuzz seed is:

```sh
FOUNDRY_FUZZ_SEED=0x28943f700d04825800d96b18a778ccd0eec1e0461757d74accd287b7ad0e1a4c forge test
```

- `AskSwarmRegistryPayments.t.sol` covers exact fee forwarding, changing prices, body limits,
  insufficient funds/approval, malformed or unsuccessful ERC20 calls, no-return tokens, Intake
  rejection before and after payment, donation isolation, and rejected ETH payments. Reverts must
  leave balances, approvals, request records, and counters unchanged.
- `AskSwarmRegistryCallbacks.t.sol` covers tampering with every signed field, wrong signers and
  domains, invalid signature lengths/recovery values, a valid false answer, distinct oracle/intake
  identifiers, byte-exact short answers, nonzero ABI padding, long-answer hashes and events, the
  4,096/4,097-byte boundary, both failure statuses, access checks, filtered reads, expiry transitions,
  and both dimensions of panel strength. Delivery uses a 200,000-gas call.
- `AskSwarmRegistryInvariant.t.sol` runs 256 sequences of 96 calls with three funded callers.
  Eight handlers exercise successful and reverted asks, donations, signed/invalid/expired/oversized
  answers, refusals, time changes, unauthorized callbacks, and transport retries. Ghost accounting
  tracks each caller's payments and donations. Checks cover conservation, exact fee forwarding,
  zero remaining Intake approval, request counts, immutable settled records under ordinary Intake
  routing, and coherent majority-only question indexes. Seeded setup reaches meaningful states
  even before random calls begin. Unexpected handler reverts fail the campaign.
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

The random campaign exercises correct Intake argument pairing. It does not assert that the
registry itself rejects repeated trusted callbacks. Three separate failing regressions are
reported with their complete standalone sources in `.imd-findings.json`: settled-record overwrite
through another request's completion, future issuance beyond the canonical clock tolerance, and
the cached domain after a chain-id-changing fork. Their preconditions and low severity are stated
there. Those regressions are not converted into passing assertions of incorrect behavior.
