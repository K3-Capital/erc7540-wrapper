// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {IERC7540, IERC7540Deposit, IERC7540Redeem, IERC7540Operator} from "forge-std/interfaces/IERC7540.sol";
import {IERC7575} from "forge-std/interfaces/IERC7575.sol";

import {EpochStagedERC7540Vault} from "./EpochStagedERC7540Vault.sol";

contract SmartAccountWrapper is
    Initializable,
    Ownable2StepUpgradeable,
    PausableUpgradeable,
    EpochStagedERC7540Vault,
    IERC1271
{
    using SafeERC20 for IERC20;

    bytes4 private constant ERC1271_MAGIC_VALUE = 0x1626ba7e;
    bytes4 private constant ERC1271_INVALID = 0xffffffff;

    event SmartAccountSet(address smartAccount);

    /// @custom:storage-location erc7201:zyfai.storage.SmartAccountWrapper
    struct SmartAccountWrapperStorage {
        address smartAccount;
    }

    // keccak256(abi.encode(uint256(keccak256("zyfai.storage.SmartAccountWrapper")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant SMART_ACCOUNT_WRAPPER_STORAGE_LOCATION =
        0x0b4df025537faa360009ab68a91bc7272fab48607bc6e74d5be7ac40332a8400;

    function _getSmartAccountWrapperStorage() private pure returns (SmartAccountWrapperStorage storage $) {
        assembly {
            $.slot := SMART_ACCOUNT_WRAPPER_STORAGE_LOCATION
        }
    }

    modifier onlySmartAccount() override {
        _checkSmartAccount();
        _;
    }

    function _checkSmartAccount() internal view {
        address account = smartAccount();
        if (account == address(0)) revert SA__SmartAccountNotSet();
        if (account != _msgSender()) revert SA__NotSmartAccount();
    }

    function initialize(
        address owner_,
        address smartAccount_,
        address underlyingToken_,
        string memory name_,
        string memory symbol_
    ) public initializer {
        if (owner_ == address(0) || smartAccount_ == address(0) || underlyingToken_ == address(0)) {
            revert SA__ZeroAddress();
        }
        __Ownable_init(owner_);
        __Pausable_init();
        __ERC20_init_unchained(name_, symbol_);
        __ERC4626_init_unchained(IERC20(underlyingToken_));
        __EpochStagedERC7540Vault_init();
        _getSmartAccountWrapperStorage().smartAccount = smartAccount_;
        emit SmartAccountSet(smartAccount_);
    }

    function requestDeposit(uint256 assets, address controller, address owner)
        public
        override
        whenNotPaused
        returns (uint256 requestId)
    {
        return super.requestDeposit(assets, controller, owner);
    }

    function requestRedeem(uint256 shares, address controller, address owner)
        public
        override
        whenNotPaused
        returns (uint256 requestId)
    {
        return super.requestRedeem(shares, controller, owner);
    }

    function closeEpoch() public override onlySmartAccount returns (uint40 closedEpochId, uint40 nextEpochId) {
        return super.closeEpoch();
    }

    function settleEpoch(uint40 epochId, uint256 navSnapshot) public override onlySmartAccount {
        super.settleEpoch(epochId, navSnapshot);
    }

    function pause() public onlyOwner {
        _pause();
    }

    function unpause() public onlyOwner {
        _unpause();
    }

    function setSmartAccount(address smartAccount_) public onlyOwner {
        if (smartAccount_ == address(0)) revert SA__ZeroAddress();
        _getSmartAccountWrapperStorage().smartAccount = smartAccount_;
        emit SmartAccountSet(smartAccount_);
    }

    function smartAccount() public view returns (address) {
        return _getSmartAccountWrapperStorage().smartAccount;
    }

    function _smartAccount() internal view override returns (address) {
        return smartAccount();
    }

    function _claimsPaused() internal view override returns (bool) {
        return paused();
    }

    function rescue(address token, uint256 amount) external onlyOwner {
        if (token == asset()) {
            if (amount > assetSurplus()) revert SA__InsufficientSettlementAssets();
            IERC20(token).safeTransfer(smartAccount(), amount);
            return;
        }
        IERC20(token).safeTransfer(owner(), amount);
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view override returns (bytes4) {
        if (SignatureChecker.isValidSignatureNow(owner(), hash, signature)) {
            return ERC1271_MAGIC_VALUE;
        }
        return ERC1271_INVALID;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == type(IERC7540).interfaceId
            || interfaceId == type(IERC7540Deposit).interfaceId || interfaceId == type(IERC7540Redeem).interfaceId
            || interfaceId == type(IERC7540Operator).interfaceId || interfaceId == type(IERC7575).interfaceId;
    }
}
