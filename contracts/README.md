# FAT Protocol — Reference Implementations

Two reference implementations of the **FAT (Fungible Agent Tokens)** protocol
([`../docs/fat-protocol-spec.md`](../docs/fat-protocol-spec.md)):

| Contract | Deployment shape | Upgrade authority |
|---|---|---|
| `src/FATAgent.sol` | Direct deployment; `acceptToken` is `immutable` | None — fully immutable |
| `src/FATAgentUpgradeableV1.sol` | Behind an ERC-1967 proxy (UUPS); ERC-7201 namespaced storage | Owner (`_authorizeUpgrade` → `onlyOwner`) |

`src/IAgent.sol` is the normative §4 interface plus the §5 events. Both
implementations are behaviorally identical; the shared test suite
(`test/AgentBehavior.t.sol`) runs against both.

> **Reference code.** Written for clarity and spec traceability, not gas.
> Do not deploy to production without an independent audit.

## Build & test

```bash
git submodule update --init   # restore pinned dependencies into lib/
forge build
forge test
```

Requires [Foundry](https://getfoundry.sh). Dependencies (git submodules,
also pinned in `foundry.lock`): forge-std v1.16.2, OpenZeppelin Contracts
v5.6.1 (+ upgradeable).

## Policy choices (spec §7 disclosure)

The FAT spec deliberately leaves these to implementers; this reference picks
one simple, sound policy for each and documents it:

| §7 item | This reference |
|---|---|
| Pricing formula | Settlement converts the requester's **entire** pending balance at the stored `exchangeRate` (Accept-Token wei per 1e18 Share wei) |
| Rate source | Executor-reported NAV via `updateExchangeRate(newRate, reasoningHash, reasoningURI)` — a reasoned agent action (§6.2) emitting `Reasoned` + `ExchangeRateUpdated`. **Trust disclosure:** the Executor prices the book; reasoning records make each report auditable after the fact, not correct by construction |
| Epoch | Starts at 1; increments on every `updateExchangeRate` (a rate epoch = a settlement round) |
| Fees | None |
| Share transferability | Unrestricted ERC-20 (the Agent contract is the Share token; `shareToken() == address(this)`) |
| Scope policy (`isInScope`) | Owner-managed `(target, selector)` allowlist + per-target `maxCallValue` ether cap; calldata shorter than 4 bytes matches selector `0x00000000` (plain value transfer); default-deny |
| Redemption liquidity | `settleRedeem` requires free balance (Agent's Accept-Token balance minus unsettled deposits minus already-reserved payouts) to cover the payout; otherwise it reverts and the request stays pending |
| Pending-window NAV treatment (§6.4.7) | Unsettled mint deposits are **not** part of NAV and not spendable toward redemptions (`totalPendingAssets` is excluded); settled-but-unclaimed payouts are reserved (`totalClaimableTokens`) |
| Cancellation / expiry | Not supported |
| Batch settlement / batch execute | Not provided |
| Fee-on-transfer / rebasing Accept Token | **Unsupported** (§6.3.1 documentation requirement) |
| Pause | None |
| Ownership transfer | Two-step (`Ownable2Step`). Renouncing ownership freezes the executor set, URI, and Scope — and for the UUPS version, the implementation — forever |
| Sweep / rescue | None |
| Meta-transactions | None |
| Reentrancy (§6.8) | `nonReentrant` on `requestMint`, `mint`, `requestRedeem`, `redeem`, `settleMint`, `settleRedeem`, `execute` |

## Extending the reference implementations

Every state-changing entry point is `virtual`, and the accounting logic is
factored through OpenZeppelin-style hooks so you can inherit either version
and layer your own policy without re-implementing the request/settle/claim
bookkeeping:

| Hook | Called by | Use for |
|---|---|---|
| `_beforeRequestMint(requester, assets)` | `requestMint`, before the deposit is pulled | KYC / allowlists, min/max deposit, per-address caps, subscription windows |
| `_beforeRequestRedeem(requester, shares)` | `requestRedeem`, before the escrow | Lockups, redemption windows, minimum holding sizes |
| `_settleMintAmounts(requester, pendingAssets) → (assets, shares)` | `settleMint` | Entry fees, differentiated pricing, quotas, **partial settlement** (return `assets < pendingAssets`; the rest stays pending) |
| `_settleRedeemAmounts(requester, pendingShares) → (shares, tokens)` | `settleRedeem` | Exit fees, withdrawal tiers, partial settlement |
| `_beforeExecute(target, value, data)` | `execute`, after the Scope check | Extra policy per spec §6.6.5: rate limits, circuit breakers, target bans |
| `_afterExecute(target, value, data, returnData)` | `execute`, after a successful call | Position accounting, post-call invariant checks |

Defaults preserve the reference behavior (settle everything at
`exchangeRate()`, fee-free, no extra execute policy). `settleMint` /
`settleRedeem` still validate whatever the hooks return: zero settlements
revert, and a hook can never settle more than the pending balance. Note that
`_beforeExecute` policy is *in addition to* — never instead of — the
Owner-set `isInScope` gate the standard requires.

`test/Hooks.t.sol` contains a worked example (`HookedAgent`) exercising all
six hooks: minimum deposit, redemption window, 1% entry fee, per-call
settlement cap, target veto, and execute accounting.

## Layout

```
src/IAgent.sol                 normative interface + events (spec §4/§5)
src/FATAgent.sol               immutable reference implementation
src/FATAgentUpgradeableV1.sol  UUPS reference implementation
test/AgentBehavior.t.sol       shared conformance/lifecycle suite (runs on both)
test/Upgrade.t.sol             UUPS-specific: authorization, state preservation,
                               ERC-7201 slot derivation, bricked implementation
test/Hooks.t.sol               HookedAgent example subclass exercising all hooks
test/mocks/                    MockERC20, MockTarget
```
