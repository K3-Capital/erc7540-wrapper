// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {DeployHelper} from "../script/utils/DeployHelper.sol";
import {SmartAccountWrapper} from "../src/SmartAccountWrapper.sol";

contract ReentrantDepositAsset is ERC20Mock {
    SmartAccountWrapper private vault;
    bool private entered;

    function configure(SmartAccountWrapper vault_) external {
        vault = vault_;
        _mint(address(this), 150e18);
        _approve(address(this), address(vault_), 150e18);
    }

    function attack() external {
        vault.requestDeposit(100e18, address(this), address(this));
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        bool success = super.transferFrom(from, to, value);
        if (!entered) {
            entered = true;
            vault.requestDeposit(50e18, address(this), address(this));
        }
        return success;
    }
}

contract CrossFunctionCallbackAsset is ERC20Mock {
    SmartAccountWrapper private vault;
    bool private callbackArmed;
    bool private entered;
    bool public callbackBlocked;

    function configure(SmartAccountWrapper vault_) external {
        vault = vault_;
        _mint(address(this), 10e18);
        _approve(address(this), address(vault_), type(uint256).max);
    }

    function armCallback() external {
        callbackArmed = true;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        bool success = super.transfer(to, value);
        if (callbackArmed && !entered) {
            entered = true;
            try vault.requestDeposit(1, address(this), address(this)) returns (uint256) {
                callbackBlocked = false;
            } catch (bytes memory reason) {
                bytes4 selector;
                if (reason.length >= 4) {
                    assembly {
                        selector := mload(add(reason, 0x20))
                    }
                }
                callbackBlocked = selector == ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector;
            }
        }
        return success;
    }
}

contract ReentrancyHardeningTest is Test {
    address private safe = makeAddr("safe");
    bytes32 private constant REENTRANCY_GUARD_STORAGE =
        0x9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f00;

    function test_requestDepositRejectsNestedBalanceDeltaAccounting() public {
        ReentrantDepositAsset asset = new ReentrantDepositAsset();
        SmartAccountWrapper vault = _deployVault(address(asset));
        asset.configure(vault);

        vm.expectRevert(ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector);
        asset.attack();

        assertEq(asset.balanceOf(vault.staging()), 0, "reverted request leaves no staged assets");
        assertEq(vault.pendingDepositRequest(1, address(asset)), 0, "reverted request leaves no deposit credit");
    }

    function test_guardProtectsExistingProxyWithUninitializedNamespacedStatus() public {
        ReentrantDepositAsset asset = new ReentrantDepositAsset();
        SmartAccountWrapper vault = _deployVault(address(asset));
        asset.configure(vault);
        vm.store(address(vault), REENTRANCY_GUARD_STORAGE, bytes32(0));

        vm.expectRevert(ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector);
        asset.attack();

        assertEq(asset.balanceOf(vault.staging()), 0, "zero-status guard still rolls back the nested request");
        assertEq(vault.pendingDepositRequest(1, address(asset)), 0, "zero-status guard leaves no deposit credit");
    }

    function test_settleEpochBlocksCrossFunctionTokenCallback() public {
        CrossFunctionCallbackAsset asset = new CrossFunctionCallbackAsset();
        SmartAccountWrapper vault = _deployVault(address(asset));
        asset.configure(vault);
        address depositor = makeAddr("depositor");
        asset.mint(depositor, 100e18);

        vm.startPrank(depositor);
        asset.approve(address(vault), 100e18);
        vault.requestDeposit(100e18, depositor, depositor);
        vm.stopPrank();
        vm.prank(safe);
        vault.closeEpoch();
        asset.armCallback();

        vm.prank(safe);
        vault.settleEpoch(1, 0);

        assertTrue(asset.callbackBlocked(), "settlement must block callback into another guarded entrypoint");
    }

    function test_withdrawBlocksCrossFunctionTokenCallback() public {
        (CrossFunctionCallbackAsset asset, SmartAccountWrapper vault, address controller) = _prepareRedeemClaim();
        asset.armCallback();

        vm.prank(controller);
        vault.withdraw(50e18, controller, controller);

        assertTrue(asset.callbackBlocked(), "withdrawal must block callback into another guarded entrypoint");
    }

    function test_redeemBlocksCrossFunctionTokenCallback() public {
        (CrossFunctionCallbackAsset asset, SmartAccountWrapper vault, address controller) = _prepareRedeemClaim();
        asset.armCallback();

        vm.prank(controller);
        vault.redeem(50e18, controller, controller);

        assertTrue(asset.callbackBlocked(), "redemption must block callback into another guarded entrypoint");
    }

    function _prepareRedeemClaim()
        private
        returns (CrossFunctionCallbackAsset asset, SmartAccountWrapper vault, address controller)
    {
        asset = new CrossFunctionCallbackAsset();
        vault = _deployVault(address(asset));
        asset.configure(vault);
        controller = makeAddr("controller");
        asset.mint(controller, 100e18);

        vm.startPrank(controller);
        asset.approve(address(vault), 100e18);
        vault.requestDeposit(100e18, controller, controller);
        vm.stopPrank();
        vm.prank(safe);
        vault.closeEpoch();
        vm.prank(safe);
        vault.settleEpoch(1, 0);
        vm.prank(controller);
        vault.deposit(100e18, controller, controller);
        vm.prank(controller);
        vault.requestRedeem(50e18, controller, controller);
        vm.prank(safe);
        vault.closeEpoch();
        vm.startPrank(safe);
        assertTrue(asset.transfer(address(vault), 50e18));
        vault.settleEpoch(2, 100e18);
        vm.stopPrank();
    }

    function _deployVault(address asset) private returns (SmartAccountWrapper vault) {
        SmartAccountWrapper implementation = new SmartAccountWrapper();
        address beacon = DeployHelper.deployBeacon(address(implementation), address(this));
        vault = DeployHelper.deploySmartAccountWrapper(beacon, address(this), safe, asset, "Epoch Vault", "EV");
    }
}
