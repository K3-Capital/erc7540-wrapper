// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {SmartAccountWrapper} from "../../src/SmartAccountWrapper.sol";
import {CREATE3} from "solady/utils/CREATE3.sol";

library DeployHelper {
    struct DeployParams {
        address owner;
        address smartAccount;
        address underlyingToken;
        string name;
        string symbol;
        bytes32 salt;
    }

    struct DeployResult {
        address implementation;
        address beacon;
        address wrapper;
    }

    /// @notice Deploy implementation, beacon, and wrapper in one transaction using CREATE3
    /// @dev Deterministic addresses across all EVMs with the same salt
    function deployAll(DeployParams memory params) internal returns (DeployResult memory result) {
        // Deploy implementation via CREATE3
        bytes32 implSalt = keccak256(abi.encodePacked(params.salt, "implementation"));
        result.implementation = CREATE3.deployDeterministic(type(SmartAccountWrapper).creationCode, implSalt);

        // Deploy beacon via CREATE3
        bytes32 beaconSalt = keccak256(abi.encodePacked(params.salt, "beacon"));
        result.beacon = CREATE3.deployDeterministic(
            abi.encodePacked(type(UpgradeableBeacon).creationCode, abi.encode(result.implementation, params.owner)),
            beaconSalt
        );

        // Deploy wrapper proxy via CREATE3
        bytes32 wrapperSalt = keccak256(abi.encodePacked(params.salt, "wrapper"));
        bytes memory initData = abi.encodeWithSelector(
            SmartAccountWrapper.initialize.selector,
            params.owner,
            params.smartAccount,
            params.underlyingToken,
            params.name,
            params.symbol
        );
        result.wrapper = CREATE3.deployDeterministic(
            abi.encodePacked(type(BeaconProxy).creationCode, abi.encode(result.beacon, initData)), wrapperSalt
        );

        // Verify deployment
        _verifyDeployment(result, params);
    }

    function _verifyDeployment(DeployResult memory result, DeployParams memory params) private view {
        UpgradeableBeacon beacon = UpgradeableBeacon(result.beacon);
        require(beacon.implementation() == result.implementation, "Beacon impl mismatch");
        require(beacon.owner() == params.owner, "Beacon owner mismatch");

        SmartAccountWrapper wrapper = SmartAccountWrapper(result.wrapper);
        require(wrapper.owner() == params.owner, "Wrapper owner mismatch");
        require(wrapper.smartAccount() == params.smartAccount, "Wrapper smartAccount mismatch");
        require(wrapper.asset() == params.underlyingToken, "Wrapper asset mismatch");
    }

    // ============ Legacy functions (kept for backward compatibility) ============

    function deployBeacon(address implementation, address owner) internal returns (address) {
        UpgradeableBeacon beacon = new UpgradeableBeacon(implementation, owner);
        require(beacon.implementation() == implementation, "Beacon implementation is not the expected implementation");
        require(beacon.owner() == owner, "Beacon owner is not the expected owner");
        return address(beacon);
    }

    function deploySmartAccountWrapper(
        address beacon,
        address owner_,
        address smartAccount_,
        address underlyingToken_,
        string memory name_,
        string memory symbol_
    ) internal returns (SmartAccountWrapper) {
        BeaconProxy proxy = new BeaconProxy(
            beacon,
            abi.encodeWithSelector(
                SmartAccountWrapper.initialize.selector, owner_, smartAccount_, underlyingToken_, name_, symbol_
            )
        );
        SmartAccountWrapper wrapper = SmartAccountWrapper(address(proxy));
        require(wrapper.owner() == owner_, "SmartAccountWrapper owner is not the expected owner");
        require(
            wrapper.smartAccount() == smartAccount_, "SmartAccountWrapper smartAccount is not the expected smartAccount"
        );
        require(
            wrapper.asset() == underlyingToken_,
            "SmartAccountWrapper underlyingToken is not the expected underlyingToken"
        );
        require(
            keccak256(abi.encodePacked(wrapper.name())) == keccak256(abi.encodePacked(name_)),
            "SmartAccountWrapper name is not the expected name"
        );
        require(
            keccak256(abi.encodePacked(wrapper.symbol())) == keccak256(abi.encodePacked(symbol_)),
            "SmartAccountWrapper symbol is not the expected symbol"
        );
        return wrapper;
    }
}
