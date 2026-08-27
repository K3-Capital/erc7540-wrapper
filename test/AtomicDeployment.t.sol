// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {CREATE3} from "solady/utils/CREATE3.sol";

import {SmartAccountWrapper} from "../src/SmartAccountWrapper.sol";
import {AtomicDeployment} from "../script/utils/AtomicDeployment.sol";
import {DeployHelper} from "../script/utils/DeployHelper.sol";

contract UnexpectedImplementation {
    function marker() external pure returns (uint256) {
        return 1;
    }
}

contract AtomicDeploymentTest is Test {
    bytes32 private constant PROXY_INITCODE_HASH = 0x21c35dbe1b344a2488cf3321d6ce542f8e9f305544ff09e4993a62319a497c1f;

    ERC20Mock private asset;
    DeployHelper.DeployParams private params;

    function setUp() public {
        asset = new ERC20Mock();
        params = DeployHelper.DeployParams({
            owner: address(this),
            smartAccount: makeAddr("safe"),
            underlyingToken: address(asset),
            name: "Atomic Vault",
            symbol: "ATOMIC",
            salt: keccak256("vault")
        });
    }

    function test_constructorCompletesCreate3DeploymentBeforeReturning() public {
        AtomicDeployment deployment = new AtomicDeployment{salt: keccak256("deployment")}(params);

        SmartAccountWrapper wrapper = SmartAccountWrapper(deployment.wrapper());
        assertEq(wrapper.owner(), params.owner);
        assertEq(wrapper.smartAccount(), params.smartAccount);
        assertEq(wrapper.asset(), params.underlyingToken);
        assertEq(UpgradeableBeacon(deployment.beacon()).implementation(), deployment.implementation());
        assertEq(deployment.implementation().codehash, keccak256(type(SmartAccountWrapper).runtimeCode));

        bytes32 implementationSalt = keccak256(abi.encodePacked(params.salt, "implementation"));
        address create3Proxy = _create3Proxy(address(deployment), implementationSalt);
        (bool success,) = create3Proxy.call(type(UnexpectedImplementation).creationCode);

        assertTrue(success, "the spent CREATE3 proxy can still create at nonce two");
        assertEq(deployment.implementation().codehash, keccak256(type(SmartAccountWrapper).runtimeCode));
        assertEq(UnexpectedImplementation(vm.computeCreateAddress(create3Proxy, 2)).marker(), 1);
    }

    function test_constructorRevertsTheEntireDeploymentOnInvalidInitialization() public {
        params.owner = address(0);
        bytes32 deploymentSalt = keccak256("invalid-deployment");
        bytes memory initCode = abi.encodePacked(type(AtomicDeployment).creationCode, abi.encode(params));
        address predictedDeployment = vm.computeCreate2Address(deploymentSalt, keccak256(initCode), address(this));
        bytes32 implementationSalt = keccak256(abi.encodePacked(params.salt, "implementation"));
        address predictedImplementation = CREATE3.predictDeterministicAddress(implementationSalt, predictedDeployment);

        vm.expectRevert();
        new AtomicDeployment{salt: deploymentSalt}(params);

        assertEq(predictedDeployment.code.length, 0);
        assertEq(predictedImplementation.code.length, 0);
    }

    function _create3Proxy(address deployer, bytes32 salt) private pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", deployer, salt, PROXY_INITCODE_HASH)))));
    }
}
