// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {DeployHelper} from "./utils/DeployHelper.sol";
import {SmartAccountWrapper} from "../src/SmartAccountWrapper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Deploy implementation + beacon + wrapper in one tx using CREATE3
contract DeployAll is Script {
    function run() public {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        bytes32 salt = vm.envBytes32("DEPLOY_SALT");

        DeployHelper.DeployParams memory params = DeployHelper.DeployParams({
            owner: vm.envAddress("OWNER"),
            smartAccount: vm.envAddress("SMART_ACCOUNT"),
            underlyingToken: vm.envAddress("UNDERLYING_TOKEN"),
            name: vm.envString("VAULT_NAME"),
            symbol: vm.envString("VAULT_SYMBOL"),
            salt: salt
        });

        // Preview addresses before deployment
        DeployHelper.DeployResult memory predicted = DeployHelper.predictAddresses(salt, deployer);
        console.log("Deployer:", deployer);
        console.log("Predicted addresses:");
        console.log("  Implementation:", predicted.implementation);
        console.log("  Beacon:", predicted.beacon);
        console.log("  Wrapper:", predicted.wrapper);

        vm.startBroadcast(privateKey);
        DeployHelper.DeployResult memory result = DeployHelper.deployAll(params);
        vm.stopBroadcast();

        console.log("Deployed addresses:");
        console.log("  Implementation:", result.implementation);
        console.log("  Beacon:", result.beacon);
        console.log("  Wrapper:", result.wrapper);
    }
}

/// @notice Preview CREATE3 addresses without deploying
contract PredictAddresses is Script {
    function run() public view {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        bytes32 salt = vm.envBytes32("DEPLOY_SALT");

        DeployHelper.DeployResult memory predicted = DeployHelper.predictAddresses(salt, deployer);
        console.log("Deployer:", deployer);
        console.log("Salt:", vm.toString(salt));
        console.log("Predicted addresses:");
        console.log("  Implementation:", predicted.implementation);
        console.log("  Beacon:", predicted.beacon);
        console.log("  Wrapper:", predicted.wrapper);
    }
}

contract Deposit is Script {
    function run() public {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.envAddress("OWNER");
        address underlying = vm.envAddress("UNDERLYING_TOKEN");
        address wrapper = vm.envAddress("WRAPPER_ADDRESS");
        vm.createSelectFork("base");
        vm.startBroadcast(privateKey);
        uint256 amount = 600_000;
        IERC20(underlying).approve(wrapper, amount);
        SmartAccountWrapper(wrapper).requestDeposit(amount, owner, owner);
        vm.stopBroadcast();
    }
}

contract Withdraw is Script {
    function run() public {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.envAddress("OWNER");
        address wrapper = vm.envAddress("WRAPPER_ADDRESS");
        vm.createSelectFork("base");
        vm.startBroadcast(privateKey);
        uint256 amount = 100_000;
        SmartAccountWrapper(wrapper).requestRedeem(amount, owner, owner);
        vm.stopBroadcast();
    }
}
