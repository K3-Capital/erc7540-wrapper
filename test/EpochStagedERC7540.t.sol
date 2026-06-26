// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {IERC7540Deposit, IERC7540Redeem} from "forge-std/interfaces/IERC7540.sol";

import {DeployHelper} from "../script/utils/DeployHelper.sol";
import {SmartAccountWrapper} from "../src/SmartAccountWrapper.sol";
import {SemiAsyncRedeemVault} from "../src/SemiAsyncRedeemVault.sol";
import {Staging} from "../src/Staging.sol";

contract EpochStagedERC7540Test is Test {
    SmartAccountWrapper public vault;
    ERC20Mock public asset;

    address public safe = makeAddr("safe");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    uint256 constant ONE = 1e18;

    function setUp() public {
        SmartAccountWrapper impl = new SmartAccountWrapper();
        asset = new ERC20Mock();
        address beacon = DeployHelper.deployBeacon(address(impl), address(this));
        vault = DeployHelper.deploySmartAccountWrapper(beacon, address(this), safe, address(asset), "Epoch Vault", "EV");

        asset.mint(alice, 1_000_000 * ONE);
        asset.mint(bob, 1_000_000 * ONE);
        asset.mint(safe, 1_000_000 * ONE);
    }

    function _requestDeposit(address user, uint256 assets) internal returns (uint256 requestId) {
        vm.startPrank(user);
        asset.approve(address(vault), assets);
        requestId = vault.requestDeposit(assets, user, user);
        vm.stopPrank();
    }

    function _claimDeposit(address user, uint256 assets) internal returns (uint256 shares) {
        vm.prank(user);
        shares = vault.deposit(assets, user, user);
    }

    function _settle(uint40 epochId, uint256 navSnapshot, uint256 preTransfer) internal {
        vm.startPrank(safe);
        if (preTransfer > 0) assertTrue(asset.transfer(address(vault), preTransfer));
        vault.settleEpoch(epochId, navSnapshot);
        vm.stopPrank();
    }

    function test_requestDeposit_stagesAssetsWithoutMintingShares() public {
        uint256 requestId = _requestDeposit(alice, 100 * ONE);

        assertEq(requestId, 1, "request id is current epoch");
        assertEq(vault.share(), address(vault), "ERC-7575 share token is the vault token");
        assertEq(vault.pendingDepositRequest(requestId, alice), 100 * ONE, "pending deposit assets");
        assertEq(vault.claimableDepositRequest(requestId, alice), 0, "not claimable before settlement");
        assertEq(vault.balanceOf(alice), 0, "request does not mint shares");
        assertEq(asset.balanceOf(vault.staging()), 100 * ONE, "assets staged");
    }

    function test_requestValidationAndInvalidRequestIdReverts() public {
        vm.startPrank(alice);
        asset.approve(address(vault), 100 * ONE);
        vm.expectRevert(SemiAsyncRedeemVault.SA__ZeroAmount.selector);
        vault.requestDeposit(0, alice, alice);
        vm.expectRevert(SemiAsyncRedeemVault.SA__ZeroAddress.selector);
        vault.requestDeposit(1, address(0), alice);
        vm.stopPrank();

        vm.prank(bob);
        vm.expectRevert(SemiAsyncRedeemVault.SA__NotAuthorized.selector);
        vault.requestDeposit(1, bob, alice);

        vm.startPrank(alice);
        vm.expectRevert(SemiAsyncRedeemVault.SA__ZeroAmount.selector);
        vault.requestRedeem(0, alice, alice);
        vm.expectRevert(SemiAsyncRedeemVault.SA__ZeroAddress.selector);
        vault.requestRedeem(1, address(0), alice);
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(SemiAsyncRedeemVault.SA__InvalidRequestId.selector, uint256(type(uint40).max) + 1)
        );
        vault.pendingDepositRequest(uint256(type(uint40).max) + 1, alice);
    }

    function test_closeEpoch_freezesOneEpochAndOpensNext() public {
        _requestDeposit(alice, 100 * ONE);

        vm.prank(safe);
        (uint40 closedEpochId, uint40 nextEpochId) = vault.closeEpoch();

        assertEq(closedEpochId, 1);
        assertEq(nextEpochId, 2);
        assertEq(vault.frozenEpochId(), 1);
        assertEq(vault.currentEpochId(), 2);

        _requestDeposit(bob, 50 * ONE);
        assertEq(vault.pendingDepositRequest(1, bob), 0, "new requests do not enter frozen epoch");
        assertEq(vault.pendingDepositRequest(2, bob), 50 * ONE, "new requests enter next open epoch");

        vm.prank(safe);
        vm.expectRevert(SemiAsyncRedeemVault.SA__FrozenEpochPending.selector);
        vault.closeEpoch();
    }

    function test_settleEpoch_claimDepositAndMoveSurplusToSafe() public {
        _requestDeposit(alice, 100 * ONE);

        vm.prank(safe);
        vault.closeEpoch();
        _settle(1, 0, 0);

        assertEq(vault.totalAssets(), 100 * ONE, "active NAV includes settled deposit");
        assertEq(vault.claimableDepositRequest(1, alice), 100 * ONE, "deposit claimable");
        assertEq(vault.maxDeposit(alice), 100 * ONE, "oldest claimable assets");
        assertEq(asset.balanceOf(safe), 1_000_000 * ONE + 100 * ONE, "surplus staged assets transferred to safe");

        uint256 shares = _claimDeposit(alice, 100 * ONE);
        assertEq(shares, 100 * ONE, "initial epoch mints 1:1");
        assertEq(vault.balanceOf(alice), 100 * ONE, "claimed shares received");
        assertEq(vault.maxDeposit(alice), 0, "claim consumed");
    }

    function test_settleEpoch_usesLazyPerEpochPricingForManyControllers() public {
        address[8] memory users;
        for (uint256 i = 0; i < users.length; i++) {
            users[i] = makeAddr(string.concat("depositor", vm.toString(i)));
            asset.mint(users[i], 100 * ONE);
            _requestDeposit(users[i], (i + 1) * ONE);
        }

        vm.prank(safe);
        vault.closeEpoch();

        uint256 gasBefore = gasleft();
        _settle(1, 0, 0);
        uint256 settleGas = gasBefore - gasleft();

        assertLt(settleGas, 250_000, "settlement must not scale with controller count");
        for (uint256 i = 0; i < users.length; i++) {
            uint256 assets = (i + 1) * ONE;
            assertEq(vault.claimableDepositRequest(1, users[i]), assets, "assets claim lazily from epoch totals");
            assertEq(vault.maxMint(users[i]), assets, "shares claim lazily from settlement price");
        }
    }

    function test_requestRedeem_settleWithNettingAndClaimAssets() public {
        _requestDeposit(alice, 100 * ONE);
        vm.prank(safe);
        vault.closeEpoch();
        _settle(1, 0, 0);
        _claimDeposit(alice, 100 * ONE);

        vm.prank(alice);
        uint256 redeemRequestId = vault.requestRedeem(40 * ONE, alice, alice);
        assertEq(redeemRequestId, 2, "redeem request uses current epoch");
        assertEq(vault.pendingRedeemRequest(2, alice), 40 * ONE, "redeem pending");
        assertEq(vault.balanceOf(vault.staging()), 40 * ONE, "redeem shares staged");

        _requestDeposit(bob, 100 * ONE);

        vm.prank(safe);
        vault.closeEpoch();
        _settle(2, 100 * ONE, 0);

        assertEq(vault.pendingRedeemRequest(2, alice), 0, "redeem no longer pending after settlement");
        assertEq(vault.claimableRedeemRequest(2, alice), 40 * ONE, "redeem claimable");
        assertEq(vault.maxRedeem(alice), 40 * ONE, "oldest redeem claimable shares");
        assertEq(vault.claimableDepositRequest(2, bob), 100 * ONE, "deposit claimable");
        assertEq(asset.balanceOf(safe), 1_000_000 * ONE + 160 * ONE, "net surplus moved to safe");
        assertEq(vault.totalAssets(), 160 * ONE, "post-settlement active assets");

        uint256 aliceAssetsBefore = asset.balanceOf(alice);
        vm.prank(alice);
        uint256 assetsOut = vault.redeem(40 * ONE, alice, alice);
        assertEq(assetsOut, 40 * ONE, "redeem pays settled assets");
        assertEq(asset.balanceOf(alice), aliceAssetsBefore + 40 * ONE, "assets received");

        vm.prank(bob);
        uint256 bobShares = vault.deposit(100 * ONE, bob, bob);
        assertEq(bobShares, 100 * ONE, "deposit priced at same epoch NAV");
    }

    function test_depositAndMintOverloadsUseSenderAsController() public {
        _requestDeposit(alice, 100 * ONE);
        _requestDeposit(bob, 50 * ONE);
        vm.prank(safe);
        vault.closeEpoch();
        _settle(1, 0, 0);

        vm.prank(alice);
        uint256 aliceShares = vault.deposit(100 * ONE, alice);
        assertEq(aliceShares, 100 * ONE, "two-argument deposit claims msg.sender controller");

        vm.prank(bob);
        uint256 bobAssets = vault.mint(50 * ONE, bob);
        assertEq(bobAssets, 50 * ONE, "two-argument mint claims msg.sender controller");
    }

    function test_mintAndWithdrawClaimPaths() public {
        _requestDeposit(alice, 100 * ONE);
        vm.prank(safe);
        vault.closeEpoch();
        _settle(1, 0, 0);

        vm.prank(alice);
        uint256 assetsIn = vault.mint(40 * ONE, alice, alice);
        assertEq(assetsIn, 40 * ONE, "mint claim consumes proportional deposit assets");
        assertEq(vault.maxDeposit(alice), 60 * ONE, "deposit claim remains on oldest epoch");
        assertEq(vault.maxMint(alice), 60 * ONE, "share claim remains on oldest epoch");

        vm.prank(alice);
        assetsIn = vault.mint(60 * ONE, alice, alice);
        assertEq(assetsIn, 60 * ONE, "final mint claim consumes remaining assets");
        assertEq(vault.balanceOf(alice), 100 * ONE, "all shares claimed");

        vm.prank(alice);
        vault.requestRedeem(50 * ONE, alice, alice);
        vm.prank(safe);
        vault.closeEpoch();
        _settle(2, 100 * ONE, 50 * ONE);

        assertEq(vault.maxWithdraw(alice), 50 * ONE, "withdraw assets available on oldest redeem epoch");
        vm.prank(alice);
        uint256 sharesOut = vault.withdraw(20 * ONE, alice, alice);
        assertEq(sharesOut, 20 * ONE, "withdraw claim consumes proportional redeem shares");
        assertEq(vault.maxWithdraw(alice), 30 * ONE, "remaining redeem assets stay claimable");

        vm.prank(alice);
        sharesOut = vault.withdraw(30 * ONE, alice, alice);
        assertEq(sharesOut, 30 * ONE, "final withdraw consumes remaining redeem shares");
        assertEq(vault.maxWithdraw(alice), 0, "redeem claim consumed");
    }

    function test_settlementValidationReverts() public {
        _requestDeposit(alice, 100 * ONE);
        vm.prank(safe);
        vault.closeEpoch();

        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(SemiAsyncRedeemVault.SA__WrongEpoch.selector, uint256(1), uint256(2)));
        vault.settleEpoch(2, 0);

        _settle(1, 0, 0);

        vm.prank(safe);
        vm.expectRevert(SemiAsyncRedeemVault.SA__NoFrozenEpoch.selector);
        vault.settleEpoch(1, 0);

        _claimDeposit(alice, 100 * ONE);
        vm.prank(alice);
        vault.requestRedeem(1, alice, alice);
        vm.prank(safe);
        vault.closeEpoch();

        vm.prank(safe);
        vm.expectRevert(SemiAsyncRedeemVault.SA__InvalidNavSnapshot.selector);
        vault.settleEpoch(2, 0);
    }

    function test_assetDonationsDoNotChangeEpochPricing() public {
        asset.mint(address(this), 1_000 * ONE);
        assertTrue(asset.transfer(address(vault), 10 * ONE));
        assertTrue(asset.transfer(vault.staging(), 20 * ONE));

        _requestDeposit(alice, 100 * ONE);
        vm.prank(safe);
        vault.closeEpoch();
        _settle(1, 0, 0);

        assertEq(vault.totalAssets(), 100 * ONE, "donations excluded from active NAV");
        assertEq(vault.claimableDepositRequest(1, alice), 100 * ONE, "donations excluded from deposit claim assets");
        assertEq(vault.maxMint(alice), 100 * ONE, "donations excluded from deposit claim shares");
        assertEq(asset.balanceOf(vault.staging()), 20 * ONE, "staging donation is not swept into epoch settlement");
        assertEq(
            asset.balanceOf(safe),
            1_000_000 * ONE + 110 * ONE,
            "vault donation plus settled deposit surplus moves to safe"
        );
    }

    function test_rescueCannotDrainRedeemClaimReserves() public {
        _requestDeposit(alice, 100 * ONE);
        vm.prank(safe);
        vault.closeEpoch();
        _settle(1, 0, 0);
        _claimDeposit(alice, 100 * ONE);

        vm.prank(alice);
        vault.requestRedeem(40 * ONE, alice, alice);
        vm.prank(safe);
        vault.closeEpoch();
        _settle(2, 100 * ONE, 40 * ONE);

        assertEq(vault.redeemClaimReserves(), 40 * ONE, "redeem reserve recorded");
        vm.expectRevert(SemiAsyncRedeemVault.SA__InsufficientSettlementAssets.selector);
        vault.rescue(address(asset), 1);

        vm.prank(alice);
        assertEq(vault.redeem(40 * ONE, alice, alice), 40 * ONE, "reserve remains claimable");
    }

    function test_rescueAssetSurplusSendsDonationsToSafe() public {
        asset.mint(address(vault), 7 * ONE);
        uint256 safeBefore = asset.balanceOf(safe);

        assertEq(vault.assetSurplus(), 7 * ONE, "donated asset balance is surplus");
        vault.rescue(address(asset), 7 * ONE);

        assertEq(asset.balanceOf(safe), safeBefore + 7 * ONE, "asset surplus belongs to the Safe");
    }

    function test_stagingOnlyVaultCanTransferTokens() public {
        address staging_ = vault.staging();
        asset.mint(staging_, 1);

        vm.expectRevert(Staging.ST__NotVault.selector);
        Staging(staging_).transferToken(address(asset), alice, 1);
    }

    function test_settleEpoch_revertsWhenRedeemReserveIsUnderfunded() public {
        _requestDeposit(alice, 100 * ONE);
        vm.prank(safe);
        vault.closeEpoch();
        _settle(1, 0, 0);
        _claimDeposit(alice, 100 * ONE);

        vm.prank(alice);
        vault.requestRedeem(80 * ONE, alice, alice);

        vm.prank(safe);
        vault.closeEpoch();

        vm.prank(safe);
        vm.expectRevert(SemiAsyncRedeemVault.SA__InsufficientSettlementAssets.selector);
        vault.settleEpoch(2, 100 * ONE);
    }

    function test_previewFunctionsRevertBecauseVaultIsFullyAsync() public {
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

