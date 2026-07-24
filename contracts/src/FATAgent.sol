// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IAgent} from "./IAgent.sol";

/**
 * @dev Non-upgradeable reference implementation of the FAT (Fungible Agent
 * Tokens) protocol, as specified in {IAgent}. The Agent contract itself is the
 * ERC-20 Share token (`shareToken() == address(this)`).
 *
 * The FAT specification deliberately leaves a set of policy surfaces to the
 * implementer (spec §7). This reference chooses:
 *
 * - Pricing: settlement converts the requester's entire pending balance at the
 *   stored exchange rate — an Executor-reported NAV updated through the
 *   reasoned agent action {updateExchangeRate}. No fees.
 * - Scope: an Owner-managed (target, selector) allowlist plus a per-target
 *   {maxCallValue} ether cap. Default-deny.
 * - Epoch: increments on every {updateExchangeRate} (a rate epoch is a
 *   settlement round).
 * - Shares are freely transferable; no pause, no cancellation or expiry, no
 *   sweep, no meta-transactions, no batch settlement.
 * - Fee-on-transfer and rebasing Accept Tokens are UNSUPPORTED (spec §6.3.1).
 * - Ownership transfer is two-step ({Ownable2Step}); renouncing ownership
 *   freezes the executor set, the Agent URI, and the Scope forever.
 *
 * ==== Extending this contract
 *
 * Every state-changing entry point is `virtual`, and the accounting logic is
 * factored through dedicated hooks so inheritors can layer their own policy
 * without re-implementing the request/settle/claim bookkeeping:
 *
 * - {_beforeRequestMint} and {_beforeRequestRedeem} — eligibility policy
 *   (KYC, allowlists, minimum sizes) enforced when a request is opened.
 * - {_settleMintAmounts} and {_settleRedeemAmounts} — the pricing formula:
 *   fees, differentiated pricing, quotas, and partial settlement.
 * - {_beforeExecute} and {_afterExecute} — additional `execute` policy layered
 *   on top of the Owner-set Scope (spec §6.6.5): rate limits, circuit
 *   breakers, position accounting, and similar.
 *
 * NOTE: This is reference code, written for clarity and spec traceability
 * rather than gas efficiency. Do not deploy it to production without an
 * independent audit.
 */
