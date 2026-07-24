// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

contract MockTarget {
    uint256 public lastEtherReceived;
    uint256 public lastX;

    error Boom(uint256 code);

    function echo(uint256 x) external payable returns (uint256) {
        lastX = x;
        lastEtherReceived = msg.value;
        return x;
    }

    function fail(string calldata message) external pure {
        revert(message);
    }

    function failCustom() external pure {
        revert Boom(42);
    }

    receive() external payable {
        lastEtherReceived = msg.value;
    }
}
