// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC7540Deposit, IERC7540Redeem} from "forge-std/interfaces/IERC7540.sol";

import {DeployHelper} from "../script/utils/DeployHelper.sol";
import {SmartAccountWrapper} from "../src/SmartAccountWrapper.sol";
import {EpochStagedERC7540Vault} from "../src/EpochStagedERC7540Vault.sol";
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
        vm.expectRevert(EpochStagedERC7540Vault.SA__ZeroAmount.selector);
        vault.requestDeposit(0, alice, alice);
        vm.expectRevert(EpochStagedERC7540Vault.SA__ZeroAddress.selector);
        vault.requestDeposit(1, address(0), alice);
        vm.stopPrank();

        vm.prank(bob);
        vm.expectRevert(EpochStagedERC7540Vault.SA__NotAuthorized.selector);
        vault.requestDeposit(1, bob, alice);

        vm.startPrank(alice);
        vm.expectRevert(EpochStagedERC7540Vault.SA__ZeroAmount.selector);
        vault.requestRedeem(0, alice, alice);
        vm.expectRevert(EpochStagedERC7540Vault.SA__ZeroAddress.selector);
        vault.requestRedeem(1, address(0), alice);
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(EpochStagedERC7540Vault.SA__InvalidRequestId.selector, uint256(type(uint40).max) + 1)
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
        vm.expectRevert(EpochStagedERC7540Vault.SA__FrozenEpochPending.selector);
        vault.closeEpoch();
    }

    function test_operatorDepositAndRedeemAllowanceBranches() public {
        vm.prank(alice);
        vault.setOperator(bob, true);

        vm.startPrank(bob);
        asset.approve(address(vault), 25 * ONE);
        uint256 requestId = vault.requestDeposit(25 * ONE, alice, bob);
        vm.stopPrank();

        assertEq(requestId, 1, "operator deposit uses current epoch");
        assertEq(vault.pendingDepositRequest(1, alice), 25 * ONE, "deposit credited to controller");

        vm.prank(safe);
        vault.closeEpoch();
        _settle(1, 0, 0);

        vm.prank(alice);
        vault.deposit(25 * ONE, alice, alice);

        vm.prank(alice);
        vault.approve(bob, 10 * ONE);
        vm.prank(bob);
        uint256 redeemRequestId = vault.requestRedeem(10 * ONE, alice, alice);

        assertEq(redeemRequestId, 2, "spender redeem uses current epoch");
        assertEq(vault.pendingRedeemRequest(2, alice), 10 * ONE, "redeem credited to controller");
        assertEq(vault.allowance(alice, bob), 0, "spender allowance consumed");
    }

    function test_sameEpochRepeatedRequestsDoNotDuplicateQueueEntries() public {
        _requestDeposit(alice, 10 * ONE);
        _requestDeposit(alice, 15 * ONE);
        vm.prank(safe);
        vault.closeEpoch();
        _settle(1, 0, 0);

        assertEq(vault.maxDeposit(alice), 25 * ONE, "same-epoch deposits are aggregated");
        vm.prank(alice);
        vault.deposit(25 * ONE, alice, alice);
        assertEq(vault.maxDeposit(alice), 0, "single queue entry advanced after aggregate claim");

        vm.prank(alice);
        vault.requestRedeem(5 * ONE, alice, alice);
        vm.prank(alice);
        vault.requestRedeem(7 * ONE, alice, alice);
        vm.prank(safe);
        vault.closeEpoch();
        _settle(2, 25 * ONE, 12 * ONE);

        assertEq(vault.maxRedeem(alice), 12 * ONE, "same-epoch redeems are aggregated");
        vm.prank(alice);
        vault.redeem(12 * ONE, alice, alice);
        assertEq(vault.maxRedeem(alice), 0, "single redeem queue entry advanced after aggregate claim");
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

    function test_settleEpoch_revertsOnBootstrapNavSnapshot() public {
        _requestDeposit(alice, 100 * ONE);

        vm.prank(safe);
        vault.closeEpoch();

        vm.prank(safe);
        vm.expectRevert(EpochStagedERC7540Vault.SA__InvalidNavSnapshot.selector);
        vault.settleEpoch(1, 1);

        assertEq(vault.frozenEpochId(), 1, "failed bootstrap settlement keeps epoch frozen for retry");
        _settle(1, 0, 0);
        assertEq(vault.frozenEpochId(), 0, "corrected bootstrap settlement clears frozen epoch");
        assertEq(vault.maxDeposit(alice), 100 * ONE, "corrected bootstrap settlement remains claimable");
    }

    function test_settleEpoch_allowsEmptyBootstrapZeroNavAndNextEpochProgresses() public {
        vm.prank(safe);
        vault.closeEpoch();

        _settle(1, 0, 0);

        assertEq(vault.frozenEpochId(), 0, "empty zero-NAV bootstrap settlement clears frozen epoch");
        assertEq(vault.currentEpochId(), 2, "next epoch remains open");
        assertEq(vault.totalAssets(), 0, "empty bootstrap keeps NAV at zero");
        assertEq(vault.totalSupply(), 0, "empty bootstrap keeps supply at zero");

        _requestDeposit(alice, 100 * ONE);
        assertEq(
            vault.pendingDepositRequest(2, alice), 100 * ONE, "new deposit enters next epoch after empty settlement"
        );

        vm.prank(safe);
        vault.closeEpoch();
        _settle(2, 0, 0);

        assertEq(vault.frozenEpochId(), 0, "second zero-NAV bootstrap settlement clears frozen epoch");
        assertEq(vault.currentEpochId(), 3, "ops can continue after second settlement");
        assertEq(vault.maxDeposit(alice), 100 * ONE, "deposit remains claimable after second settlement");

        uint256 shares = _claimDeposit(alice, 100 * ONE);
        assertEq(shares, 100 * ONE, "first funded epoch still mints 1:1 after empty epoch");
        assertEq(vault.balanceOf(alice), 100 * ONE, "claimed shares received");
    }

    function test_settleEpoch_allowsEmptyNonBootstrapEpochAndNextEpochProgresses() public {
        _requestDeposit(alice, 100 * ONE);
        vm.prank(safe);
        vault.closeEpoch();
        _settle(1, 0, 0);
        _claimDeposit(alice, 100 * ONE);

        assertEq(vault.totalSupply(), 100 * ONE, "bootstrap supply exists");
        assertEq(vault.totalAssets(), 100 * ONE, "bootstrap NAV exists");

        vm.prank(safe);
        vault.closeEpoch();
        _settle(2, 100 * ONE, 0);

        assertEq(vault.frozenEpochId(), 0, "empty non-bootstrap settlement clears frozen epoch");
        assertEq(vault.currentEpochId(), 3, "ops can advance past empty non-bootstrap epoch");
        assertEq(vault.totalSupply(), 100 * ONE, "empty non-bootstrap epoch does not change supply");
        assertEq(vault.totalAssets(), 100 * ONE, "empty non-bootstrap epoch preserves reported NAV");

        _requestDeposit(bob, 50 * ONE);
        assertEq(vault.pendingDepositRequest(3, bob), 50 * ONE, "new deposit enters next epoch after empty epoch");

        vm.prank(safe);
        vault.closeEpoch();
        _settle(3, 100 * ONE, 0);

        assertEq(vault.frozenEpochId(), 0, "following settlement clears frozen epoch");
        assertEq(vault.maxDeposit(bob), 50 * ONE, "following deposit remains claimable");
    }

    function test_closeAndSettleEpoch_whenPaused() public {
        _requestDeposit(alice, 100 * ONE);
        vault.pause();

        vm.prank(safe);
        vault.closeEpoch();
        _settle(1, 0, 0);

        assertEq(vault.frozenEpochId(), 0, "paused settlement clears frozen epoch");
        assertEq(vault.currentEpochId(), 2, "paused ops can advance epoch");
        assertEq(vault.maxDeposit(alice), 0, "claims remain blocked in max views while paused");

        vault.unpause();
        assertEq(vault.maxDeposit(alice), 100 * ONE, "claim becomes visible after unpause");

        uint256 shares = _claimDeposit(alice, 100 * ONE);
        assertEq(shares, 100 * ONE, "deposit remains claimable after paused settlement");
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

    function test_maxViewsReturnZeroWhenPausedOrNoClaimableEpoch() public {
        assertEq(vault.maxDeposit(alice), 0, "no deposit claim");
        assertEq(vault.maxMint(alice), 0, "no mint claim");
        assertEq(vault.maxWithdraw(alice), 0, "no withdraw claim");
        assertEq(vault.maxRedeem(alice), 0, "no redeem claim");
        assertEq(vault.claimableRedeemRequest(1, alice), 0, "unsettled redeem request is not claimable");

        _requestDeposit(alice, 100 * ONE);
        vm.prank(safe);
        vault.closeEpoch();
        _settle(1, 0, 0);

        vault.pause();
        assertEq(vault.maxDeposit(alice), 0, "paused deposit max");
        assertEq(vault.maxMint(alice), 0, "paused mint max");
        assertEq(vault.maxWithdraw(alice), 0, "paused withdraw max");
        assertEq(vault.maxRedeem(alice), 0, "paused redeem max");
        vault.unpause();

        vm.prank(alice);
        vault.deposit(100 * ONE, alice, alice);
        vm.prank(alice);
        vault.requestRedeem(25 * ONE, alice, alice);
        vm.prank(safe);
        vault.closeEpoch();
        _settle(2, 100 * ONE, 25 * ONE);

        vault.pause();
        assertEq(vault.maxWithdraw(alice), 0, "paused withdraw claim max");
        assertEq(vault.maxRedeem(alice), 0, "paused redeem claim max");
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
        assertEq(asset.balanceOf(address(vault)), 0, "vault does not custody redeem claim reserves");
        assertEq(asset.balanceOf(vault.staging()), 40 * ONE, "redeem claim reserves are staged");
        assertEq(vault.totalAssets(), 160 * ONE, "post-settlement active assets");

        uint256 aliceAssetsBefore = asset.balanceOf(alice);
        vm.prank(alice);
        uint256 assetsOut = vault.redeem(40 * ONE, alice, alice);
        assertEq(assetsOut, 40 * ONE, "redeem pays settled assets");
        assertEq(asset.balanceOf(alice), aliceAssetsBefore + 40 * ONE, "assets received");
        assertEq(asset.balanceOf(vault.staging()), 0, "redeem claim releases staged reserves");

        vm.prank(bob);
        uint256 bobShares = vault.deposit(100 * ONE, bob, bob);
        assertEq(bobShares, 100 * ONE, "deposit priced at same epoch NAV");
    }

    function test_operatorRedeemClaimEmitsControllerAsWithdrawOwner() public {
        _requestDeposit(alice, 100 * ONE);
        vm.prank(safe);
        vault.closeEpoch();
        _settle(1, 0, 0);
        _claimDeposit(alice, 100 * ONE);

        vm.prank(alice);
        vault.setOperator(bob, true);
        vm.prank(alice);
        vault.requestRedeem(40 * ONE, alice, alice);
        vm.prank(safe);
        vault.closeEpoch();
        _settle(2, 100 * ONE, 40 * ONE);

        vm.expectEmit(true, true, true, true);
        emit IERC4626.Withdraw(bob, bob, alice, 40 * ONE, 40 * ONE);

        vm.prank(bob);
        vault.redeem(40 * ONE, bob, alice);
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
        vm.expectRevert(abi.encodeWithSelector(EpochStagedERC7540Vault.SA__WrongEpoch.selector, uint256(1), uint256(2)));
        vault.settleEpoch(2, 0);

        _settle(1, 0, 0);

        vm.prank(safe);
        vm.expectRevert(EpochStagedERC7540Vault.SA__NoFrozenEpoch.selector);
        vault.settleEpoch(1, 0);

        _claimDeposit(alice, 100 * ONE);
        vm.prank(alice);
        vault.requestRedeem(1, alice, alice);
        vm.prank(safe);
        vault.closeEpoch();

        vm.prank(safe);
        vm.expectRevert(EpochStagedERC7540Vault.SA__InvalidNavSnapshot.selector);
        vault.settleEpoch(2, 0);
    }

    function test_claimValidationReverts() public {
        vm.startPrank(alice);
        vm.expectRevert(EpochStagedERC7540Vault.SA__NoClaimableEpoch.selector);
        vault.deposit(1, alice, alice);
        vm.expectRevert(EpochStagedERC7540Vault.SA__NoClaimableEpoch.selector);
        vault.mint(1, alice, alice);
        vm.expectRevert(EpochStagedERC7540Vault.SA__NoClaimableEpoch.selector);
        vault.withdraw(1, alice, alice);
        vm.expectRevert(EpochStagedERC7540Vault.SA__NoClaimableEpoch.selector);
        vault.redeem(1, alice, alice);
        vm.stopPrank();

        _requestDeposit(alice, 100 * ONE);
        vm.prank(safe);
        vault.closeEpoch();
        _settle(1, 0, 0);

        vm.prank(bob);
        vm.expectRevert(EpochStagedERC7540Vault.SA__NotAuthorized.selector);
        vault.deposit(1, bob, alice);
        vm.prank(bob);
        vm.expectRevert(EpochStagedERC7540Vault.SA__NotAuthorized.selector);
        vault.mint(1, bob, alice);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(EpochStagedERC7540Vault.SA__ExceedsClaimable.selector, 101 * ONE, 100 * ONE)
        );
        vault.deposit(101 * ONE, alice, alice);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(EpochStagedERC7540Vault.SA__ExceedsClaimable.selector, 101 * ONE, 100 * ONE)
        );
        vault.mint(101 * ONE, alice, alice);

        vm.prank(alice);
        vault.deposit(100 * ONE, alice, alice);
        vm.prank(alice);
        vault.requestRedeem(40 * ONE, alice, alice);
        vm.prank(safe);
        vault.closeEpoch();
        _settle(2, 100 * ONE, 40 * ONE);

        vm.prank(bob);
        vm.expectRevert(EpochStagedERC7540Vault.SA__NotAuthorized.selector);
        vault.withdraw(1, bob, alice);
        vm.prank(bob);
        vm.expectRevert(EpochStagedERC7540Vault.SA__NotAuthorized.selector);
        vault.redeem(1, bob, alice);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(EpochStagedERC7540Vault.SA__ExceedsClaimable.selector, 41 * ONE, 40 * ONE)
        );
        vault.withdraw(41 * ONE, alice, alice);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(EpochStagedERC7540Vault.SA__ExceedsClaimable.selector, 41 * ONE, 40 * ONE)
        );
        vault.redeem(41 * ONE, alice, alice);
    }

    function test_zeroRoundedClaimsCanBeSkippedAndQueueAdvances() public {
        _requestDeposit(alice, 2);
        vm.prank(safe);
        vault.closeEpoch();
        _settle(1, 0, 0);
        vm.prank(alice);
        vault.deposit(2, alice, alice);

        _requestDeposit(bob, 1);
        vm.prank(safe);
        vault.closeEpoch();
        _settle(2, 3, 0);

        assertEq(vault.maxDeposit(bob), 1, "asset claim exists");
        assertEq(vault.maxMint(bob), 0, "share claim rounds to zero");
        vm.prank(bob);
        assertEq(vault.deposit(1, bob, bob), 0, "zero-share deposit claim can be skipped");
        assertEq(vault.maxDeposit(bob), 0, "zero-share claim advances deposit queue");

        _requestDeposit(bob, 3);
        vm.prank(safe);
        vault.closeEpoch();
        _settle(3, 3, 0);
        assertEq(vault.maxDeposit(bob), 3, "later deposit epoch is reachable after skip");

        vm.prank(alice);
        vault.requestRedeem(1, alice, alice);
        vm.prank(safe);
        vault.closeEpoch();
        _settle(4, 1, 0);

        assertEq(vault.maxRedeem(alice), 1, "share claim exists");
        assertEq(vault.maxWithdraw(alice), 0, "asset claim rounds to zero");
        vm.prank(alice);
        assertEq(vault.redeem(1, alice, alice), 0, "zero-asset redeem claim can be skipped");
        assertEq(vault.maxRedeem(alice), 0, "zero-asset claim advances redeem queue");

        vm.prank(alice);
        vault.requestRedeem(1, alice, alice);
        vm.prank(safe);
        vault.closeEpoch();
        _settle(5, 3, 1);
        assertEq(vault.maxRedeem(alice), 1, "later redeem epoch is reachable after skip");
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
        vm.expectRevert(EpochStagedERC7540Vault.SA__InsufficientSettlementAssets.selector);
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

    function test_rescueStagedTokenOnlyAllowsUnrelatedTokens() public {
        ERC20Mock otherToken = new ERC20Mock();
        otherToken.mint(vault.staging(), 7 * ONE);

        vault.rescueStagedToken(address(otherToken), 7 * ONE);
        assertEq(otherToken.balanceOf(address(this)), 7 * ONE, "owner receives unrelated staged token");

        vm.expectRevert(abi.encodeWithSelector(SmartAccountWrapper.SA__ReservedStagedToken.selector, address(asset)));
        vault.rescueStagedToken(address(asset), 1);

        vm.expectRevert(abi.encodeWithSelector(SmartAccountWrapper.SA__ReservedStagedToken.selector, address(vault)));
        vault.rescueStagedToken(address(vault), 1);
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
        vm.expectRevert(EpochStagedERC7540Vault.SA__InsufficientSettlementAssets.selector);
        vault.settleEpoch(2, 100 * ONE);

        assertEq(vault.frozenEpochId(), 2, "underfunded settlement keeps epoch frozen for retry");
        _settle(2, 100 * ONE, 80 * ONE);
        assertEq(vault.frozenEpochId(), 0, "funded retry clears frozen epoch");
        assertEq(vault.maxRedeem(alice), 80 * ONE, "redeem remains claimable after funded retry");
    }

    function test_previewFunctionsRevertBecauseVaultIsFullyAsync() public {
        vm.expectRevert(EpochStagedERC7540Vault.SA__AsyncOnly.selector);
        vault.previewDeposit(1);
        vm.expectRevert(EpochStagedERC7540Vault.SA__AsyncOnly.selector);
        vault.previewMint(1);
        vm.expectRevert(EpochStagedERC7540Vault.SA__AsyncOnly.selector);
        vault.previewWithdraw(1);
        vm.expectRevert(EpochStagedERC7540Vault.SA__AsyncOnly.selector);
        vault.previewRedeem(1);
    }
}
