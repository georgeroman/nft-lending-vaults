// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface INFTXVault {
    function mint(uint256[] calldata tokenIds, uint256[] calldata amounts)
        external;
}
