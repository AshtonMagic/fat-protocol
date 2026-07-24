# Fungible Agent Tokens (FAT) Protocol (draft)

**Status:** Draft

**FAT (Fungible Agent Tokens)** is a tokenization standard that turns AI agents into on-chain assets, unifying three layers into one composable interface: **on-chain execution** (the agent acts on external protocols and manages capital), **tokenized ownership** (fungible shares in an agent's performance), and **off-chain attestation** (metadata and per-action reasoning anchoring the agent's intelligence to its on-chain identity).

Concretely, a minimal ERC-style standard for **FAT Agents** — the on-chain representation of an off-chain agent, not merely a vault: EVM contracts that accept a single ERC-20 in exchange for fungible shares (the *Fungible Agent Tokens*), support two-phase (request-then-claim) share minting and redemption against a queryable exchange rate, expose discoverable Agent metadata, and provide a low-level dispatch primitive for a designated off-chain Executor to call third-party protocols on behalf of the Agent within an Owner-set `isInScope` boundary.

## Specification

- [English (authoritative)](docs/fat-protocol-spec.md)
- [中文翻译](docs/fat-protocol-spec.zh-CN.md)

If the translations diverge, the English document is the authoritative source.

## Reference implementations

Two Solidity reference implementations live under [`contracts/`](contracts/):

- **`FATAgent`** — non-upgradeable (immutable) version;
- **`FATAgentUpgradeableV1`** — upgradeable version (UUPS proxy, ERC-7201 namespaced storage, Owner-gated upgrades).

Both are behaviorally identical and pass a shared Foundry conformance suite; see [`contracts/README.md`](contracts/README.md) for build instructions and the full disclosure of the implementer-defined (§7) policy choices they make. They are reference code — unaudited, written for clarity and spec traceability, not production deployment.

## Scope

The standard **defines**:

- A single immutable Accept Token and a fungible Share token (ERC-20).
- A two-phase `requestMint` / `mint` and `requestRedeem` / `redeem` flow for primary-market issuance and burn against the Agent's own holdings — request now, claim once the Agent settles — with a queryable `exchangeRate` valuation reference.
- Reasoned agent settlement (`settleMint` / `settleRedeem`) as the Agent's explicit reaction to a pending mint / redeem request, turning pending amounts into claimable ones.
- A tamper-evident reasoning record (`reasoningHash` + `reasoningURI`) attached to every agent action — settlement and `execute` alike — anchoring off-chain reasoning on-chain.
- An Owner-set `isInScope` spend boundary enforced on `execute`, bounding what the Executor may spend on the Agent's behalf.
- An Agent URI pointer for off-chain metadata (name, description, image, etc.), in the spirit of ERC-8004 agent metadata.
- An `execute` dispatch primitive for a designated Executor to call arbitrary third-party protocols under the Agent's identity, subject to (a) an `onlyExecutor` check, (b) a `DELEGATECALL` prohibition, and (c) the Owner-set `isInScope` gate.
- A minimal Owner role for rotating Executors, configuring the Scope, and updating the Agent URI.

The standard **deliberately does not define**: share pricing formulas, fee magnitudes, share transferability, the settlement trigger/timing of requests, request cancellation, request expiry, batched/epoch settlement, redemption lockups, separate dividend / reward / yield-claim channels, pause mechanisms, ownership-transfer mechanisms, emergency asset-rescue functions, batched executor dispatch, the contents/format of the reasoning record behind `reasoningURI`, or the concrete Scope policy that `isInScope` encodes. The settlement operation, the reasoning anchoring, and the scope gate themselves are now defined; their pricing/quota logic, reasoning payloads, and scope rules remain left to the implementer.

## Numbering

This standard is named the **Fungible Agent Tokens (FAT) Protocol**. No ERC/EIP number is assigned yet; a formal number will be requested if and when this document is submitted to the Ethereum Magicians process.

## License

[CC0-1.0](https://creativecommons.org/publicdomain/zero/1.0/). Copyright and related rights waived.
