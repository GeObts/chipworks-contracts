// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Collection-to-vault lookup, implemented by {ClutchVaultAdapter}.
/// @dev The router depends on this rather than on a hardcoded vault address, so the entire
///      Clutch seam stays in the adapter. See ASSUMPTIONS.md A-3.
interface IClutchVaultRegistry {
    function vaultOf(address collection) external view returns (address);
}
