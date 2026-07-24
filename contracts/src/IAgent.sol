// SPDX-License-Identifier: CC0-1.0
pragma solidity >=0.8.20;

/**
 * @dev Interface of the FAT (Fungible Agent Tokens) protocol.
 *
 * This is the normative interface from §4 of the FAT specification, together
 * with the normative events of §5. A compliant Agent MUST also implement
 * ERC-20 for its Share token and advertise support via ERC-165 using
 * `type(IAgent).interfaceId`.
 */
interface IAgent {
    /**
     * @dev Emitted when `requester` opens a mint request by depositing
     * `assets` of the Accept Token. `epoch` is the Agent's current settlement
     * epoch (MAY be 0); `timestamp` is `block.timestamp` at emission.
     */
    event MintRequested(address indexed requester, uint256 assets, uint64 indexed epoch, uint256 timestamp);

    /**
     * @dev Emitted when `requester` opens a redeem request by escrowing
     * `shares` of the Share token. `epoch` is the Agent's current settlement
     * epoch (MAY be 0); `timestamp` is `block.timestamp` at emission.
     */
    event RedeemRequested(address indexed requester, uint256 shares, uint64 indexed epoch, uint256 timestamp);

    /**
     * @dev Emitted when a mint claim is collected for `requester`. Because a
     * claim collects the entire claimable balance, which MAY span several
     * settlements, the fields report the aggregate: `assets` and `shares` are
     * the totals the claim converts between, `sharePrice` is the effective
     * settled rate `assets * 1e18 / shares` (0 when `shares` is 0), and
     * `epoch` is the most recent settlement epoch included.
     */
    event SharesMinted(
        address indexed requester,
        uint256 assets,
        uint256 shares,
        uint64 indexed epoch,
        uint256 sharePrice,
        uint256 timestamp
    );

    /**
     * @dev Emitted when a redeem claim is collected for `requester`. Fields
     * mirror {SharesMinted}: `shares` were redeemed to produce the `assets`
     * payout, in aggregate across the settlements the claim collects.
     */
    event SharesRedeemed(
        address indexed requester,
        uint256 shares,
        uint256 assets,
        uint64 indexed epoch,
        uint256 sharePrice,
        uint256 timestamp
    );

    /**
     * @dev SHOULD be emitted whenever `exchangeRate()` changes (e.g. at NAV
     * settlement). A constant-rate (fixed-price) Agent need never emit it.
     */
    event ExchangeRateUpdated(uint256 newRate);

    /**
     * @dev Emitted when the Owner updates the Agent URI.
     */
    event AgentURIUpdated(string newURI);

    /**
     * @dev Emitted on every successful {execute}. `selector` is the first 4
     * bytes of the calldata, `0x00000000` if `data.length < 4`. The reasoning
     * fields anchor the agent's off-chain reasoning record (spec §6.2). A
     * failed call reverts and emits nothing.
     */
    event Executed(
        address indexed executor,
        address indexed target,
        uint256 value,
        bytes4 indexed selector,
        bytes returnData,
        bytes32 reasoningHash,
        string reasoningURI
    );

    /**
     * @dev Emitted when an Executor settles a pending request (spec §6.3,
     * §6.4). `kind` is 0 for mint and 1 for redeem; `amount` is the shares
     * (mint) or Accept Token (redeem) made claimable.
     */
    event Settled(
        address indexed requester,
        uint8 kind,
        uint256 amount,
        bytes32 indexed reasoningHash,
        string reasoningURI
    );

    /**
     * @dev SHOULD be emitted by an implementer's own agent-facing functions to
     * attach reasoning uniformly (spec §6.2.4). The standard operations —
     * `settleMint`, `settleRedeem`, `execute` — carry reasoning in their own
     * events instead.
     */
    event Reasoned(address indexed actor, bytes4 indexed action, bytes32 indexed reasoningHash, string reasoningURI);

    /**
     * @dev Emitted when the Owner enables or disables an Executor.
     */
    event ExecutorUpdated(address indexed executor, bool enabled);

    /**
     * @dev Returns the single ERC-20 accepted for share purchase and paid out
     * on redemption. MUST return the same address for the lifetime of the
     * Agent.
     */
    function acceptToken() external view returns (address);

    /**
     * @dev Returns the address of the ERC-20 Share token. MAY return
     * `address(this)` if the Agent contract itself is the ERC-20.
     */
    function shareToken() external view returns (address);

    /**
     * @dev Phase 1 of minting: deposits `amount` of the Accept Token, adding
     * to the caller's pending mint balance. MUST pull exactly `amount` via
     * ERC-20 `transferFrom`; MUST NOT accept native ether. The share count is
     * determined later, at settlement. MUST emit {MintRequested}.
     */
    function requestMint(uint256 amount) external;

    /**
     * @dev Phase 2 of minting: claims ALL currently-claimable shares for
     * `user`. Permissionless: any caller MAY trigger the claim, but the
     * shares are always minted to `user` (the owed party), so the caller only
     * pays gas. MUST mint `user`'s entire claimable-share balance, zero that
     * balance, and emit {SharesMinted}. Takes no slippage guard: the share
     * count was already fixed at settlement (spec §6.3). Returns the number
     * of shares minted (0 if nothing is claimable).
     */
    function mint(address user) external returns (uint256 shares);

