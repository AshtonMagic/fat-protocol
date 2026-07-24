// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAgent} from "../src/IAgent.sol";
import {FATAgent} from "../src/FATAgent.sol";
import {FATAgentUpgradeableV1} from "../src/FATAgentUpgradeableV1.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockTarget} from "./mocks/MockTarget.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @dev Superset of IAgent covering the reference implementations' implementer-defined
///      surface (identical on both versions) plus the ERC-20 Share functions.
interface IRefAgent is IAgent {
    function updateExchangeRate(uint256 newRate, bytes32 reasoningHash, string calldata reasoningURI) external;
    function setScope(address target, bytes4 selector, bool allowed) external;
    function setMaxCallValue(address target, uint256 maxValue) external;
    function currentEpoch() external view returns (uint64);
    function totalPendingAssets() external view returns (uint256);
    function totalClaimableTokens() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

/// @dev Behavior suite run against BOTH reference implementations. Concrete
///      subclasses at the bottom of this file pick the deployment shape.
abstract contract AgentBehaviorTest is Test {
    IRefAgent internal agent;
    MockERC20 internal token;
    MockTarget internal target;

    address internal owner = makeAddr("owner");
    address internal executor = makeAddr("executor");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal stranger = makeAddr("stranger");

    bytes32 internal constant RHASH = keccak256("reasoning-record");
    string internal constant RURI = "ipfs://bafyreasoning/record.json";
    uint256 internal constant ONE = 1e18;

    function _deployAgent(address acceptToken_, address owner_, uint256 initialRate_)
        internal
        virtual
        returns (IRefAgent);

    function setUp() public virtual {
        vm.warp(1_700_000_000);
        token = new MockERC20();
        target = new MockTarget();
        agent = _deployAgent(address(token), owner, ONE);

        vm.prank(owner);
        agent.setExecutor(executor, true);

        token.mint(alice, 1_000e18);
        token.mint(bob, 1_000e18);
        vm.prank(alice);
        token.approve(address(agent), type(uint256).max);
        vm.prank(bob);
        token.approve(address(agent), type(uint256).max);
    }

    // ---------- helpers ----------

    function _depositSettleClaim(address user, uint256 assets) internal returns (uint256 shares) {
        vm.prank(user);
        agent.requestMint(assets);
        vm.prank(executor);
        agent.settleMint(user, RHASH, RURI);
        shares = agent.mint(user);
    }

    // ---------- metadata / conformance ----------

    function test_metadata() public view {
        assertEq(agent.acceptToken(), address(token));
        assertEq(agent.shareToken(), address(agent));
        assertEq(agent.exchangeRate(), ONE);
        assertEq(agent.owner(), owner);
        assertEq(agent.agentURI(), "ipfs://agent-metadata.json");
        assertEq(agent.currentEpoch(), 1);
        assertTrue(agent.isExecutor(executor));
        assertFalse(agent.isExecutor(stranger));
    }

    function test_erc165() public view {
        assertTrue(agent.supportsInterface(type(IAgent).interfaceId));
        assertTrue(agent.supportsInterface(type(IERC165).interfaceId));
        assertFalse(agent.supportsInterface(0xdeadbeef));
    }

    // ---------- mint lifecycle (§6.3) ----------

    function test_requestMint_pullsTokensAndTracksPending() public {
        vm.expectEmit(true, true, true, true, address(agent));
        emit IAgent.MintRequested(alice, 100e18, 1, block.timestamp);
        vm.prank(alice);
        agent.requestMint(100e18);

        (uint256 pendingAssets, uint256 claimableShares) = agent.queryMintStatus(alice);
        assertEq(pendingAssets, 100e18);
        assertEq(claimableShares, 0);
        assertEq(token.balanceOf(address(agent)), 100e18);
        assertEq(agent.totalPendingAssets(), 100e18);
    }

    function test_requestMint_zeroReverts() public {
        vm.expectRevert(FATAgent.ZeroAmount.selector);
        vm.prank(alice);
        agent.requestMint(0);
    }

    function test_settleMint_movesPendingToClaimable() public {
        vm.prank(alice);
        agent.requestMint(100e18);

        vm.expectEmit(true, true, true, true, address(agent));
        emit IAgent.Settled(alice, 0, 100e18, RHASH, RURI);
        vm.prank(executor);
        agent.settleMint(alice, RHASH, RURI);

        (uint256 pendingAssets, uint256 claimableShares) = agent.queryMintStatus(alice);
        assertEq(pendingAssets, 0);
        assertEq(claimableShares, 100e18);
        assertEq(agent.totalPendingAssets(), 0);
    }

    function test_settleMint_onlyExecutor() public {
        vm.prank(alice);
        agent.requestMint(100e18);

        vm.expectRevert(abi.encodeWithSelector(FATAgent.NotExecutor.selector, owner));
        vm.prank(owner); // Owner is not automatically an Executor
        agent.settleMint(alice, RHASH, RURI);
    }

    function test_settleMint_requiresReasoningEnvelope() public {
        vm.prank(alice);
        agent.requestMint(100e18);

        vm.expectRevert(FATAgent.InvalidReasoning.selector);
        vm.prank(executor);
        agent.settleMint(alice, bytes32(0), RURI);

        vm.expectRevert(FATAgent.InvalidReasoning.selector);
        vm.prank(executor);
        agent.settleMint(alice, RHASH, "");
    }

    function test_settleMint_nothingPendingReverts() public {
        vm.expectRevert(abi.encodeWithSelector(FATAgent.NothingPending.selector, alice));
        vm.prank(executor);
        agent.settleMint(alice, RHASH, RURI);
    }

    function test_mint_claimIsPermissionlessAndPaysOwedParty() public {
        vm.prank(alice);
        agent.requestMint(100e18);
        vm.prank(executor);
        agent.settleMint(alice, RHASH, RURI);

        vm.expectEmit(true, true, true, true, address(agent));
        emit IAgent.SharesMinted(alice, 100e18, 100e18, 1, ONE, block.timestamp);
        vm.prank(stranger); // permissionless crank
        uint256 shares = agent.mint(alice);

        assertEq(shares, 100e18);
        assertEq(agent.balanceOf(alice), 100e18);
        assertEq(agent.balanceOf(stranger), 0);

        // second claim: nothing left
        assertEq(agent.mint(alice), 0);
    }

    function test_settleMint_roundsToZeroRefundsDeposit() public {
        vm.prank(executor);
        agent.updateExchangeRate(10 * ONE, RHASH, RURI); // 1 share now costs 10 tokens

        vm.prank(alice);
        agent.requestMint(5); // 5 wei of assets -> 0 shares at this rate

        uint256 balBefore = token.balanceOf(alice);
        vm.expectEmit(true, true, true, true, address(agent));
        emit IAgent.Settled(alice, 0, 0, RHASH, RURI);
        vm.expectEmit(true, true, true, true, address(agent));
        emit FATAgent.MintRefunded(alice, 5, RHASH, RURI);
        vm.prank(executor);
        agent.settleMint(alice, RHASH, RURI);

        (uint256 pendingAssets, uint256 claimableShares) = agent.queryMintStatus(alice);
        assertEq(pendingAssets, 0);
        assertEq(claimableShares, 0);
        assertEq(agent.totalPendingAssets(), 0);
        assertEq(token.balanceOf(alice), balBefore + 5); // deposit returned, not stranded
    }

    function test_mint_aggregatesMultipleRequests() public {
        vm.startPrank(alice);
        agent.requestMint(60e18);
        agent.requestMint(40e18);
        vm.stopPrank();

        (uint256 pendingAssets,) = agent.queryMintStatus(alice);
        assertEq(pendingAssets, 100e18);

        vm.prank(executor);
        agent.settleMint(alice, RHASH, RURI);
        assertEq(agent.mint(alice), 100e18);
    }

    // ---------- exchange rate / epoch ----------

    function test_updateExchangeRate_isReasonedAgentAction() public {
        vm.expectEmit(true, true, true, true, address(agent));
        emit IAgent.Reasoned(executor, IRefAgent.updateExchangeRate.selector, RHASH, RURI);
        vm.expectEmit(true, true, true, true, address(agent));
        emit IAgent.ExchangeRateUpdated(2 * ONE);
        vm.prank(executor);
        agent.updateExchangeRate(2 * ONE, RHASH, RURI);

        assertEq(agent.exchangeRate(), 2 * ONE);
        assertEq(agent.currentEpoch(), 2);

        vm.expectRevert(abi.encodeWithSelector(FATAgent.NotExecutor.selector, owner));
        vm.prank(owner);
        agent.updateExchangeRate(3 * ONE, RHASH, RURI);
    }

    function test_settlementUsesCurrentRate() public {
        vm.prank(alice);
        agent.requestMint(100e18);
        vm.prank(executor);
        agent.updateExchangeRate(2 * ONE, RHASH, RURI); // 1 share now costs 2 mUSD
        vm.prank(executor);
        agent.settleMint(alice, RHASH, RURI);

        (, uint256 claimableShares) = agent.queryMintStatus(alice);
        assertEq(claimableShares, 50e18);

        // claim reports the settlement epoch (2) and effective price (2e18)
        vm.expectEmit(true, true, true, true, address(agent));
        emit IAgent.SharesMinted(alice, 100e18, 50e18, 2, 2 * ONE, block.timestamp);
        agent.mint(alice);
    }

    // ---------- redeem lifecycle (§6.4) ----------

    function test_redeem_fullLifecycle() public {
        _depositSettleClaim(alice, 100e18);

        vm.expectEmit(true, true, true, true, address(agent));
        emit IAgent.RedeemRequested(alice, 40e18, 1, block.timestamp);
        vm.prank(alice);
        agent.requestRedeem(40e18);

        assertEq(agent.balanceOf(alice), 60e18);
        assertEq(agent.balanceOf(address(agent)), 40e18); // escrowed
        (uint256 pendingShares, uint256 claimableTokens) = agent.queryRedeemStatus(alice);
        assertEq(pendingShares, 40e18);
        assertEq(claimableTokens, 0);

        vm.expectEmit(true, true, true, true, address(agent));
        emit IAgent.Settled(alice, 1, 40e18, RHASH, RURI);
        vm.prank(executor);
        agent.settleRedeem(alice, RHASH, RURI);

        assertEq(agent.balanceOf(address(agent)), 0); // escrowed shares burned at settlement
        assertEq(agent.totalSupply(), 60e18);
        assertEq(agent.totalClaimableTokens(), 40e18);

        uint256 balBefore = token.balanceOf(alice);
        vm.expectEmit(true, true, true, true, address(agent));
        emit IAgent.SharesRedeemed(alice, 40e18, 40e18, 1, ONE, block.timestamp);
        vm.prank(stranger); // permissionless crank
        uint256 tokens = agent.redeem(alice);

        assertEq(tokens, 40e18);
        assertEq(token.balanceOf(alice), balBefore + 40e18);
        assertEq(agent.totalClaimableTokens(), 0);
        assertEq(agent.redeem(alice), 0); // nothing left
    }

    function test_settleRedeem_insufficientLiquidityReverts() public {
        _depositSettleClaim(alice, 100e18);

        vm.prank(executor);
        agent.updateExchangeRate(2 * ONE, RHASH, RURI); // NAV doubled, but no extra tokens held

        vm.prank(alice);
        agent.requestRedeem(100e18); // now worth 200e18

        vm.expectRevert(abi.encodeWithSelector(FATAgent.InsufficientLiquidity.selector, 200e18, 100e18));
        vm.prank(executor);
        agent.settleRedeem(alice, RHASH, RURI);
    }

    function test_settleRedeem_pendingDepositsAreNotSpendable() public {
        _depositSettleClaim(alice, 100e18);

        vm.prank(executor);
        agent.updateExchangeRate(12e17, RHASH, RURI); // 1.2

        vm.prank(bob);
        agent.requestMint(60e18); // unsettled: sits in the Agent but is NOT free liquidity

        vm.prank(alice);
        agent.requestRedeem(100e18); // worth 120e18 > 160e18 - 60e18 = 100e18 free

        vm.expectRevert(abi.encodeWithSelector(FATAgent.InsufficientLiquidity.selector, 120e18, 100e18));
        vm.prank(executor);
        agent.settleRedeem(alice, RHASH, RURI);
    }

    function test_settleRedeem_roundsToZeroReturnsShares() public {
        _depositSettleClaim(alice, 100e18);

        vm.prank(executor);
        agent.updateExchangeRate(1, RHASH, RURI); // NAV collapse: 1 wei per 1e18 share wei

        vm.prank(alice);
        agent.requestRedeem(1e6); // 1e6 * 1 / 1e18 -> 0 tokens

        vm.expectEmit(true, true, true, true, address(agent));
        emit IAgent.Settled(alice, 1, 0, RHASH, RURI);
        vm.expectEmit(true, true, true, true, address(agent));
        emit FATAgent.RedeemRefunded(alice, 1e6, RHASH, RURI);
        vm.prank(executor);
        agent.settleRedeem(alice, RHASH, RURI);

        (uint256 pendingShares, uint256 claimableTokens) = agent.queryRedeemStatus(alice);
        assertEq(pendingShares, 0);
        assertEq(claimableTokens, 0);
        assertEq(agent.balanceOf(alice), 100e18); // escrow returned, nothing burned
        assertEq(agent.totalSupply(), 100e18);
    }

    // ---------- executor dispatch (§6.6) ----------

    function test_execute_defaultDeny() public {
        bytes memory data = abi.encodeCall(MockTarget.echo, (7));
        vm.expectRevert(
            abi.encodeWithSelector(FATAgent.OutOfScope.selector, address(target), 0, MockTarget.echo.selector)
        );
        vm.prank(executor);
        agent.execute(address(target), 0, data, RHASH, RURI);
    }

    function test_execute_onlyExecutor() public {
        vm.expectRevert(abi.encodeWithSelector(FATAgent.NotExecutor.selector, stranger));
        vm.prank(stranger);
        agent.execute(address(target), 0, "", RHASH, RURI);
    }

    function test_execute_requiresReasoningEnvelope() public {
        vm.expectRevert(FATAgent.InvalidReasoning.selector);
        vm.prank(executor);
        agent.execute(address(target), 0, "", bytes32(0), RURI);
    }

    function test_execute_inScopeCallSucceedsAndEmits() public {
        vm.prank(owner);
        agent.setScope(address(target), MockTarget.echo.selector, true);

        bytes memory data = abi.encodeCall(MockTarget.echo, (7));
        vm.expectEmit(true, true, true, true, address(agent));
        emit IAgent.Executed(executor, address(target), 0, MockTarget.echo.selector, abi.encode(7), RHASH, RURI);
        vm.prank(executor);
        bytes memory ret = agent.execute(address(target), 0, data, RHASH, RURI);

        assertEq(abi.decode(ret, (uint256)), 7);
        assertEq(target.lastX(), 7);
    }

    function test_execute_valueCapEnforced() public {
        vm.deal(address(agent), 2 ether);
        vm.startPrank(owner);
        agent.setScope(address(target), bytes4(0), true); // plain value transfer
        agent.setMaxCallValue(address(target), 1 ether);
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(FATAgent.OutOfScope.selector, address(target), 1.5 ether, bytes4(0))
        );
        vm.prank(executor);
        agent.execute(address(target), 1.5 ether, "", RHASH, RURI);

        vm.prank(executor);
        agent.execute(address(target), 1 ether, "", RHASH, RURI);
        assertEq(target.lastEtherReceived(), 1 ether);
        assertEq(address(agent).balance, 1 ether);
    }

