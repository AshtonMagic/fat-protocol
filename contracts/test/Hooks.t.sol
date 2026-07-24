// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAgent} from "../src/IAgent.sol";
import {FATAgent} from "../src/FATAgent.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockTarget} from "./mocks/MockTarget.sol";

/**
 * @dev Example subclass exercising every extension hook of the reference
 * implementation: a minimum deposit, a redemption window, a 1% entry fee, a
 * per-call settlement cap (partial settlement), an execute veto, and
 * post-execute accounting.
 */
contract HookedAgent is FATAgent {
    uint256 public constant MIN_DEPOSIT = 10e18;
    uint256 public constant SETTLE_CAP = 50e18; // max assets settled per settleMint call
    uint16 public constant ENTRY_FEE_BPS = 100; // 1%

    uint256 public immutable redeemOpensAt;
    address public bannedTarget;
    uint256 public executeCount;

    error DepositTooSmall(uint256 assets, uint256 minimum);
    error RedemptionsNotOpen(uint256 opensAt);
    error TargetBanned(address target);

    constructor(
        address acceptToken_,
        address owner_,
        uint256 initialRate_,
        uint256 redeemOpensAt_,
        address bannedTarget_
    ) FATAgent(acceptToken_, "Hooked Agent Shares", "hAGT", owner_, initialRate_, "ipfs://hooked.json") {
        redeemOpensAt = redeemOpensAt_;
        bannedTarget = bannedTarget_;
    }

    function _beforeRequestMint(address, uint256 assets) internal view override {
        if (assets < MIN_DEPOSIT) revert DepositTooSmall(assets, MIN_DEPOSIT);
    }

    function _beforeRequestRedeem(address, uint256) internal view override {
        if (block.timestamp < redeemOpensAt) revert RedemptionsNotOpen(redeemOpensAt);
    }

    function _settleMintAmounts(address requester, uint256 pendingAssets)
        internal
        override
        returns (uint256 assets, uint256 shares)
    {
        (assets, shares) = super._settleMintAmounts(requester, pendingAssets);
        if (assets > SETTLE_CAP) {
            assets = SETTLE_CAP;
            shares = (assets * 1e18) / exchangeRate();
        }
        shares -= (shares * ENTRY_FEE_BPS) / 10_000;
    }

    function _beforeExecute(address target, uint256, bytes calldata) internal view override {
        if (target == bannedTarget) revert TargetBanned(target);
    }

    function _afterExecute(address, uint256, bytes calldata, bytes memory) internal override {
        executeCount += 1;
    }
}

contract HooksTest is Test {
    HookedAgent internal agent;
    MockERC20 internal token;
    MockTarget internal target;
    MockTarget internal banned;

    address internal owner = makeAddr("owner");
    address internal executor = makeAddr("executor");
    address internal alice = makeAddr("alice");

    bytes32 internal constant RHASH = keccak256("reasoning-record");
    string internal constant RURI = "ipfs://bafyreasoning/record.json";
    uint256 internal constant REDEEM_OPENS_AT = 1_700_000_000 + 30 days;

    function setUp() public {
        vm.warp(1_700_000_000);
        token = new MockERC20();
        target = new MockTarget();
        banned = new MockTarget();
        agent = new HookedAgent(address(token), owner, 1e18, REDEEM_OPENS_AT, address(banned));

        vm.prank(owner);
        agent.setExecutor(executor, true);
        token.mint(alice, 1_000e18);
        vm.prank(alice);
        token.approve(address(agent), type(uint256).max);
    }

    function test_beforeRequestMint_enforcesMinimumDeposit() public {
        vm.expectRevert(abi.encodeWithSelector(HookedAgent.DepositTooSmall.selector, 5e18, 10e18));
        vm.prank(alice);
        agent.requestMint(5e18);

        vm.prank(alice);
        agent.requestMint(10e18); // at the minimum: accepted
    }

    function test_settleMintAmounts_capAndFee() public {
        vm.prank(alice);
        agent.requestMint(100e18);

        // First settlement: capped at 50e18 assets, 1% entry fee on the shares.
        vm.prank(executor);
        agent.settleMint(alice, RHASH, RURI);
        (uint256 pendingAssets, uint256 claimableShares) = agent.queryMintStatus(alice);
        assertEq(pendingAssets, 50e18); // remainder simply stays pending
        assertEq(claimableShares, 49.5e18); // 50e18 shares - 1%

        // Second settlement drains the rest.
        vm.prank(executor);
        agent.settleMint(alice, RHASH, RURI);
        (pendingAssets, claimableShares) = agent.queryMintStatus(alice);
        assertEq(pendingAssets, 0);
        assertEq(claimableShares, 99e18);

        // The claim reports the aggregate basis: 100e18 assets for 99e18 shares.
        vm.expectEmit(true, true, true, true, address(agent));
        emit IAgent.SharesMinted(alice, 100e18, 99e18, 1, uint256(100e18) * 1e18 / 99e18, block.timestamp);
        agent.mint(alice);
        assertEq(agent.balanceOf(alice), 99e18);
    }

    function test_beforeRequestRedeem_enforcesWindow() public {
        vm.prank(alice);
        agent.requestMint(100e18);
        vm.prank(executor);
        agent.settleMint(alice, RHASH, RURI);
        agent.mint(alice);

        vm.expectRevert(abi.encodeWithSelector(HookedAgent.RedemptionsNotOpen.selector, REDEEM_OPENS_AT));
        vm.prank(alice);
        agent.requestRedeem(10e18);

        vm.warp(REDEEM_OPENS_AT);
        vm.prank(alice);
        agent.requestRedeem(10e18); // window open: accepted
    }

    function test_beforeExecute_vetoesBannedTarget() public {
        // In scope by Owner policy, still vetoed by the subclass hook.
        vm.prank(owner);
        agent.setScope(address(banned), MockTarget.echo.selector, true);

        vm.expectRevert(abi.encodeWithSelector(HookedAgent.TargetBanned.selector, address(banned)));
        vm.prank(executor);
        agent.execute(address(banned), 0, abi.encodeCall(MockTarget.echo, (1)), RHASH, RURI);
    }

    function test_afterExecute_accounting() public {
        vm.prank(owner);
        agent.setScope(address(target), MockTarget.echo.selector, true);

        vm.startPrank(executor);
        agent.execute(address(target), 0, abi.encodeCall(MockTarget.echo, (1)), RHASH, RURI);
        agent.execute(address(target), 0, abi.encodeCall(MockTarget.echo, (2)), RHASH, RURI);
        vm.stopPrank();

        assertEq(agent.executeCount(), 2);
    }
}
