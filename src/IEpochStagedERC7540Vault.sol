// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title Epoch-staged ERC-7540 vault interface
/// @notice Fully async deposit and redeem interface for the Safe-backed wrapper.
interface IEpochStagedERC7540Vault {
    event DepositRequest(
        address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 assets
    );
    event RedeemRequest(
        address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 shares
    );
    event OperatorSet(address indexed controller, address indexed operator, bool approved);

    event EpochClosed(
        uint40 indexed epochId, uint40 indexed nextEpochId, uint256 totalDepositAssets, uint256 totalRedeemShares
    );

    event EpochSettled(
        uint40 indexed epochId,
        uint256 navSnapshot,
        uint256 totalSupplySnapshot,
        uint256 totalDepositAssets,
        uint256 totalRedeemShares,
        uint256 depositSharesMinted,
        uint256 redeemAssetsReserved
    );

    function currentEpochId() external view returns (uint40);
    function frozenEpochId() external view returns (uint40);
    function staging() external view returns (address);

    function requestDeposit(uint256 assets, address controller, address owner) external returns (uint256 requestId);
    function pendingDepositRequest(uint256 requestId, address controller) external view returns (uint256 pendingAssets);
    function claimableDepositRequest(uint256 requestId, address controller)
        external
        view
        returns (uint256 claimableAssets);

    function requestRedeem(uint256 shares, address controller, address owner) external returns (uint256 requestId);
    function pendingRedeemRequest(uint256 requestId, address controller) external view returns (uint256 pendingShares);
    function claimableRedeemRequest(uint256 requestId, address controller)
        external
        view
        returns (uint256 claimableShares);

    function setOperator(address operator, bool approved) external returns (bool);
    function isOperator(address controller, address operator) external view returns (bool status);

    function closeEpoch() external returns (uint40 closedEpochId, uint40 nextEpochId);
    function settleEpoch(uint40 epochId, uint256 navSnapshot) external;
}
