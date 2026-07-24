// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FATAgentUpgradeableV1} from "../src/FATAgentUpgradeableV1.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

/// @dev Minimal next version: appends behavior without touching V1 storage.
contract FATAgentV2Mock is FATAgentUpgradeableV1 {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract UpgradeTest is Test {
    FATAgentUpgradeableV1 internal agent;
    MockERC20 internal token;

    address internal owner = makeAddr("owner");
    address internal executor = makeAddr("executor");
    address internal alice = makeAddr("alice");

    bytes32 internal constant RHASH = keccak256("reasoning-record");
    string internal constant RURI = "ipfs://bafyreasoning/record.json";

    function setUp() public {
        vm.warp(1_700_000_000);
        token = new MockERC20();
        FATAgentUpgradeableV1 impl = new FATAgentUpgradeableV1();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                FATAgentUpgradeableV1.initialize,
                (address(token), "FAT Agent Shares", "sAGT", owner, 1e18, "ipfs://agent-metadata.json")
            )
        );
        agent = FATAgentUpgradeableV1(payable(address(proxy)));

        vm.prank(owner);
        agent.setExecutor(executor, true);
        token.mint(alice, 1_000e18);
        vm.prank(alice);
        token.approve(address(agent), type(uint256).max);
    }

    function test_erc7201SlotDerivation() public pure {
        bytes32 expected =
            keccak256(abi.encode(uint256(keccak256("fat.storage.Agent")) - 1)) & ~bytes32(uint256(0xff));
        assertEq(expected, 0xcd540dd93dcc445f94bb58ddd0cc5173ee76b24f9adcd1a34fd8332bedfbaa00);
    }

    function test_initializeCannotRunTwice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        agent.initialize(address(token), "x", "x", owner, 1e18, "");
    }

    function test_implementationIsBricked() public {
        FATAgentUpgradeableV1 impl = new FATAgentUpgradeableV1();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(address(token), "x", "x", owner, 1e18, "");
    }

    function test_upgradeIsOwnerOnly() public {
        FATAgentV2Mock v2 = new FATAgentV2Mock();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, executor));
        vm.prank(executor); // the Executor must not be able to upgrade its own cage
        agent.upgradeToAndCall(address(v2), "");

        vm.prank(owner);
        agent.upgradeToAndCall(address(v2), "");
        assertEq(FATAgentV2Mock(payable(address(agent))).version(), 2);
    }

    function test_upgradePreservesState() public {
        // build up representative state on V1
        vm.prank(alice);
        agent.requestMint(100e18);
        vm.prank(executor);
        agent.settleMint(alice, RHASH, RURI);
        agent.mint(alice);
        vm.prank(alice);
        agent.requestRedeem(30e18);
        vm.prank(executor);
        agent.updateExchangeRate(15e17, RHASH, RURI);

        // upgrade
        FATAgentV2Mock v2 = new FATAgentV2Mock();
        vm.prank(owner);
        agent.upgradeToAndCall(address(v2), "");

        // everything survives the implementation swap
        assertEq(agent.acceptToken(), address(token));
        assertEq(agent.balanceOf(alice), 70e18);
        assertEq(agent.totalSupply(), 100e18); // 70 held + 30 escrowed in the Agent
        assertEq(agent.exchangeRate(), 15e17);
        assertEq(agent.currentEpoch(), 2);
        assertEq(agent.owner(), owner);
        assertTrue(agent.isExecutor(executor));
        assertEq(agent.agentURI(), "ipfs://agent-metadata.json");
        (uint256 pendingShares,) = agent.queryRedeemStatus(alice);
        assertEq(pendingShares, 30e18);

        // and the Agent still operates: settle + claim the escrowed redemption
        vm.prank(executor);
        agent.settleRedeem(alice, RHASH, RURI);
        uint256 balBefore = token.balanceOf(alice);
        agent.redeem(alice);
        assertEq(token.balanceOf(alice), balBefore + 45e18); // 30 shares * 1.5
    }
}
