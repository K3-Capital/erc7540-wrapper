// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {DeployHelper} from "./DeployHelper.sol";

/// @notice One-shot coordinator that completes the CREATE3 deployment sequence in its constructor.
/// @dev Deploying this contract is a single transaction, so no CREATE3 proxy can be called between
///      its CREATE2 deployment and its nonce-one child deployment.
contract AtomicDeployment {
    address public immutable implementation;
    address public immutable beacon;
    address public immutable wrapper;

    constructor(DeployHelper.DeployParams memory params) {
        DeployHelper.DeployResult memory result = DeployHelper.deployAll(params);
        implementation = result.implementation;
        beacon = result.beacon;
        wrapper = result.wrapper;
    }
}
