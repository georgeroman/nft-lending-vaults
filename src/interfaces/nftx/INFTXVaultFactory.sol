// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface INFTXVaultFactory {
    function vaultsForAsset(address asset)
        external
        view
        returns (address[] memory);
}
