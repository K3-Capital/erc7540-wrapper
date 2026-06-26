// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {IERC7540Operator} from "forge-std/interfaces/IERC7540.sol";

import {DeployHelper} from "../script/utils/DeployHelper.sol";
import {SmartAccountWrapper} from "../src/SmartAccountWrapper.sol";
import {SemiAsyncRedeemVault} from "../src/SemiAsyncRedeemVault.sol";

contract ERC7540ComplianceTest is Test {
    SmartAccountWrapper public vault;
    ERC20Mock public asset;

    address safe = makeAddr("safe");
    address user = makeAddr("user");
    address operator = makeAddr("operator");

    function setUp() public {
        SmartAccountWrapper impl = new SmartAccountWrapper();
        asset = new ERC20Mock();
        address beacon = DeployHelper.deployBeacon(address(impl), address(this));
        vault = DeployHelper.deploySmartAccountWrapper(
            beacon, address(this), safe, address(asset), "ERC7540Vault", "E7540"
        );
        asset.mint(user, 1_000_000e18);
    }

    function test_setOperator() public {
        assertFalse(vault.isOperator(user, operator));

        vm.expectEmit(true, true, false, true);
        emit IERC7540Operator.OperatorSet(user, operator, true);

        vm.prank(user);
        assertTrue(vault.setOperator(operator, true));
        assertTrue(vault.isOperator(user, operator));

        vm.prank(user);
        assertTrue(vault.setOperator(operator, false));
        assertFalse(vault.isOperator(user, operator));
    }

    function test_requestViewsAreCallerIndependentAndSplitPendingClaimable() public {
        vm.startPrank(user);
        asset.approve(address(vault), 100e18);
        uint256 requestId = vault.requestDeposit(100e18, user, user);
        vm.stopPrank();

        assertEq(vault.pendingDepositRequest(requestId, user), 100e18);
        assertEq(vault.claimableDepositRequest(requestId, user), 0);

        vm.prank(safe);
        vault.closeEpoch();
        vm.prank(safe);
        vault.settleEpoch(1, 0);

        assertEq(vault.pendingDepositRequest(requestId, user), 0);
        assertEq(vault.claimableDepositRequest(requestId, user), 100e18);
    }

    function test_operatorCanClaimForController() public {
        vm.startPrank(user);
        asset.approve(address(vault), 100e18);
        vault.requestDeposit(100e18, user, user);
        vault.setOperator(operator, true);
        vm.stopPrank();

        vm.prank(safe);
        vault.closeEpoch();
        vm.prank(safe);
        vault.settleEpoch(1, 0);

        vm.prank(operator);
        uint256 shares = vault.deposit(100e18, operator, user);
        assertEq(shares, 100e18);
        assertEq(vault.balanceOf(operator), 100e18);
    }

    function test_previewFunctionsRevert() public {
        vm.expectRevert(SemiAsyncRedeemVault.SA__AsyncOnly.selector);
        vault.previewDeposit(1);
        vm.expectRevert(SemiAsyncRedeemVault.SA__AsyncOnly.selector);
        vault.previewMint(1);
        vm.expectRevert(SemiAsyncRedeemVault.SA__AsyncOnly.selector);
        vault.previewWithdraw(1);
        vm.expectRevert(SemiAsyncRedeemVault.SA__AsyncOnly.selector);
        vault.previewRedeem(1);
    }
}
