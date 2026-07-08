// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {IERC7540Operator} from "forge-std/interfaces/IERC7540.sol";
import {IERC7575, IERC7575Share} from "forge-std/interfaces/IERC7575.sol";

import {DeployHelper} from "../script/utils/DeployHelper.sol";
import {SmartAccountWrapper} from "../src/SmartAccountWrapper.sol";
import {EpochStagedERC7540Vault} from "../src/EpochStagedERC7540Vault.sol";

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

    function test_operatorCannotRedirectOwnerFundedDepositToOwnController() public {
        vm.startPrank(user);
        asset.approve(address(vault), 100e18);
        vault.setOperator(operator, true);
        vm.stopPrank();

        vm.prank(operator);
        vm.expectRevert(EpochStagedERC7540Vault.SA__NotAuthorized.selector);
        vault.requestDeposit(100e18, operator, user);

        assertEq(vault.pendingDepositRequest(1, operator), 0);
        assertEq(asset.balanceOf(user), 1_000_000e18);
    }

    function test_unrelatedCallerCannotSelfFundVictimControllerRequest() public {
        asset.mint(operator, 100e18);

        vm.startPrank(operator);
        asset.approve(address(vault), 100e18);
        vm.expectRevert(EpochStagedERC7540Vault.SA__NotAuthorized.selector);
        vault.requestDeposit(100e18, user, operator);
        vm.stopPrank();

        assertEq(vault.pendingDepositRequest(1, user), 0);
        assertEq(asset.balanceOf(operator), 100e18);
    }

    function test_controllerAuthorizedCallerCanSelfFundControllerRequest() public {
        asset.mint(operator, 100e18);

        vm.prank(user);
        vault.setOperator(operator, true);

        vm.startPrank(operator);
        asset.approve(address(vault), 100e18);
        uint256 requestId = vault.requestDeposit(100e18, user, operator);
        vm.stopPrank();

        assertEq(requestId, 1);
        assertEq(vault.pendingDepositRequest(requestId, user), 100e18);
        assertEq(asset.balanceOf(operator), 0);
    }

    function test_previewFunctionsRevert() public {
        vm.expectRevert(EpochStagedERC7540Vault.SA__AsyncOnly.selector);
        vault.previewDeposit(1);
        vm.expectRevert(EpochStagedERC7540Vault.SA__AsyncOnly.selector);
        vault.previewMint(1);
        vm.expectRevert(EpochStagedERC7540Vault.SA__AsyncOnly.selector);
        vault.previewWithdraw(1);
        vm.expectRevert(EpochStagedERC7540Vault.SA__AsyncOnly.selector);
        vault.previewRedeem(1);
    }

    function test_erc7575ShareSideCompatibilityWhenShareIsVault() public view {
        IERC7575Share shareToken = IERC7575Share(vault.share());

        assertEq(vault.share(), address(vault));
        assertEq(shareToken.vault(address(asset)), address(vault));
        assertEq(shareToken.vault(address(0xBEEF)), address(0));
        assertTrue(vault.supportsInterface(type(IERC7575).interfaceId));
        assertTrue(vault.supportsInterface(type(IERC7575Share).interfaceId));
    }
}
