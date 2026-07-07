// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {DeployHelper} from "./utils/DeployHelper.sol";
import {SmartAccountWrapper} from "../src/SmartAccountWrapper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Deploy implementation + beacon + wrapper in one tx using CREATE3
contract DeployAll is Script {
    function run() public {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        bytes32 salt = vm.envBytes32("DEPLOY_SALT");

        DeployHelper.DeployParams memory params = DeployHelper.DeployParams({
            owner: vm.envAddress("OWNER"),
            smartAccount: vm.envAddress("SMART_ACCOUNT"),
            underlyingToken: vm.envAddress("UNDERLYING_TOKEN"),
            name: vm.envString("VAULT_NAME"),
            symbol: vm.envString("VAULT_SYMBOL"),
            salt: salt
        });

        console.log("Deployer:", deployer);

        vm.startBroadcast(deployer);
        DeployHelper.DeployResult memory result = DeployHelper.deployAll(params);
        vm.stopBroadcast();

        console.log("Deployed addresses:");
        console.log("  Implementation:", result.implementation);
        console.log("  Beacon:", result.beacon);
        console.log("  Wrapper:", result.wrapper);
    }
}

contract RequestDeposit is Script {
    function run() public {
        address requestOwner = vm.envAddress("REQUEST_OWNER");
        address controller = vm.envOr("REQUEST_CONTROLLER", requestOwner);
        address underlying = vm.envAddress("UNDERLYING_TOKEN");
        address wrapper = vm.envAddress("WRAPPER_ADDRESS");
        uint256 assets = vm.envUint("REQUEST_ASSETS");

        vm.startBroadcast(requestOwner);
        IERC20(underlying).approve(wrapper, assets);
        SmartAccountWrapper(wrapper).requestDeposit(assets, controller, requestOwner);
        vm.stopBroadcast();
    }
}

contract RequestRedeem is Script {
    function run() public {
        address requestOwner = vm.envAddress("REQUEST_OWNER");
        address controller = vm.envOr("REQUEST_CONTROLLER", requestOwner);
        address wrapper = vm.envAddress("WRAPPER_ADDRESS");
        uint256 shares = vm.envUint("REQUEST_SHARES");

        vm.startBroadcast(requestOwner);
        SmartAccountWrapper(wrapper).requestRedeem(shares, controller, requestOwner);
        vm.stopBroadcast();
    }
}
