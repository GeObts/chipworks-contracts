// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IPot {
    function quoteToken() external view returns (address);
    function available() external view returns (uint256);
    function pullBudget(uint256 amount) external returns (uint256);
    function noteReturned(uint256 amount) external;
}
