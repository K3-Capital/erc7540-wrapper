// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {SmartAccountWrapper} from "../src/SmartAccountWrapper.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

contract Upgrade is Script {
    function run() public {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address beacon = vm.envAddress("BEACON_ADDRESS");

        vm.startBroadcast(deployer);
        UpgradeableBeacon(beacon).upgradeTo(address(new SmartAccountWrapper()));
        vm.stopBroadcast();
    }
}