contract FATAgent is IAgent, ERC20, Ownable2Step, ReentrancyGuard, ERC165 {
    using SafeERC20 for IERC20;

    /**
     * @dev The caller is not a currently-enabled Executor.
     */
    error NotExecutor(address account);

    /**
     * @dev The requested amount is zero.
     */
    error ZeroAmount();

    /**
     * @dev `requester` has no pending balance to settle.
     */
    error NothingPending(address requester);

    /**
     * @dev The settlement hook settled zero of the pending balance. (A
     * settlement whose *output* rounds to zero is not an error: the settled
     * input is refunded — see {MintRefunded} and {RedeemRefunded}.)
     */
    error SettlementRoundsToZero();

    /**
     * @dev A settlement hook returned more than the requester's pending balance.
     */
    error SettlementExceedsPending(uint256 settled, uint256 pending);

    /**
     * @dev The reasoning envelope is invalid: the hash is zero or the URI is
     * empty (spec §6.2).
     */
    error InvalidReasoning();

    /**
     * @dev The call is outside the Owner-configured Scope (spec §6.6.7).
     */
    error OutOfScope(address target, uint256 value, bytes4 selector);

    /**
     * @dev The Agent's free Accept-Token balance cannot cover the redemption
     * payout. The request stays pending until liquidity allows settlement.
     */
    error InsufficientLiquidity(uint256 needed, uint256 available);

    /**
     * @dev An {execute} call left the Agent's Accept-Token balance below the
     * reserved amount: unsettled mint deposits plus settled-but-unclaimed
     * redemption payouts (spec §6.4.7).
     */
    error ReservesBreached(uint256 required, uint256 available);

    /**
     * @dev The exchange rate is zero.
     */
    error InvalidRate();

    /**
     * @dev The zero address was supplied where an address is required.
     */
    error ZeroAddress();

    /**
     * @dev Emitted when the Owner allows or disallows a (target, selector)
     * pair in the Scope (spec §6.6.8).
     */
    event ScopeUpdated(address indexed target, bytes4 indexed selector, bool allowed);

    /**
     * @dev Emitted when the Owner changes the maximum ether value `execute`
     * may attach to a call to `target`.
     */
    event MaxCallValueUpdated(address indexed target, uint256 maxValue);

    /**
     * @dev Emitted when a mint settlement's conversion rounds to zero shares
     * and the settled deposit is refunded to the requester instead. Without a
     * cancellation mechanism, rejecting the settlement would strand the
     * deposit forever.
     */
    event MintRefunded(address indexed requester, uint256 assets, bytes32 indexed reasoningHash, string reasoningURI);

    /**
     * @dev Emitted when a redeem settlement's conversion rounds to zero
     * Accept Token and the escrowed shares are returned to the requester
     * instead. Mirrors {MintRefunded}.
     */
    event RedeemRefunded(address indexed requester, uint256 shares, bytes32 indexed reasoningHash, string reasoningURI);

    /**
     * @dev Aggregate mint-side request state for one requester (spec §2
     * "Request": requests are fungible per requester, tracked in aggregate).
     */
    struct MintState {
        uint256 pendingAssets; // deposited, awaiting settlement
        uint256 claimableShares; // settled, awaiting claim
        uint256 settledAssets; // assets basis of claimableShares (for SharesMinted)
        uint64 settledEpoch; // most recent settlement epoch included
    }

    /**
     * @dev Aggregate redeem-side request state for one requester.
     */
    struct RedeemState {
        uint256 pendingShares; // escrowed, awaiting settlement
        uint256 claimableTokens; // settled, awaiting claim
        uint256 settledShares; // shares basis of claimableTokens (for SharesRedeemed)
        uint64 settledEpoch; // most recent settlement epoch included
    }

    address private immutable _acceptToken;

    uint256 private _exchangeRate; // Accept-Token wei per 1e18 Share wei
    uint64 private _epoch; // settlement round; bumps on updateExchangeRate
    string private _agentURI;

    mapping(address account => bool) private _executors;
    mapping(address requester => MintState) private _mints;
    mapping(address requester => RedeemState) private _redeems;

    /**
     * @dev Accept Token held for not-yet-settled mint requests. Not part of
     * NAV until settled, and not spendable toward redemptions (spec §6.4.7).
     */
    uint256 public totalPendingAssets;

    /**
     * @dev Accept Token reserved for settled-but-unclaimed redemptions.
     */
    uint256 public totalClaimableTokens;

    /**
     * @dev Scope backing (spec §6.6.7–8): Owner-only configuration, default-deny.
     */
    mapping(address target => mapping(bytes4 selector => bool)) public scopeAllowed;

    /**
     * @dev Maximum ether value `execute` may attach per call, per target.
     */
    mapping(address target => uint256) public maxCallValue;

    /**
     * @dev Sets the immutable Accept Token and the initial rate, URI, and
     * Owner. `initialRate_` is Accept-Token wei per 1e18 Share wei and cannot
     * be zero. The epoch starts at 1.
     */
    constructor(
        address acceptToken_,
        string memory name_,
        string memory symbol_,
        address owner_,
        uint256 initialRate_,
        string memory initialURI_
    ) ERC20(name_, symbol_) Ownable(owner_) {
        if (acceptToken_ == address(0)) revert ZeroAddress();
        if (initialRate_ == 0) revert InvalidRate();
        _acceptToken = acceptToken_;
        _exchangeRate = initialRate_;
        _epoch = 1;
        _agentURI = initialURI_;
    }

    /**
     * @dev The Agent may hold ether to fund `execute` value transfers (spec
     * §6.6.4). Ether is never accepted as payment for Shares (spec §6.1.2).
     */
    receive() external payable {}

    /**
     * @dev Throws if called by any account that is not a currently-enabled
     * Executor.
     */
    modifier onlyExecutor() {
        if (!_executors[msg.sender]) revert NotExecutor(msg.sender);
        _;
    }

    /**
     * @dev Validates the reasoning envelope of an agent action (spec §6.2):
     * non-zero hash, non-empty URI. The correspondence between the hash and
     * the content behind the URI is verified off-chain by auditors.
     */
    modifier withReasoning(bytes32 reasoningHash, string calldata reasoningURI) {
        if (reasoningHash == bytes32(0) || bytes(reasoningURI).length == 0) {
            revert InvalidReasoning();
        }
        _;
    }

    /**
     * @dev See {IAgent-acceptToken}.
     */
    function acceptToken() public view virtual returns (address) {
        return _acceptToken;
    }

    /**
     * @dev See {IAgent-shareToken}. This Agent is its own Share token.
     */
    function shareToken() public view virtual returns (address) {
        return address(this);
    }

    /**
     * @dev See {IAgent-requestMint}. Calls {_beforeRequestMint} before pulling
     * the deposit.
     */
    function requestMint(uint256 amount) public virtual nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _beforeRequestMint(msg.sender, amount);
        IERC20(_acceptToken).safeTransferFrom(msg.sender, address(this), amount);
        _mints[msg.sender].pendingAssets += amount;
        totalPendingAssets += amount;
        emit MintRequested(msg.sender, amount, _epoch, block.timestamp);
    }

    /**
     * @dev See {IAgent-settleMint}. The settled portion and the share count
     * are computed by {_settleMintAmounts}; because they are computed by
     * contract logic rather than supplied by the caller, the Executor cannot
     * mint an arbitrary amount (spec §6.3.4). If the conversion rounds to
     * zero shares, the settled deposit is refunded to the requester instead
     * of being stranded ({MintRefunded}).
     */
    function settleMint(address requester, bytes32 reasoningHash, string calldata reasoningURI)
        public
        virtual
        onlyExecutor
        withReasoning(reasoningHash, reasoningURI)
        nonReentrant
    {
        MintState storage m = _mints[requester];
        uint256 pending = m.pendingAssets;
        if (pending == 0) revert NothingPending(requester);

        (uint256 assets, uint256 shares) = _settleMintAmounts(requester, pending);
        if (assets == 0) revert SettlementRoundsToZero();
        if (assets > pending) revert SettlementExceedsPending(assets, pending);

        if (shares == 0) {
            // The conversion rounds to zero shares. With no cancellation
            // mechanism, rejecting would strand the deposit forever; refund it.
            m.pendingAssets = pending - assets;
            totalPendingAssets -= assets;
            IERC20(_acceptToken).safeTransfer(requester, assets);
            emit Settled(requester, 0, 0, reasoningHash, reasoningURI);
            emit MintRefunded(requester, assets, reasoningHash, reasoningURI);
            return;
        }

        m.pendingAssets = pending - assets;
        m.claimableShares += shares;
        m.settledAssets += assets;
        m.settledEpoch = _epoch;
        totalPendingAssets -= assets; // deposit enters the Agent's working capital

        emit Settled(requester, 0, shares, reasoningHash, reasoningURI);
    }

    /**
     * @dev See {IAgent-mint}. Permissionless claim crank: callable by anyone,
     * always mints to `user` (the owed party). Returns 0 without emitting if
     * nothing is claimable.
     */
    function mint(address user) public virtual nonReentrant returns (uint256 shares) {
        MintState storage m = _mints[user];
        shares = m.claimableShares;
        if (shares == 0) return 0;

        uint256 assets = m.settledAssets;
        uint64 epoch = m.settledEpoch;
        m.claimableShares = 0;
        m.settledAssets = 0;

        _mint(user, shares);
        emit SharesMinted(user, assets, shares, epoch, (assets * 1e18) / shares, block.timestamp);
    }

    /**
     * @dev See {IAgent-queryMintStatus}.
     */
    function queryMintStatus(address user)
        public
        view
        virtual
        returns (uint256 pendingAssets, uint256 claimableShares)
    {
        MintState storage m = _mints[user];
        return (m.pendingAssets, m.claimableShares);
    }

    /**
     * @dev See {IAgent-requestRedeem}. Calls {_beforeRequestRedeem} before
     * escrowing the shares (spec §6.4.1).
     */
    function requestRedeem(uint256 shares) public virtual nonReentrant {
        if (shares == 0) revert ZeroAmount();
        _beforeRequestRedeem(msg.sender, shares);
        _transfer(msg.sender, address(this), shares); // escrow
        _redeems[msg.sender].pendingShares += shares;
        emit RedeemRequested(msg.sender, shares, _epoch, block.timestamp);
    }

    /**
     * @dev See {IAgent-settleRedeem}. The settled portion and the payout are
     * computed by {_settleRedeemAmounts}. Requires the Agent's free balance —
     * excluding unsettled deposits and already-reserved payouts — to cover the
     * payout; the escrowed shares burn at settlement (spec §6.4.4). If the
     * conversion rounds to zero Accept Token, the escrowed shares are
     * returned to the requester instead of being stranded ({RedeemRefunded}).
     */
    function settleRedeem(address requester, bytes32 reasoningHash, string calldata reasoningURI)
        public
        virtual
        onlyExecutor
        withReasoning(reasoningHash, reasoningURI)
        nonReentrant
    {
        RedeemState storage r = _redeems[requester];
        uint256 pending = r.pendingShares;
        if (pending == 0) revert NothingPending(requester);

        (uint256 shares, uint256 tokens) = _settleRedeemAmounts(requester, pending);
        if (shares == 0) revert SettlementRoundsToZero();
        if (shares > pending) revert SettlementExceedsPending(shares, pending);

        if (tokens == 0) {
            // The conversion rounds to zero Accept Token; return the escrowed
            // shares rather than stranding them (mirrors settleMint's refund).
            r.pendingShares = pending - shares;
            _transfer(address(this), requester, shares);
            emit Settled(requester, 1, 0, reasoningHash, reasoningURI);
            emit RedeemRefunded(requester, shares, reasoningHash, reasoningURI);
            return;
        }

        uint256 available =
            IERC20(_acceptToken).balanceOf(address(this)) - totalPendingAssets - totalClaimableTokens;
        if (tokens > available) revert InsufficientLiquidity(tokens, available);

        r.pendingShares = pending - shares;
        r.claimableTokens += tokens;
        r.settledShares += shares;
        r.settledEpoch = _epoch;
        totalClaimableTokens += tokens;
        _burn(address(this), shares);

        emit Settled(requester, 1, tokens, reasoningHash, reasoningURI);
    }

    /**
     * @dev See {IAgent-redeem}. Permissionless claim crank: callable by
     * anyone, always pays `user` (the owed party). Returns 0 without emitting
     * if nothing is claimable.
     */
    function redeem(address user) public virtual nonReentrant returns (uint256 tokens) {
        RedeemState storage r = _redeems[user];
        tokens = r.claimableTokens;
        if (tokens == 0) return 0;

        uint256 shares = r.settledShares;
        uint64 epoch = r.settledEpoch;
        r.claimableTokens = 0;
        r.settledShares = 0;
        totalClaimableTokens -= tokens;

        IERC20(_acceptToken).safeTransfer(user, tokens);
        emit SharesRedeemed(user, shares, tokens, epoch, (tokens * 1e18) / shares, block.timestamp);
    }

    /**
     * @dev See {IAgent-queryRedeemStatus}.
     */
    function queryRedeemStatus(address user)
        public
        view
        virtual
        returns (uint256 pendingShares, uint256 claimableTokens)
    {
        RedeemState storage r = _redeems[user];
        return (r.pendingShares, r.claimableTokens);
    }

    /**
     * @dev See {IAgent-exchangeRate}.
     */
    function exchangeRate() public view virtual returns (uint256 rate) {
        return _exchangeRate;
    }

    /**
     * @dev Implementer-defined agent action: the Executor reports a new NAV
     * rate, with reasoning attached (spec §6.2.4 — emits {IAgent-Reasoned}),
     * and opens a new settlement epoch.
     *
     * Trust disclosure: the Executor prices the book. Holders trust the
     * Executor's NAV reporting; the reasoning record makes each report
     * auditable after the fact, not correct by construction.
     */
    function updateExchangeRate(uint256 newRate, bytes32 reasoningHash, string calldata reasoningURI)
        public
        virtual
        onlyExecutor
        withReasoning(reasoningHash, reasoningURI)
    {
        if (newRate == 0) revert InvalidRate();
        _exchangeRate = newRate;
        _epoch += 1;
        emit Reasoned(msg.sender, msg.sig, reasoningHash, reasoningURI);
        emit ExchangeRateUpdated(newRate);
    }

    /**
     * @dev Current settlement epoch (spec §2). Starts at 1; bumps on every
     * rate update.
     */
    function currentEpoch() public view virtual returns (uint64) {
        return _epoch;
    }

    /**
     * @dev See {IAgent-agentURI}.
     */
    function agentURI() public view virtual returns (string memory) {
        return _agentURI;
    }

    /**
     * @dev See {IAgent-setAgentURI}.
     */
    function setAgentURI(string calldata uri) public virtual onlyOwner {
        _agentURI = uri;
        emit AgentURIUpdated(uri);
    }

    /**
     * @dev See {IAgent-execute}. Enforces, in order: the Executor check, the
     * reasoning envelope, the Owner-set Scope ({isInScope}), and
     * {_beforeExecute}. Dispatches via plain `CALL` only (spec §6.6.2) with
     * `value` paid from the Agent's own balance (spec §6.6.4), bubbles revert
     * data unchanged (spec §6.6.3), then calls {_afterExecute}, enforces
     * {_checkReserves}, and emits {IAgent-Executed}.
     */
    function execute(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 reasoningHash,
        string calldata reasoningURI
    )
        public
        virtual
        onlyExecutor
        withReasoning(reasoningHash, reasoningURI)
        nonReentrant
        returns (bytes memory returnData)
    {
        bytes4 selector = data.length >= 4 ? bytes4(data[:4]) : bytes4(0);
        if (!isInScope(target, value, data)) revert OutOfScope(target, value, selector);
        _beforeExecute(target, value, data);

        bool success;
        (success, returnData) = target.call{value: value}(data);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }

        _afterExecute(target, value, data, returnData);
        _checkReserves();
        emit Executed(msg.sender, target, value, selector, returnData, reasoningHash, reasoningURI);
    }

    /**
     * @dev Reverts with {ReservesBreached} unless the Agent's Accept-Token
     * balance covers the reserved amount: unsettled mint deposits plus
     * settled-but-unclaimed redemption payouts (spec §6.4.7). Enforced after
     * every {execute} dispatch, so the Executor can only spend free working
     * capital. NOTE: an in-scope `approve` can authorize a later pull that
     * happens outside {execute} and bypasses this check — never allowlist the
     * Accept Token's `approve` in the Scope.
     */
    function _checkReserves() internal view virtual {
        uint256 required = totalPendingAssets + totalClaimableTokens;
        uint256 balance = IERC20(_acceptToken).balanceOf(address(this));
        if (balance < required) revert ReservesBreached(required, balance);
    }

    /**
     * @dev See {IAgent-isInScope}. Reference Scope policy: a (target,
     * selector) allowlist plus a per-target ether cap. Calldata shorter than
     * 4 bytes matches selector `0x00000000` (plain value transfer).
     * Configurable only by the Owner (spec §6.6.8).
     */
    function isInScope(address target, uint256 value, bytes calldata data)
        public
        view
        virtual
        returns (bool)
    {
        bytes4 selector = data.length >= 4 ? bytes4(data[:4]) : bytes4(0);
        return scopeAllowed[target][selector] && value <= maxCallValue[target];
    }

    /**
     * @dev See {IAgent-setExecutor}.
     */
    function setExecutor(address account, bool enabled) public virtual onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        _executors[account] = enabled;
        emit ExecutorUpdated(account, enabled);
    }

    /**
     * @dev Allows or disallows a (target, selector) pair in the Scope.
     * Owner only (spec §6.6.8) — the Executor must never be able to widen the
     * boundary it operates in.
     */
    function setScope(address target, bytes4 selector, bool allowed) public virtual onlyOwner {
        scopeAllowed[target][selector] = allowed;
        emit ScopeUpdated(target, selector, allowed);
    }

    /**
     * @dev Sets the maximum ether value `execute` may attach to a call to
     * `target`. Owner only.
     */
    function setMaxCallValue(address target, uint256 maxValue) public virtual onlyOwner {
        maxCallValue[target] = maxValue;
        emit MaxCallValueUpdated(target, maxValue);
    }

    /**
     * @dev See {IAgent-owner}.
     */
    function owner() public view virtual override(IAgent, Ownable) returns (address) {
        return Ownable.owner();
    }

    /**
     * @dev See {IAgent-isExecutor}.
     */
    function isExecutor(address account) public view virtual returns (bool) {
        return _executors[account];
    }

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165) returns (bool) {
        return interfaceId == type(IAgent).interfaceId || interfaceId == type(IERC20).interfaceId
            || super.supportsInterface(interfaceId);
    }

    // ==== Extension hooks ====

    /**
     * @dev Hook that is called at the start of {requestMint}, before the
     * deposit is pulled. `requester` is the caller and `assets` the deposit
     * size. Revert to reject the request.
     *
     * Use it for eligibility policy: KYC or allowlist checks, minimum or
     * maximum deposit sizes, per-address caps, subscription windows.
     *
     * The default implementation accepts every request.
     */
    function _beforeRequestMint(address requester, uint256 assets) internal virtual {}

    /**
     * @dev Hook that is called at the start of {requestRedeem}, before the
     * shares are escrowed. `requester` is the caller and `shares` the amount
     * to escrow. Revert to reject the request.
     *
     * Use it for exit policy: lockup periods, redemption windows, minimum
     * holding sizes.
     *
     * The default implementation accepts every request.
     */
    function _beforeRequestRedeem(address requester, uint256 shares) internal virtual {}

    /**
     * @dev Hook that computes a mint settlement (spec §6.3.4). Called by
     * {settleMint} with the requester's full pending balance; returns how much
     * of it to settle (`assets <= pendingAssets`) and the `shares` to credit
     * for it. {settleMint} reverts if `assets` is zero or exceeds the pending
     * balance, refunds the settled `assets` if `shares` rounds to zero, and
     * leaves anything unsettled pending.
     *
     * Override it to charge entry fees, apply differentiated pricing or
     * quotas, or settle partially. The default implementation settles the
     * entire pending balance at the current {exchangeRate}, fee-free:
     * `shares = assets * 1e18 / exchangeRate()`.
     */
    function _settleMintAmounts(address, /* requester */ uint256 pendingAssets)
        internal
        virtual
        returns (uint256 assets, uint256 shares)
    {
        assets = pendingAssets;
        shares = (assets * 1e18) / _exchangeRate;
    }

    /**
     * @dev Hook that computes a redeem settlement (spec §6.4.4). Called by
     * {settleRedeem} with the requester's full pending (escrowed) share
     * balance; returns how many of them to settle (`shares <= pendingShares`)
     * and the Accept-Token `tokens` to pay for them. {settleRedeem} reverts if
     * `shares` is zero or exceeds the pending balance, or if the Agent's free
     * balance cannot cover `tokens`; it returns the escrowed shares to the
     * requester if `tokens` rounds to zero.
     *
     * Override it to charge exit fees, apply withdrawal tiers, or settle
     * partially. The default implementation settles the entire pending balance
     * at the current {exchangeRate}, fee-free:
     * `tokens = shares * exchangeRate() / 1e18`.
     */
    function _settleRedeemAmounts(address, /* requester */ uint256 pendingShares)
        internal
        virtual
        returns (uint256 shares, uint256 tokens)
    {
        shares = pendingShares;
        tokens = (shares * _exchangeRate) / 1e18;
    }

    /**
     * @dev Hook that is called by {execute} after the Scope check passes and
     * before the call is dispatched. Revert to veto the call.
     *
     * Use it to layer policy beyond the Owner-set Scope (spec §6.6.5): rate
     * limits, circuit breakers, per-asset caps, external policy contracts.
     * Note that such policy is not part of the FAT standard and integrators
     * must not rely on it as a protocol guarantee.
     *
     * The default implementation is a no-op.
     */
    function _beforeExecute(address target, uint256 value, bytes calldata data) internal virtual {}

    /**
     * @dev Hook that is called by {execute} after a successful dispatch, with
     * the call's return data, before {IAgent-Executed} is emitted. A revert
     * here undoes the entire call.
     *
     * Use it for position accounting, invariant checks on the Agent's
     * post-call state, or notification of downstream contracts.
     *
     * The default implementation is a no-op.
     */
    function _afterExecute(address target, uint256 value, bytes calldata data, bytes memory returnData)
        internal
        virtual
    {}
}
