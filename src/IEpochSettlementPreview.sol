// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/// @title Epoch settlement preview capability
/// @notice Lets operators obtain the exact settlement outputs from the vault implementation.
/// @dev Callers should source the supplied snapshots and epoch totals from the same chain state used
/// to prepare settlement. Implementations advertise this single-function interface through ERC-165.
interface IEpochSettlementPreview {
    function previewSettlement(
        uint256 navSnapshot,
        uint256 totalSupplySnapshot,
        uint256 totalDepositAssets,
        uint256 totalRedeemShares
    ) external view returns (uint256 depositShares, uint256 redeemAssets);
}
