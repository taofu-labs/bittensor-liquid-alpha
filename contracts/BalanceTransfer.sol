// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

address constant ISUBTENSOR_BALANCE_TRANSFER_ADDRESS = 0x0000000000000000000000000000000000000800;

interface ISubtensorBalanceTransfer {
    function transfer(bytes32 data) external payable;
}