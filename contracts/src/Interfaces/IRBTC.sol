// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

interface IRBTCToken {
    function getExchangeRate() external view returns (uint256);
}