    function test_execute_bubblesRevertData() public {
        vm.startPrank(owner);
        agent.setScope(address(target), MockTarget.fail.selector, true);
        agent.setScope(address(target), MockTarget.failCustom.selector, true);
        vm.stopPrank();

        vm.expectRevert(bytes("nope"));
        vm.prank(executor);
        agent.execute(address(target), 0, abi.encodeCall(MockTarget.fail, ("nope")), RHASH, RURI);

        vm.expectRevert(abi.encodeWithSelector(MockTarget.Boom.selector, 42));
        vm.prank(executor);
        agent.execute(address(target), 0, abi.encodeCall(MockTarget.failCustom, ()), RHASH, RURI);
    }

    function test_execute_cannotSpendPendingDeposits() public {
        vm.prank(bob);
        agent.requestMint(60e18); // unsettled: reserved, not working capital

        vm.prank(owner);
        agent.setScope(address(token), token.transfer.selector, true);

        bytes memory data = abi.encodeCall(token.transfer, (stranger, 10e18));
        vm.expectRevert(abi.encodeWithSelector(FATAgent.ReservesBreached.selector, 60e18, 50e18));
        vm.prank(executor);
        agent.execute(address(token), 0, data, RHASH, RURI);
    }

    function test_execute_cannotSpendReservedPayouts() public {
        _depositSettleClaim(alice, 100e18);
        vm.prank(alice);
        agent.requestRedeem(100e18);
        vm.prank(executor);
        agent.settleRedeem(alice, RHASH, RURI); // 100e18 now reserved for alice's claim

        vm.prank(owner);
        agent.setScope(address(token), token.transfer.selector, true);

        bytes memory data = abi.encodeCall(token.transfer, (stranger, 1));
        vm.expectRevert(abi.encodeWithSelector(FATAgent.ReservesBreached.selector, 100e18, 100e18 - 1));
        vm.prank(executor);
        agent.execute(address(token), 0, data, RHASH, RURI);
    }

