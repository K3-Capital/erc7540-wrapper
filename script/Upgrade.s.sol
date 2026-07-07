// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {SmartAccountWrapper} from "../src/SmartAccountWrapper.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

contract Upgrade is Script {
    function run() public {
        address beaconOwner = vm.envAddress("BEACON_OWNER");
        address beacon = vm.envAddress("BEACON_ADDRESS");

        vm.startBroadcast(beaconOwner);
        UpgradeableBeacon(beacon).upgradeTo(address(new SmartAccountWrapper()));
        vm.stopBroadcast();
    }
}
