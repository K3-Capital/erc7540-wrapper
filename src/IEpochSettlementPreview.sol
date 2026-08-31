// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/// @title Epoch settlement preview capability
/// @notice Lets operators obtain the exact settlement outputs from the vault implementation.
/// @dev Callers should source the supplied snapshots and epoch totals from the same chain state used
/// to prepare settlement. The returned values describe conversion output, not whether the supplied NAV
/// is economically safe. A nonzero totalDepositAssets value may return zero depositShares under floor
/// rounding; callers should surface that result and apply their deployment's materiality and dust policy.
/// Implementations advertise this single-function interface through ERC-165.
interface IEpochSettlementPreview {
    function previewSettlement(
        uint256 navSnapshot,
        uint256 totalSupplySnapshot,
        uint256 totalDepositAssets,
        uint256 totalRedeemShares
    ) external view returns (uint256 depositShares, uint256 redeemAssets);
}
