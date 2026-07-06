// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

import {DeployHelper} from "../script/utils/DeployHelper.sol";
import {SmartAccountWrapper} from "../src/SmartAccountWrapper.sol";

contract DepositInvariantHandler is Test {
    SmartAccountWrapper public vault;
    ERC20Mock public asset;
    address public safe;
    address[] public actors;

    uint256 public constant MAX_REQUEST = 1e21;

    constructor(SmartAccountWrapper vault_, ERC20Mock asset_, address safe_, address[] memory actors_) {
        vault = vault_;
        asset = asset_;
        safe = safe_;
        actors = actors_;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 index) external view returns (address) {
        return actors[index];
    }

    function requestDeposit(uint8 actorSeed, uint96 assets_) external {
        address actor = actors[actorSeed % actors.length];
        uint256 assets = bound(uint256(assets_), 1, MAX_REQUEST);

        vm.startPrank(actor);
        asset.approve(address(vault), assets);
        try vault.requestDeposit(assets, actor, actor) {} catch {}
        vm.stopPrank();
    }

    function closeAndSettle() external {
        if (vault.frozenEpochId() != 0) return;

        vm.startPrank(safe);
        try vault.closeEpoch() returns (uint40 epochId, uint40) {
            uint256 navSnapshot = vault.totalSupply() == 0 ? 0 : vault.totalAssets();
            try vault.settleEpoch(epochId, navSnapshot) {} catch {}
        } catch {}
        vm.stopPrank();
    }

    function claimDeposit(uint8 actorSeed, uint96 assets_) external {
        address actor = actors[actorSeed % actors.length];
        uint256 maxAssets = vault.maxDeposit(actor);
        if (maxAssets == 0) return;
        uint256 assets = bound(uint256(assets_), 1, maxAssets);

        vm.prank(actor);
        try vault.deposit(assets, actor, actor) {} catch {}
    }
}

contract EpochStagedERC7540InvariantTest is Test {
    SmartAccountWrapper public vault;
    ERC20Mock public asset;
    DepositInvariantHandler public handler;

    address public safe = makeAddr("safe");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public carol = makeAddr("carol");

    uint256 public constant STARTING_BALANCE = 1e30;

    function setUp() public {
        SmartAccountWrapper impl = new SmartAccountWrapper();
        asset = new ERC20Mock();
        address beacon = DeployHelper.deployBeacon(address(impl), address(this));
        vault = DeployHelper.deploySmartAccountWrapper(
            beacon, address(this), safe, address(asset), "Invariant Vault", "IV"
        );

        address[] memory actors = new address[](3);
        actors[0] = alice;
        actors[1] = bob;
        actors[2] = carol;

        for (uint256 i = 0; i < actors.length; i++) {
            asset.mint(actors[i], STARTING_BALANCE);
        }

        handler = new DepositInvariantHandler(vault, asset, safe, actors);
        targetContract(address(handler));
    }

    function invariant_depositOnlyShareSupplyIsConservedAcrossStagingAndControllers() public view {
        uint256 accountedShares = vault.balanceOf(vault.staging());
        uint256 count = handler.actorCount();
        for (uint256 i = 0; i < count; i++) {
            accountedShares += vault.balanceOf(handler.actorAt(i));
        }
        assertEq(accountedShares, vault.totalSupply(), "all deposit-only shares are in staging or controller balances");
    }

    function invariant_openEpochDepositsAreNeverClaimable() public view {
        uint256 currentEpoch = vault.currentEpochId();
        uint256 count = handler.actorCount();
        for (uint256 i = 0; i < count; i++) {
            address actor = handler.actorAt(i);
            if (vault.pendingDepositRequest(currentEpoch, actor) > 0) {
                assertEq(vault.claimableDepositRequest(currentEpoch, actor), 0, "open epoch deposit is not claimable");
            }
        }
    }
}
