// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {DeployHelper} from "../script/utils/DeployHelper.sol";
import {SmartAccountWrapper} from "../src/SmartAccountWrapper.sol";
import {SemiAsyncRedeemVault} from "../src/SemiAsyncRedeemVault.sol";

contract EpochStagedERC7540FuzzTest is Test {
    using Math for uint256;

    SmartAccountWrapper public vault;
    ERC20Mock public asset;

    address public safe = makeAddr("safe");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public carol = makeAddr("carol");

    uint256 constant MAX_AMOUNT = 1e30;

    function setUp() public {
        SmartAccountWrapper impl = new SmartAccountWrapper();
        asset = new ERC20Mock();
        address beacon = DeployHelper.deployBeacon(address(impl), address(this));
        vault = DeployHelper.deploySmartAccountWrapper(beacon, address(this), safe, address(asset), "Epoch Vault", "EV");

        asset.mint(alice, MAX_AMOUNT);
        asset.mint(bob, MAX_AMOUNT);
        asset.mint(carol, MAX_AMOUNT);
        asset.mint(safe, MAX_AMOUNT);
    }

    function _requestDeposit(address user, uint256 assets) internal returns (uint256 requestId) {
        vm.startPrank(user);
        asset.approve(address(vault), assets);
        requestId = vault.requestDeposit(assets, user, user);
        vm.stopPrank();
    }

    function _settle(uint40 epochId, uint256 navSnapshot, uint256 preTransfer) internal {
        vm.startPrank(safe);
        if (preTransfer > 0) assertTrue(asset.transfer(address(vault), preTransfer));
        vault.settleEpoch(epochId, navSnapshot);
        vm.stopPrank();
    }

    function _seedVault(uint256 initialAssets) internal {
        _requestDeposit(alice, initialAssets);
        vm.prank(safe);
        vault.closeEpoch();
        _settle(1, 0, 0);
        vm.prank(alice);
        vault.deposit(initialAssets, alice, alice);
    }

    function testFuzz_depositSettlementUsesFloorPricePerShare(
        uint128 initialSupply_,
        uint128 navSnapshot_,
        uint128 depositAssets_
    ) public {
        uint256 initialSupply = bound(uint256(initialSupply_), 1, MAX_AMOUNT / 1e12);
        uint256 navSnapshot = bound(uint256(navSnapshot_), 1, MAX_AMOUNT / 1e12);
        uint256 depositAssets = bound(uint256(depositAssets_), 1, MAX_AMOUNT / 1e12);

        uint256 expectedShares = depositAssets.mulDiv(initialSupply, navSnapshot, Math.Rounding.Floor);
        vm.assume(expectedShares > 0);

        _seedVault(initialSupply);
        _requestDeposit(bob, depositAssets);
        vm.prank(safe);
        vault.closeEpoch();
        _settle(2, navSnapshot, 0);

        assertEq(vault.claimableDepositRequest(2, bob), depositAssets, "all requested assets remain claimable");
        assertEq(vault.maxMint(bob), expectedShares, "deposit shares use floor epoch PPS");
        assertEq(vault.totalAssets(), navSnapshot + depositAssets, "active assets use reported NAV plus deposits");

        vm.prank(bob);
        uint256 assetsIn = vault.mint(expectedShares, bob, bob);
        assertEq(assetsIn, depositAssets, "final mint claim consumes all deposit assets");
        assertEq(vault.balanceOf(bob), expectedShares, "controller receives rounded-down shares");
        assertEq(vault.maxDeposit(bob), 0, "claim queue advances after full claim");
    }

    function testFuzz_redeemSettlementUsesFloorPricePerShare(
        uint128 initialSupply_,
        uint128 navSnapshot_,
        uint128 redeemShares_
    ) public {
        uint256 initialSupply = bound(uint256(initialSupply_), 1, MAX_AMOUNT / 1e12);
        uint256 navSnapshot = bound(uint256(navSnapshot_), 1, MAX_AMOUNT / 1e12);
        uint256 redeemShares = bound(uint256(redeemShares_), 1, initialSupply);
        uint256 expectedAssets = redeemShares.mulDiv(navSnapshot, initialSupply, Math.Rounding.Floor);
        vm.assume(expectedAssets > 0);

        _seedVault(initialSupply);
        vm.prank(alice);
        vault.requestRedeem(redeemShares, alice, alice);
        vm.prank(safe);
        vault.closeEpoch();
        _settle(2, navSnapshot, expectedAssets);

        assertEq(vault.claimableRedeemRequest(2, alice), redeemShares, "all requested shares remain claimable");
        assertEq(vault.maxWithdraw(alice), expectedAssets, "redeem assets use floor epoch PPS");
        assertEq(vault.redeemClaimReserves(), expectedAssets, "reserved assets match settlement price");
        assertEq(vault.totalAssets(), navSnapshot - expectedAssets, "active assets exclude redeem claim reserve");

        uint256 aliceBefore = asset.balanceOf(alice);
        vm.prank(alice);
        uint256 sharesOut = vault.withdraw(expectedAssets, alice, alice);
        assertEq(sharesOut, redeemShares, "final withdraw claim consumes all redeem shares");
        assertEq(asset.balanceOf(alice), aliceBefore + expectedAssets, "controller receives rounded-down assets");
        assertEq(vault.redeemClaimReserves(), 0, "reserve is released by claim");
    }

    function testFuzz_partialDepositClaimsConserveRoundedSettlementShares(
        uint128 initialSupply_,
        uint128 navSnapshot_,
        uint128 depositAssets_,
        uint128 firstAssetClaim_
    ) public {
        uint256 initialSupply = bound(uint256(initialSupply_), 1, MAX_AMOUNT / 1e12);
        uint256 navSnapshot = bound(uint256(navSnapshot_), 1, MAX_AMOUNT / 1e12);
        uint256 depositAssets = bound(uint256(depositAssets_), 2, MAX_AMOUNT / 1e12);
        uint256 expectedShares = depositAssets.mulDiv(initialSupply, navSnapshot, Math.Rounding.Floor);
        vm.assume(expectedShares > 1);
        uint256 firstAssetClaim = bound(uint256(firstAssetClaim_), 1, depositAssets - 1);
        vm.assume(firstAssetClaim.mulDiv(expectedShares, depositAssets, Math.Rounding.Floor) > 0);

        _seedVault(initialSupply);
        _requestDeposit(bob, depositAssets);
        vm.prank(safe);
        vault.closeEpoch();
        _settle(2, navSnapshot, 0);

        uint256 expectedFirstShares = firstAssetClaim.mulDiv(expectedShares, depositAssets, Math.Rounding.Floor);
        vm.prank(bob);
        uint256 firstShares = vault.deposit(firstAssetClaim, bob, bob);
        assertEq(firstShares, expectedFirstShares, "partial deposit claim rounds shares down");

        uint256 remainingAssets = depositAssets - firstAssetClaim;
        uint256 remainingShares = expectedShares - expectedFirstShares;
        assertEq(vault.maxDeposit(bob), remainingAssets, "unclaimed deposit assets are tracked exactly");
        assertEq(vault.maxMint(bob), remainingShares, "unclaimed deposit shares carry rounding residue");

        vm.prank(bob);
        uint256 finalAssets = vault.mint(remainingShares, bob, bob);
        assertEq(finalAssets, remainingAssets, "final mint consumes exact remaining assets");
        assertEq(vault.balanceOf(bob), expectedShares, "partial plus final claims conserve rounded shares");
        assertEq(vault.maxMint(bob), 0, "deposit claim fully consumed");
    }

    function testFuzz_partialRedeemClaimsConserveRoundedSettlementAssets(
        uint128 initialSupply_,
        uint128 navSnapshot_,
        uint128 redeemShares_,
        uint128 firstAssetClaim_
    ) public {
        uint256 initialSupply = bound(uint256(initialSupply_), 2, MAX_AMOUNT / 1e12);
        uint256 navSnapshot = bound(uint256(navSnapshot_), 1, MAX_AMOUNT / 1e12);
        uint256 redeemShares = bound(uint256(redeemShares_), 2, initialSupply);
        uint256 expectedAssets = redeemShares.mulDiv(navSnapshot, initialSupply, Math.Rounding.Floor);
        vm.assume(expectedAssets > 1);
        uint256 firstAssetClaim = bound(uint256(firstAssetClaim_), 1, expectedAssets - 1);

        _seedVault(initialSupply);
        vm.prank(alice);
        vault.requestRedeem(redeemShares, alice, alice);
        vm.prank(safe);
        vault.closeEpoch();
        _settle(2, navSnapshot, expectedAssets);

        uint256 expectedFirstShares = firstAssetClaim.mulDiv(redeemShares, expectedAssets, Math.Rounding.Ceil);
        vm.assume(expectedFirstShares < redeemShares);
        vm.prank(alice);
        uint256 firstShares = vault.withdraw(firstAssetClaim, alice, alice);
        assertEq(firstShares, expectedFirstShares, "partial withdraw claim rounds shares up");

        uint256 remainingAssets = expectedAssets - firstAssetClaim;
        uint256 remainingShares = redeemShares - expectedFirstShares;
        assertEq(vault.maxWithdraw(alice), remainingAssets, "unclaimed redeem assets are tracked exactly");
        assertEq(vault.maxRedeem(alice), remainingShares, "unclaimed redeem shares carry rounding residue");

        uint256 aliceBefore = asset.balanceOf(alice);
        vm.prank(alice);
        uint256 finalAssets = vault.redeem(remainingShares, alice, alice);
        assertEq(finalAssets, remainingAssets, "final redeem consumes exact remaining assets");
        assertEq(
            asset.balanceOf(alice), aliceBefore + remainingAssets, "partial plus final claims conserve rounded assets"
        );
        assertEq(vault.redeemClaimReserves(), 0, "redeem reserve fully released");
    }

    function testFuzz_twoDepositorsAllocationDustStaysInStaging(
        uint128 initialSupply_,
        uint128 navSnapshot_,
        uint128 aliceAssets_,
        uint128 bobAssets_
    ) public {
        uint256 initialSupply = bound(uint256(initialSupply_), 1, MAX_AMOUNT / 1e12);
        uint256 navSnapshot = bound(uint256(navSnapshot_), 1, MAX_AMOUNT / 1e12);
        uint256 aliceAssets = bound(uint256(aliceAssets_), 1, MAX_AMOUNT / 1e12);
        uint256 bobAssets = bound(uint256(bobAssets_), 1, MAX_AMOUNT / 1e12);
        uint256 totalDepositAssets = aliceAssets + bobAssets;
        uint256 settlementShares = totalDepositAssets.mulDiv(initialSupply, navSnapshot, Math.Rounding.Floor);
        vm.assume(settlementShares >= 2);

        _seedVault(initialSupply);
        _requestDeposit(alice, aliceAssets);
        _requestDeposit(bob, bobAssets);
        vm.prank(safe);
        vault.closeEpoch();
        _settle(2, navSnapshot, 0);

        uint256 aliceShares = aliceAssets.mulDiv(settlementShares, totalDepositAssets, Math.Rounding.Floor);
        uint256 bobShares = bobAssets.mulDiv(settlementShares, totalDepositAssets, Math.Rounding.Floor);
        vm.assume(aliceShares > 0 && bobShares > 0);

        vm.prank(alice);
        vault.deposit(aliceAssets, alice, alice);
        vm.prank(bob);
        vault.deposit(bobAssets, bob, bob);

        assertEq(vault.balanceOf(alice), initialSupply + aliceShares, "alice gets floor allocation");
        assertEq(vault.balanceOf(bob), bobShares, "bob gets floor allocation");
        assertLe(settlementShares - aliceShares - bobShares, 1, "two-way allocation dust is bounded");
        assertEq(
            vault.balanceOf(vault.staging()),
            settlementShares - aliceShares - bobShares,
            "share dust remains in staging"
        );
    }
}
