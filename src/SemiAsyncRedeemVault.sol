// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ISemiAsyncRedeemVault} from "./ISemiAsyncRedeemVault.sol";
import {Staging} from "./Staging.sol";

/// @notice Fully async ERC-7540 epoch vault base.
abstract contract SemiAsyncRedeemVault is Initializable, ERC4626Upgradeable, ISemiAsyncRedeemVault {
    using SafeERC20 for IERC20;
    using Math for uint256;

    struct EpochData {
        bool closed;
        bool settled;
        uint256 totalDepositAssets;
        uint256 totalRedeemShares;
        mapping(address controller => uint256 assets) depositAssets;
        mapping(address controller => uint256 shares) redeemShares;
    }

    struct DepositClaimData {
        uint256 assetsClaimed;
        uint256 sharesClaimed;
    }

    struct RedeemClaimData {
        uint256 sharesClaimed;
        uint256 assetsClaimed;
    }

    struct SettlementData {
        uint256 navSnapshot;
        uint256 totalSupplySnapshot;
        uint256 totalDepositAssets;
        uint256 totalRedeemShares;
        uint256 depositSharesMinted;
        uint256 redeemAssetsReserved;
    }

    /// @custom:storage-location erc7201:zyfai.storage.EpochAsyncVault
    struct SemiAsyncRedeemVaultStorage {
        uint40 currentEpochId;
        uint40 frozenEpochId;
        Staging staging;
        uint256 activeAssets;
        uint256 totalRedeemClaimReserves;
        mapping(uint40 epochId => EpochData) epochs;
        mapping(uint40 epochId => SettlementData) settlements;
        mapping(uint40 epochId => mapping(address controller => DepositClaimData)) depositClaims;
        mapping(uint40 epochId => mapping(address controller => RedeemClaimData)) redeemClaims;
        mapping(address controller => mapping(address operator => bool)) operators;
        mapping(address controller => uint40 epochId) firstDepositEpoch;
        mapping(address controller => uint40 epochId) lastDepositEpoch;
        mapping(address controller => mapping(uint40 epochId => uint40 nextEpochId)) nextDepositEpoch;
        mapping(address controller => uint40 epochId) firstRedeemEpoch;
        mapping(address controller => uint40 epochId) lastRedeemEpoch;
        mapping(address controller => mapping(uint40 epochId => uint40 nextEpochId)) nextRedeemEpoch;
    }

    // keccak256(abi.encode(uint256(keccak256("zyfai.storage.EpochAsyncVault")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant SEMI_ASYNC_REDEEM_VAULT_STORAGE_LOCATION =
        0xfeab585c10efbf3bb169b09d6b661509bec6d52c999594b33373cb626354d100;

    error SA__AsyncOnly();
    error SA__NotAuthorized();
    error SA__NotSmartAccount();
    error SA__SmartAccountNotSet();
    error SA__ZeroAddress();
    error SA__FrozenEpochPending();
    error SA__NoFrozenEpoch();
    error SA__WrongEpoch(uint256 expected, uint256 actual);
    error SA__EpochNotClosed(uint256 epochId);
    error SA__EpochAlreadySettled(uint256 epochId);
    error SA__InsufficientSettlementAssets();
    error SA__NoClaimableEpoch();
    error SA__ExceedsClaimable(uint256 requested, uint256 claimable);
    error SA__ZeroAmount();
    error SA__InvalidNavSnapshot();
    error SA__InvalidRequestId(uint256 requestId);

    function _getSemiAsyncRedeemVaultStorage() private pure returns (SemiAsyncRedeemVaultStorage storage $) {
        assembly {
            $.slot := SEMI_ASYNC_REDEEM_VAULT_STORAGE_LOCATION
        }
    }

    function __SemiAsyncRedeemVault_init() internal onlyInitializing {
        SemiAsyncRedeemVaultStorage storage $ = _getSemiAsyncRedeemVaultStorage();
        $.currentEpochId = 1;
        $.staging = new Staging(address(this));
    }

    modifier onlySmartAccount() virtual;

    /*//////////////////////////////////////////////////////////////
                              ERC-7540 OPS
    //////////////////////////////////////////////////////////////*/

    function setOperator(address operator, bool approved) external returns (bool) {
        _getSemiAsyncRedeemVaultStorage().operators[_msgSender()][operator] = approved;
        emit OperatorSet(_msgSender(), operator, approved);
        return true;
    }

    function isOperator(address controller, address operator) public view returns (bool status) {
        return _getSemiAsyncRedeemVaultStorage().operators[controller][operator];
    }

    function _isAuthorized(address caller, address controller) internal view returns (bool) {
        return caller == controller || isOperator(controller, caller);
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    function currentEpochId() public view returns (uint40) {
        return _getSemiAsyncRedeemVaultStorage().currentEpochId;
    }

    function frozenEpochId() public view returns (uint40) {
        return _getSemiAsyncRedeemVaultStorage().frozenEpochId;
    }

    function staging() public view returns (address) {
        return address(_getSemiAsyncRedeemVaultStorage().staging);
    }

    function totalAssets() public view override returns (uint256) {
        return _getSemiAsyncRedeemVaultStorage().activeAssets;
    }

    function redeemClaimReserves() public view returns (uint256) {
        return _getSemiAsyncRedeemVaultStorage().totalRedeemClaimReserves;
    }

    function assetSurplus() public view returns (uint256) {
        uint256 balance = IERC20(asset()).balanceOf(address(this));
        uint256 reserves = redeemClaimReserves();
        return balance > reserves ? balance - reserves : 0;
    }

    function pendingDepositRequest(uint256 requestId, address controller) external view returns (uint256) {
        SemiAsyncRedeemVaultStorage storage $ = _getSemiAsyncRedeemVaultStorage();
        EpochData storage epoch = $.epochs[_toEpochId(requestId)];
        if (epoch.settled) return 0;
        return epoch.depositAssets[controller];
    }

    function claimableDepositRequest(uint256 requestId, address controller) public view returns (uint256) {
        SemiAsyncRedeemVaultStorage storage $ = _getSemiAsyncRedeemVaultStorage();
        uint40 epochId = _toEpochId(requestId);
        EpochData storage epoch = $.epochs[epochId];
        if (!epoch.settled) return 0;
        DepositClaimData storage claim = $.depositClaims[epochId][controller];
        uint256 assets = epoch.depositAssets[controller];
        return assets - claim.assetsClaimed;
    }

    function pendingRedeemRequest(uint256 requestId, address controller) external view returns (uint256) {
        SemiAsyncRedeemVaultStorage storage $ = _getSemiAsyncRedeemVaultStorage();
        EpochData storage epoch = $.epochs[_toEpochId(requestId)];
        if (epoch.settled) return 0;
        return epoch.redeemShares[controller];
    }

    function claimableRedeemRequest(uint256 requestId, address controller) public view returns (uint256) {
        SemiAsyncRedeemVaultStorage storage $ = _getSemiAsyncRedeemVaultStorage();
        uint40 epochId = _toEpochId(requestId);
        EpochData storage epoch = $.epochs[epochId];
        if (!epoch.settled) return 0;
        RedeemClaimData storage claim = $.redeemClaims[epochId][controller];
        uint256 shares = epoch.redeemShares[controller];
        return shares - claim.sharesClaimed;
    }

    function share() external view returns (address) {
        return address(this);
    }

    function maxDeposit(address controller) public view override returns (uint256) {
        if (_claimsPaused()) return 0;
        uint40 epochId = _oldestDepositClaimEpoch(controller);
        if (epochId == 0) return 0;
        return claimableDepositRequest(epochId, controller);
    }

    function maxMint(address controller) public view override returns (uint256) {
        if (_claimsPaused()) return 0;
        uint40 epochId = _oldestDepositClaimEpoch(controller);
        if (epochId == 0) return 0;
        return _remainingDepositShares(_getSemiAsyncRedeemVaultStorage(), epochId, controller);
    }

    function maxWithdraw(address controller) public view override returns (uint256) {
        if (_claimsPaused()) return 0;
        uint40 epochId = _oldestRedeemClaimEpoch(controller);
        if (epochId == 0) return 0;
        return _remainingRedeemAssets(_getSemiAsyncRedeemVaultStorage(), epochId, controller);
    }

    function maxRedeem(address controller) public view override returns (uint256) {
        if (_claimsPaused()) return 0;
        uint40 epochId = _oldestRedeemClaimEpoch(controller);
        if (epochId == 0) return 0;
        return claimableRedeemRequest(epochId, controller);
    }

    function previewDeposit(uint256) public view override returns (uint256) {
        return _asyncPreviewRevert();
    }

    function previewMint(uint256) public view override returns (uint256) {
        return _asyncPreviewRevert();
    }

    function previewWithdraw(uint256) public view override returns (uint256) {
        return _asyncPreviewRevert();
    }

    function previewRedeem(uint256) public view override returns (uint256) {
        return _asyncPreviewRevert();
    }

    function _asyncPreviewRevert() internal view returns (uint256) {
        if (gasleft() == type(uint256).max) return 0;
        revert SA__AsyncOnly();
    }

    function _claimsPaused() internal view virtual returns (bool) {
        return false;
    }

    function _toEpochId(uint256 requestId) internal pure returns (uint40) {
        if (requestId > type(uint40).max) revert SA__InvalidRequestId(requestId);
        uint40 epochId;
        assembly {
            epochId := requestId
        }
        return epochId;
    }

    /*//////////////////////////////////////////////////////////////
                                 REQUESTS
    //////////////////////////////////////////////////////////////*/

    function requestDeposit(uint256 assets, address controller, address owner) public virtual returns (uint256 requestId) {
        if (assets == 0) revert SA__ZeroAmount();
        if (controller == address(0) || owner == address(0)) revert SA__ZeroAddress();
        address caller = _msgSender();
        if (caller != owner && !isOperator(owner, caller)) revert SA__NotAuthorized();

        SemiAsyncRedeemVaultStorage storage $ = _getSemiAsyncRedeemVaultStorage();
        uint40 epochId = $.currentEpochId;
        requestId = epochId;
        EpochData storage epoch = $.epochs[epochId];

        uint256 beforeBalance = IERC20(asset()).balanceOf(address($.staging));
        IERC20(asset()).safeTransferFrom(owner, address($.staging), assets);
        uint256 received = IERC20(asset()).balanceOf(address($.staging)) - beforeBalance;
        if (received == 0) revert SA__ZeroAmount();

        if (epoch.depositAssets[controller] == 0) _pushDepositEpoch($, controller, epochId);
        epoch.depositAssets[controller] += received;
        epoch.totalDepositAssets += received;

        emit DepositRequest(controller, owner, requestId, caller, received);
    }

    function requestRedeem(uint256 shares, address controller, address owner) public virtual returns (uint256 requestId) {
        if (shares == 0) revert SA__ZeroAmount();
        if (controller == address(0) || owner == address(0)) revert SA__ZeroAddress();
        address caller = _msgSender();
        if (caller != owner) _spendAllowance(owner, caller, shares);

        SemiAsyncRedeemVaultStorage storage $ = _getSemiAsyncRedeemVaultStorage();
        uint40 epochId = $.currentEpochId;
        requestId = epochId;
        EpochData storage epoch = $.epochs[epochId];

        _transfer(owner, address($.staging), shares);

        if (epoch.redeemShares[controller] == 0) _pushRedeemEpoch($, controller, epochId);
        epoch.redeemShares[controller] += shares;
        epoch.totalRedeemShares += shares;

        emit RedeemRequest(controller, owner, requestId, caller, shares);
    }

    function _pushDepositEpoch(SemiAsyncRedeemVaultStorage storage $, address controller, uint40 epochId) internal {
        uint40 last = $.lastDepositEpoch[controller];
        if (last == epochId) return;
        if ($.firstDepositEpoch[controller] == 0) {
            $.firstDepositEpoch[controller] = epochId;
        } else {
            $.nextDepositEpoch[controller][last] = epochId;
        }
        $.lastDepositEpoch[controller] = epochId;
    }

    function _pushRedeemEpoch(SemiAsyncRedeemVaultStorage storage $, address controller, uint40 epochId) internal {
        uint40 last = $.lastRedeemEpoch[controller];
        if (last == epochId) return;
        if ($.firstRedeemEpoch[controller] == 0) {
            $.firstRedeemEpoch[controller] = epochId;
        } else {
            $.nextRedeemEpoch[controller][last] = epochId;
        }
        $.lastRedeemEpoch[controller] = epochId;
    }

    /*//////////////////////////////////////////////////////////////
                              EPOCH SETTLEMENT
    //////////////////////////////////////////////////////////////*/

    function closeEpoch() public virtual onlySmartAccount returns (uint40 closedEpochId, uint40 nextEpochId) {
        SemiAsyncRedeemVaultStorage storage $ = _getSemiAsyncRedeemVaultStorage();
        if ($.frozenEpochId != 0) revert SA__FrozenEpochPending();

        closedEpochId = $.currentEpochId;
        EpochData storage epoch = $.epochs[closedEpochId];
        epoch.closed = true;
        $.frozenEpochId = closedEpochId;
        nextEpochId = closedEpochId + 1;
        $.currentEpochId = nextEpochId;

        emit EpochClosed(closedEpochId, nextEpochId, epoch.totalDepositAssets, epoch.totalRedeemShares);
    }

    function settleEpoch(uint40 epochId, uint256 navSnapshot) public virtual onlySmartAccount {
        SemiAsyncRedeemVaultStorage storage $ = _getSemiAsyncRedeemVaultStorage();
        if ($.frozenEpochId == 0) revert SA__NoFrozenEpoch();
        if (epochId != $.frozenEpochId) revert SA__WrongEpoch($.frozenEpochId, epochId);

        EpochData storage epoch = $.epochs[epochId];
        if (!epoch.closed) revert SA__EpochNotClosed(epochId);
        if (epoch.settled) revert SA__EpochAlreadySettled(epochId);

        uint256 supplySnapshot = totalSupply();
        if (supplySnapshot != 0 && navSnapshot == 0) revert SA__InvalidNavSnapshot();
        if (epoch.totalRedeemShares > supplySnapshot) revert SA__InvalidNavSnapshot();

        (uint256 depositShares, uint256 redeemAssets) =
            _settlementAmounts(navSnapshot, supplySnapshot, epoch.totalDepositAssets, epoch.totalRedeemShares);

        if (epoch.totalDepositAssets > 0) {
            $.staging.transferToken(asset(), address(this), epoch.totalDepositAssets);
        }

        uint256 unreservedBalance = IERC20(asset()).balanceOf(address(this)) - $.totalRedeemClaimReserves;
        if (unreservedBalance < redeemAssets) revert SA__InsufficientSettlementAssets();

        if (epoch.totalRedeemShares > 0) {
            _burn(address($.staging), epoch.totalRedeemShares);
        }
        if (depositShares > 0) {
            _mint(address($.staging), depositShares);
        }

        $.totalRedeemClaimReserves += redeemAssets;
        $.settlements[epochId] = SettlementData({
            navSnapshot: navSnapshot,
            totalSupplySnapshot: supplySnapshot,
            totalDepositAssets: epoch.totalDepositAssets,
            totalRedeemShares: epoch.totalRedeemShares,
            depositSharesMinted: depositShares,
            redeemAssetsReserved: redeemAssets
        });

        $.activeAssets = navSnapshot + epoch.totalDepositAssets - redeemAssets;
        epoch.settled = true;
        $.frozenEpochId = 0;

        uint256 surplus = IERC20(asset()).balanceOf(address(this)) - $.totalRedeemClaimReserves;
        if (surplus > 0) IERC20(asset()).safeTransfer(_smartAccount(), surplus);

        emit EpochSettled(
            epochId,
            navSnapshot,
            supplySnapshot,
            epoch.totalDepositAssets,
            epoch.totalRedeemShares,
            depositShares,
            redeemAssets
        );
    }

    function _settlementAmounts(uint256 navSnapshot, uint256 supplySnapshot, uint256 depositAssets, uint256 redeemShares)
        internal
        pure
        returns (uint256 depositShares, uint256 redeemAssets)
    {
        if (supplySnapshot == 0) {
            if (redeemShares != 0) revert SA__InvalidNavSnapshot();
            return (depositAssets, 0);
        }
        depositShares = depositAssets == 0 ? 0 : depositAssets.mulDiv(supplySnapshot, navSnapshot, Math.Rounding.Floor);
        redeemAssets = redeemShares == 0 ? 0 : redeemShares.mulDiv(navSnapshot, supplySnapshot, Math.Rounding.Floor);
    }

    /*//////////////////////////////////////////////////////////////
                                  CLAIMS
    //////////////////////////////////////////////////////////////*/

    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        return deposit(assets, receiver, _msgSender());
    }

    function deposit(uint256 assets, address receiver, address controller) public virtual returns (uint256 shares) {
        if (!_isAuthorized(_msgSender(), controller)) revert SA__NotAuthorized();
        SemiAsyncRedeemVaultStorage storage $ = _getSemiAsyncRedeemVaultStorage();
        uint40 epochId = _oldestDepositClaimEpoch(controller);
        if (epochId == 0) revert SA__NoClaimableEpoch();
        DepositClaimData storage claim = $.depositClaims[epochId][controller];
        uint256 remainingAssets = $.epochs[epochId].depositAssets[controller] - claim.assetsClaimed;
        uint256 remainingShares = _remainingDepositShares($, epochId, controller);
        if (assets > remainingAssets) revert SA__ExceedsClaimable(assets, remainingAssets);
        shares = assets == remainingAssets ? remainingShares : assets.mulDiv(remainingShares, remainingAssets, Math.Rounding.Floor);
        _consumeDepositClaim($, epochId, controller, claim, receiver, assets, shares);
    }

    function mint(uint256 shares, address receiver) public override returns (uint256) {
        return mint(shares, receiver, _msgSender());
    }

    function mint(uint256 shares, address receiver, address controller) public virtual returns (uint256 assets) {
        if (!_isAuthorized(_msgSender(), controller)) revert SA__NotAuthorized();
        SemiAsyncRedeemVaultStorage storage $ = _getSemiAsyncRedeemVaultStorage();
        uint40 epochId = _oldestDepositClaimEpoch(controller);
        if (epochId == 0) revert SA__NoClaimableEpoch();
        DepositClaimData storage claim = $.depositClaims[epochId][controller];
        uint256 remainingAssets = $.epochs[epochId].depositAssets[controller] - claim.assetsClaimed;
        uint256 remainingShares = _remainingDepositShares($, epochId, controller);
        if (shares > remainingShares) revert SA__ExceedsClaimable(shares, remainingShares);
        assets = shares == remainingShares ? remainingAssets : shares.mulDiv(remainingAssets, remainingShares, Math.Rounding.Ceil);
        _consumeDepositClaim($, epochId, controller, claim, receiver, assets, shares);
    }

    function _consumeDepositClaim(
        SemiAsyncRedeemVaultStorage storage $,
        uint40 epochId,
        address controller,
        DepositClaimData storage claim,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal {
        if (assets == 0 || shares == 0) revert SA__ZeroAmount();
        claim.assetsClaimed += assets;
        claim.sharesClaimed += shares;
        _transfer(staging(), receiver, shares);
        if (claim.assetsClaimed == $.epochs[epochId].depositAssets[controller] || _remainingDepositShares($, epochId, controller) == 0) {
            _advanceDepositEpoch($, controller, epochId);
        }
        emit Deposit(_msgSender(), receiver, assets, shares);
    }

    function withdraw(uint256 assets, address receiver, address controller)
        public
        override
        returns (uint256 shares)
    {
        if (!_isAuthorized(_msgSender(), controller)) revert SA__NotAuthorized();
        SemiAsyncRedeemVaultStorage storage $ = _getSemiAsyncRedeemVaultStorage();
        uint40 epochId = _oldestRedeemClaimEpoch(controller);
        if (epochId == 0) revert SA__NoClaimableEpoch();
        RedeemClaimData storage claim = $.redeemClaims[epochId][controller];
        uint256 remainingAssets = _remainingRedeemAssets($, epochId, controller);
        uint256 remainingShares = $.epochs[epochId].redeemShares[controller] - claim.sharesClaimed;
        if (assets > remainingAssets) revert SA__ExceedsClaimable(assets, remainingAssets);
        shares = assets == remainingAssets ? remainingShares : assets.mulDiv(remainingShares, remainingAssets, Math.Rounding.Ceil);
        _consumeRedeemClaim($, epochId, controller, claim, receiver, assets, shares);
    }

    function redeem(uint256 shares, address receiver, address controller)
        public
        override
        returns (uint256 assets)
    {
        if (!_isAuthorized(_msgSender(), controller)) revert SA__NotAuthorized();
        SemiAsyncRedeemVaultStorage storage $ = _getSemiAsyncRedeemVaultStorage();
        uint40 epochId = _oldestRedeemClaimEpoch(controller);
        if (epochId == 0) revert SA__NoClaimableEpoch();
        RedeemClaimData storage claim = $.redeemClaims[epochId][controller];
        uint256 remainingAssets = _remainingRedeemAssets($, epochId, controller);
        uint256 remainingShares = $.epochs[epochId].redeemShares[controller] - claim.sharesClaimed;
        if (shares > remainingShares) revert SA__ExceedsClaimable(shares, remainingShares);
        assets = shares == remainingShares ? remainingAssets : shares.mulDiv(remainingAssets, remainingShares, Math.Rounding.Floor);
        _consumeRedeemClaim($, epochId, controller, claim, receiver, assets, shares);
    }

    function _consumeRedeemClaim(
        SemiAsyncRedeemVaultStorage storage $,
        uint40 epochId,
        address controller,
        RedeemClaimData storage claim,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal {
        if (assets == 0 || shares == 0) revert SA__ZeroAmount();
        claim.assetsClaimed += assets;
        claim.sharesClaimed += shares;
        $.totalRedeemClaimReserves -= assets;
        IERC20(asset()).safeTransfer(receiver, assets);
        if (claim.sharesClaimed == $.epochs[epochId].redeemShares[controller] || _remainingRedeemAssets($, epochId, controller) == 0) {
            _advanceRedeemEpoch($, controller, epochId);
        }
        emit Withdraw(_msgSender(), receiver, _msgSender(), assets, shares);
    }

    function _remainingDepositShares(SemiAsyncRedeemVaultStorage storage $, uint40 epochId, address controller)
        internal
        view
        returns (uint256)
    {
        EpochData storage epoch = $.epochs[epochId];
        SettlementData storage settlement = $.settlements[epochId];
        DepositClaimData storage claim = $.depositClaims[epochId][controller];
        uint256 assets = epoch.depositAssets[controller];
        uint256 totalShares = epoch.totalDepositAssets == 0
            ? 0
            : assets.mulDiv(settlement.depositSharesMinted, epoch.totalDepositAssets, Math.Rounding.Floor);
        return totalShares - claim.sharesClaimed;
    }

    function _remainingRedeemAssets(SemiAsyncRedeemVaultStorage storage $, uint40 epochId, address controller)
        internal
        view
        returns (uint256)
    {
        EpochData storage epoch = $.epochs[epochId];
        SettlementData storage settlement = $.settlements[epochId];
        RedeemClaimData storage claim = $.redeemClaims[epochId][controller];
        uint256 shares = epoch.redeemShares[controller];
        uint256 totalClaimAssets = epoch.totalRedeemShares == 0
            ? 0
            : shares.mulDiv(settlement.redeemAssetsReserved, epoch.totalRedeemShares, Math.Rounding.Floor);
        return totalClaimAssets - claim.assetsClaimed;
    }

    function _oldestDepositClaimEpoch(address controller) internal view returns (uint40) {
        SemiAsyncRedeemVaultStorage storage $ = _getSemiAsyncRedeemVaultStorage();
        uint40 epochId = $.firstDepositEpoch[controller];
        if (epochId == 0 || !$.epochs[epochId].settled) return 0;
        return epochId;
    }

    function _oldestRedeemClaimEpoch(address controller) internal view returns (uint40) {
        SemiAsyncRedeemVaultStorage storage $ = _getSemiAsyncRedeemVaultStorage();
        uint40 epochId = $.firstRedeemEpoch[controller];
        if (epochId == 0 || !$.epochs[epochId].settled) return 0;
        return epochId;
    }

    function _advanceDepositEpoch(SemiAsyncRedeemVaultStorage storage $, address controller, uint40 epochId) internal {
        if ($.firstDepositEpoch[controller] != epochId) return;
        uint40 next = $.nextDepositEpoch[controller][epochId];
        $.firstDepositEpoch[controller] = next;
        if (next == 0) $.lastDepositEpoch[controller] = 0;
    }

    function _advanceRedeemEpoch(SemiAsyncRedeemVaultStorage storage $, address controller, uint40 epochId) internal {
        if ($.firstRedeemEpoch[controller] != epochId) return;
        uint40 next = $.nextRedeemEpoch[controller][epochId];
        $.firstRedeemEpoch[controller] = next;
        if (next == 0) $.lastRedeemEpoch[controller] = 0;
    }

    function _smartAccount() internal view virtual returns (address);
}