    /**
     * @dev Agent reaction: settles `requester`'s pending mint request, with
     * reasoning attached. Executor only. Settles some, all, or none of the
     * requester's pending assets into claimable shares; the amount and price
     * are computed by the implementation inside. MUST emit {Settled}.
     * `reasoningHash` MUST be non-zero and `reasoningURI` non-empty and
     * resolvable (spec §6.2).
     */
    function settleMint(address requester, bytes32 reasoningHash, string calldata reasoningURI) external;

    /**
     * @dev Returns the aggregate mint status for `user`: `pendingAssets`
     * deposited but not yet settled, and `claimableShares` settled and
     * awaiting a {mint} claim.
     */
    function queryMintStatus(address user)
        external
        view
        returns (uint256 pendingAssets, uint256 claimableShares);

    /**
     * @dev Phase 1 of redemption: escrows `shares`, adding to the caller's
     * pending redeem balance. MUST pull (escrow) exactly `shares` of the
     * Share token from the caller. Settled shares are burned at settlement;
     * the payout is priced then. MUST emit {RedeemRequested}.
     */
    function requestRedeem(uint256 shares) external;

    /**
     * @dev Phase 2 of redemption: claims ALL currently-claimable Accept Token
     * for `user`. Permissionless: any caller MAY trigger the claim, but the
     * payout always goes to `user` (the owed party). MUST transfer `user`'s
     * entire claimable-token balance, zero that balance, and emit
     * {SharesRedeemed}. Takes no slippage guard: the payout was already fixed
     * at settlement (spec §6.4). Returns the Accept Token transferred (0 if
     * nothing is claimable).
     */
    function redeem(address user) external returns (uint256 tokens);

    /**
     * @dev Agent reaction: settles `requester`'s pending redeem request, with
     * reasoning attached. Executor only. Symmetric to {settleMint}: settles
     * pending shares into claimable Accept Token, burning the settled shares.
     * MUST emit {Settled}.
     */
    function settleRedeem(address requester, bytes32 reasoningHash, string calldata reasoningURI) external;

    /**
     * @dev Returns the aggregate redeem status for `user`: `pendingShares`
     * escrowed but not yet settled, and `claimableTokens` settled and
     * awaiting a {redeem} claim.
     */
    function queryRedeemStatus(address user)
        external
        view
        returns (uint256 pendingShares, uint256 claimableTokens);

    /**
     * @dev Returns the canonical valuation rate: how many Accept-Token
     * base-units one 1e18 Share base-units are worth right now (wei-to-wei,
     * 18-decimal fixed point): `x` Share wei are worth `x * rate / 1e18`
     * Accept-Token wei. A share-valuation / NAV reference for tooling — NOT a
     * predictor of mint/redeem outcomes, which are fixed at settlement and
     * reported by {queryMintStatus} / {queryRedeemStatus}.
     */
    function exchangeRate() external view returns (uint256 rate);

    /**
     * @dev Returns the URI pointing to off-chain JSON metadata describing the
     * Agent (spec §6.5).
     */
    function agentURI() external view returns (string memory);

    /**
     * @dev Sets the Agent URI. Owner only. MUST emit {AgentURIUpdated}.
     */
    function setAgentURI(string calldata uri) external;

    /**
     * @dev Executor dispatch, with reasoning and scope enforcement.
     *
     * MUST revert unless the caller is an Executor. MUST NOT dispatch via
     * `DELEGATECALL` (spec §6.6.2). MUST NOT be `payable`; `value` is paid
     * from the Agent's own balance (spec §6.6.4). MUST call
     * {isInScope}`(target, value, data)` and revert if it returns false (spec
     * §6.6.7). MUST bubble the revert data unchanged on failure (and emit no
     * event then). MUST emit {Executed}, carrying the reasoning, on success.
     *
     * Beyond the Executor check, the `DELEGATECALL` prohibition, and the
     * {isInScope} gate, implementers MAY layer any further policy on top of
     * this function.
     */
    function execute(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 reasoningHash,
        string calldata reasoningURI
    ) external returns (bytes memory returnData);

    /**
     * @dev Enables or disables `account` as an Executor. Owner only. MUST
     * emit {ExecutorUpdated}.
     */
    function setExecutor(address account, bool enabled) external;

    /**
     * @dev Returns the address currently authorized to invoke Owner-gated
     * functions. The mechanism by which this value changes is outside the
     * scope of the FAT specification.
     */
    function owner() external view returns (address);

    /**
     * @dev Returns true if `account` is a currently-enabled Executor.
     */
    function isExecutor(address account) external view returns (bool);

    /**
     * @dev Returns whether an {execute} to (`target`, `value`, `data`) is
     * within the Agent's spend scope. Implementer-defined predicate that
     * {execute} MUST consult (spec §6.6.7); its backing configuration MUST be
     * changeable only by the Owner (spec §6.6.8). Also usable as an off-chain
     * audit query.
     */
    function isInScope(address target, uint256 value, bytes calldata data) external view returns (bool);
}