    function test_execute_canSpendFreeCapital() public {
        _depositSettleClaim(alice, 100e18); // settled: free working capital
        vm.prank(bob);
        agent.requestMint(60e18); // reserved

        vm.prank(owner);
        agent.setScope(address(token), token.transfer.selector, true);

        bytes memory data = abi.encodeCall(token.transfer, (stranger, 100e18));
        vm.prank(executor);
        agent.execute(address(token), 0, data, RHASH, RURI); // exactly the free capital

        assertEq(token.balanceOf(stranger), 100e18);
        assertEq(token.balanceOf(address(agent)), 60e18); // reserves intact
    }

    function test_scope_isOwnerOnly() public {
        // §6.6.8: the Executor must never be able to widen its own Scope.
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, executor));
        vm.prank(executor);
        agent.setScope(address(target), MockTarget.echo.selector, true);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, executor));
        vm.prank(executor);
        agent.setMaxCallValue(address(target), 1 ether);
    }

    function test_isInScope_view() public {
        assertFalse(agent.isInScope(address(target), 0, abi.encodeCall(MockTarget.echo, (1))));
        vm.prank(owner);
        agent.setScope(address(target), MockTarget.echo.selector, true);
        assertTrue(agent.isInScope(address(target), 0, abi.encodeCall(MockTarget.echo, (1))));
        assertFalse(agent.isInScope(address(target), 1, abi.encodeCall(MockTarget.echo, (1)))); // value > cap 0
        assertFalse(agent.isInScope(address(target), 0, hex"01")); // short calldata -> selector 0x0, not allowed
    }

    // ---------- admin ----------

    function test_setAgentURI_ownerOnly() public {
        vm.expectEmit(true, true, true, true, address(agent));
        emit IAgent.AgentURIUpdated("ipfs://v2.json");
        vm.prank(owner);
        agent.setAgentURI("ipfs://v2.json");
        assertEq(agent.agentURI(), "ipfs://v2.json");

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        agent.setAgentURI("ipfs://evil.json");
    }

    function test_setExecutor_ownerOnlyAndRevocable() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        agent.setExecutor(stranger, true);

        vm.expectEmit(true, true, true, true, address(agent));
        emit IAgent.ExecutorUpdated(executor, false);
        vm.prank(owner);
        agent.setExecutor(executor, false);

        vm.expectRevert(abi.encodeWithSelector(FATAgent.NotExecutor.selector, executor));
        vm.prank(executor);
        agent.settleMint(alice, RHASH, RURI);
    }
}

// ---------- Concrete suites ----------

contract FATAgentBehaviorTest is AgentBehaviorTest {
    function _deployAgent(address acceptToken_, address owner_, uint256 initialRate_)
        internal
        override
        returns (IRefAgent)
    {
        return IRefAgent(
            payable(
                address(
                    new FATAgent(
                        acceptToken_, "FAT Agent Shares", "sAGT", owner_, initialRate_, "ipfs://agent-metadata.json"
                    )
                )
            )
        );
    }
}

contract FATAgentUpgradeableBehaviorTest is AgentBehaviorTest {
    function _deployAgent(address acceptToken_, address owner_, uint256 initialRate_)
        internal
        override
        returns (IRefAgent)
    {
        FATAgentUpgradeableV1 impl = new FATAgentUpgradeableV1();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                FATAgentUpgradeableV1.initialize,
                (acceptToken_, "FAT Agent Shares", "sAGT", owner_, initialRate_, "ipfs://agent-metadata.json")
            )
        );
        return IRefAgent(payable(address(proxy)));
    }
}
