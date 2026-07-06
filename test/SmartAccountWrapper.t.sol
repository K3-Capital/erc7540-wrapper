// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC7540, IERC7540Deposit, IERC7540Operator, IERC7540Redeem} from "forge-std/interfaces/IERC7540.sol";
import {IERC7575} from "forge-std/interfaces/IERC7575.sol";

import {DeployHelper} from "../script/utils/DeployHelper.sol";
import {SmartAccountWrapper} from "../src/SmartAccountWrapper.sol";
import {EpochStagedERC7540Vault} from "../src/EpochStagedERC7540Vault.sol";

contract MockERC1271Wallet is IERC1271 {
    bytes4 private constant ERC1271_MAGIC = 0x1626ba7e;
    bytes4 private constant ERC1271_INVALID = 0xffffffff;

    mapping(address => bool) public owners;
    uint256 public threshold;

    constructor(address[] memory _owners, uint256 _threshold) {
        require(_threshold <= _owners.length, "threshold too high");
        for (uint256 i = 0; i < _owners.length; i++) {
            owners[_owners[i]] = true;
        }
        threshold = _threshold;
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view override returns (bytes4) {
        uint256 sigCount = signature.length / 65;
        if (sigCount < threshold) return ERC1271_INVALID;
        uint256 validSigs;
        for (uint256 i = 0; i < sigCount; i++) {
            bytes memory sig = signature[i * 65:(i + 1) * 65];
            if (owners[ECDSA.recover(hash, sig)]) validSigs++;
        }
        return validSigs >= threshold ? ERC1271_MAGIC : ERC1271_INVALID;
    }
}

contract SmartAccountWrapperTest is Test {
    SmartAccountWrapper public vault;
    ERC20Mock public asset;
    address safe = makeAddr("safe");
    address user = makeAddr("user");
    address pauser = makeAddr("pauser");

    uint256 constant OWNER_PRIVATE_KEY = 0xA11CE;
    uint256 constant WRONG_PRIVATE_KEY = 0xB0B;
    uint256 constant OWNER1_KEY = 0x1111;
    uint256 constant OWNER2_KEY = 0x2222;
    uint256 constant OWNER3_KEY = 0x3333;
    uint256 constant NON_OWNER_KEY = 0x9999;
    bytes4 constant ERC1271_MAGIC_VALUE = 0x1626ba7e;
    bytes4 constant ERC1271_INVALID = 0xffffffff;

    function setUp() public {
        SmartAccountWrapper impl = new SmartAccountWrapper();
        asset = new ERC20Mock();
        address beacon = DeployHelper.deployBeacon(address(impl), address(this));
        vault = DeployHelper.deploySmartAccountWrapper(
            beacon, address(this), safe, address(asset), "SmartAccountWrapper", "SAW"
        );
        asset.mint(user, 1_000_000e18);
    }

    function test_deploy() public view {
        assertEq(vault.smartAccount(), safe);
        assertEq(vault.asset(), address(asset));
        assertEq(vault.name(), "SmartAccountWrapper");
        assertEq(vault.symbol(), "SAW");
        assertEq(vault.currentEpochId(), 1);
        assertTrue(vault.staging() != address(0));
    }

    function test_uninitializedImplementationRejectsSafeOnlyCalls() public {
        SmartAccountWrapper impl = new SmartAccountWrapper();
        vm.expectRevert(EpochStagedERC7540Vault.SA__SmartAccountNotSet.selector);
        impl.closeEpoch();
    }

    function test_initializeRejectsZeroAddresses() public {
        SmartAccountWrapper impl = new SmartAccountWrapper();

        vm.expectRevert(EpochStagedERC7540Vault.SA__ZeroAddress.selector);
        impl.initialize(address(0), safe, address(asset), "SmartAccountWrapper", "SAW");

        impl = new SmartAccountWrapper();
        vm.expectRevert(EpochStagedERC7540Vault.SA__ZeroAddress.selector);
        impl.initialize(address(this), address(0), address(asset), "SmartAccountWrapper", "SAW");

        impl = new SmartAccountWrapper();
        vm.expectRevert(EpochStagedERC7540Vault.SA__ZeroAddress.selector);
        impl.initialize(address(this), safe, address(0), "SmartAccountWrapper", "SAW");
    }

    function test_onlySafeCanCloseAndSettle() public {
        vm.prank(user);
        vm.expectRevert(EpochStagedERC7540Vault.SA__NotSmartAccount.selector);
        vault.closeEpoch();

        vm.prank(safe);
        vault.closeEpoch();

        vm.prank(user);
        vm.expectRevert(EpochStagedERC7540Vault.SA__NotSmartAccount.selector);
        vault.settleEpoch(1, 0);
    }

    function test_pauseBlocksRequestsButNotClaims() public {
        vault.pause();
        vm.startPrank(user);
        asset.approve(address(vault), 100e18);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vault.requestDeposit(100e18, user, user);
        vm.stopPrank();

        vault.unpause();
        vm.startPrank(user);
        vault.requestDeposit(100e18, user, user);
        vm.stopPrank();
        vm.prank(safe);
        vault.closeEpoch();
        vm.prank(safe);
        vault.settleEpoch(1, 0);

        vault.pause();
        vm.prank(user);
        vault.deposit(100e18, user, user);
        assertEq(vault.balanceOf(user), 100e18);
    }

    function test_twoStepOwnershipTransfer() public {
        address newOwner = makeAddr("newOwner");
        vault.transferOwnership(newOwner);
        assertEq(vault.owner(), address(this));
        assertEq(vault.pendingOwner(), newOwner);
        vm.prank(newOwner);
        vault.acceptOwnership();
        assertEq(vault.owner(), newOwner);
    }

    function test_pendingOwnerCannotActAsOwner() public {
        address newOwner = makeAddr("newOwner");
        bytes32 pauserRole = vault.PAUSER_ROLE();
        vault.transferOwnership(newOwner);
        vm.prank(newOwner);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, newOwner, pauserRole)
        );
        vault.pause();
    }

    function test_ownerIsRoleAdminAndCanGrantPauserRole() public {
        bytes32 pauserRole = vault.PAUSER_ROLE();

        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), address(this)), "owner is admin");
        assertEq(vault.getRoleAdmin(pauserRole), vault.DEFAULT_ADMIN_ROLE(), "owner-admin controls pauser role");

        vault.grantRole(pauserRole, pauser);
        assertTrue(vault.hasRole(pauserRole, pauser), "pauser role granted");

        vm.prank(pauser);
        vault.pause();
        assertTrue(vault.paused(), "pauser can pause");

        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, pauserRole));
        vm.prank(user);
        vault.pause();

        vault.revokeRole(pauserRole, pauser);
        vault.unpause();

        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, pauser, pauserRole));
        vm.prank(pauser);
        vault.pause();
    }

    function test_pauserRoleCannotPerformOtherAdminOperations() public {
        bytes32 pauserRole = vault.PAUSER_ROLE();
        vault.grantRole(pauserRole, pauser);

        vm.startPrank(pauser);

        vault.pause();

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, pauser));
        vault.unpause();

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, pauser));
        vault.setSmartAccount(makeAddr("newSafe"));

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, pauser, vault.DEFAULT_ADMIN_ROLE())
        );
        vault.grantRole(pauserRole, user);

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, pauser));
        vault.rescue(address(asset), 0);

        vm.stopPrank();
    }

    function test_setSmartAccount_onlyOwnerAndRejectsZeroAddress() public {
        address newSafe = makeAddr("newSafe");

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user));
        vault.setSmartAccount(newSafe);

        vm.expectRevert(EpochStagedERC7540Vault.SA__ZeroAddress.selector);
        vault.setSmartAccount(address(0));

        vm.expectEmit(false, false, false, true);
        emit SmartAccountWrapper.SmartAccountSet(newSafe);
        vault.setSmartAccount(newSafe);
        assertEq(vault.smartAccount(), newSafe);
    }

    function test_rescueUnrelatedTokenHeldByVaultSendsToOwner() public {
        ERC20Mock otherToken = new ERC20Mock();
        otherToken.mint(address(vault), 7e18);

        vault.rescue(address(otherToken), 7e18);

        assertEq(otherToken.balanceOf(address(this)), 7e18);
        assertEq(otherToken.balanceOf(address(vault)), 0);
    }

    function test_supportsDeclaredInterfacesOnly() public view {
        assertTrue(vault.supportsInterface(type(IERC165).interfaceId));
        assertTrue(vault.supportsInterface(type(IERC1271).interfaceId));
        assertTrue(vault.supportsInterface(type(IERC7540).interfaceId));
        assertTrue(vault.supportsInterface(type(IERC7540Deposit).interfaceId));
        assertTrue(vault.supportsInterface(type(IERC7540Redeem).interfaceId));
        assertTrue(vault.supportsInterface(type(IERC7540Operator).interfaceId));
        assertTrue(vault.supportsInterface(type(IERC7575).interfaceId));
        assertFalse(vault.supportsInterface(0xffffffff));
    }

    function _deployWithEOAOwner(uint256 privateKey) internal returns (SmartAccountWrapper wrapper, address eoaOwner) {
        eoaOwner = vm.addr(privateKey);
        SmartAccountWrapper impl = new SmartAccountWrapper();
        address beacon = DeployHelper.deployBeacon(address(impl), address(this));
        wrapper = DeployHelper.deploySmartAccountWrapper(
            beacon, eoaOwner, safe, address(asset), "SmartAccountWrapper", "SAW"
        );
    }

    function test_isValidSignature_EOA_ValidSignature() public {
        (SmartAccountWrapper wrapper,) = _deployWithEOAOwner(OWNER_PRIVATE_KEY);
        bytes32 hash = keccak256("test message");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_PRIVATE_KEY, hash);
        assertEq(wrapper.isValidSignature(hash, abi.encodePacked(r, s, v)), ERC1271_MAGIC_VALUE);
    }

    function test_isValidSignature_EOA_WrongSigner() public {
        (SmartAccountWrapper wrapper,) = _deployWithEOAOwner(OWNER_PRIVATE_KEY);
        bytes32 hash = keccak256("test message");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(WRONG_PRIVATE_KEY, hash);
        assertEq(wrapper.isValidSignature(hash, abi.encodePacked(r, s, v)), ERC1271_INVALID);
    }

    function _deployWithContractOwner(uint256 threshold) internal returns (SmartAccountWrapper wrapper) {
        address[] memory owners = new address[](3);
        owners[0] = vm.addr(OWNER1_KEY);
        owners[1] = vm.addr(OWNER2_KEY);
        owners[2] = vm.addr(OWNER3_KEY);
        MockERC1271Wallet wallet = new MockERC1271Wallet(owners, threshold);
        SmartAccountWrapper impl = new SmartAccountWrapper();
        address beacon = DeployHelper.deployBeacon(address(impl), address(this));
        wrapper = DeployHelper.deploySmartAccountWrapper(
            beacon, address(wallet), safe, address(asset), "SmartAccountWrapper", "SAW"
        );
    }

    function _sign(uint256 privateKey, bytes32 hash) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, hash);
        return abi.encodePacked(r, s, v);
    }

    function test_isValidSignature_Contract_ValidSignature_2of3() public {
        SmartAccountWrapper wrapper = _deployWithContractOwner(2);
        bytes32 hash = keccak256("test message");
        bytes memory signatures = abi.encodePacked(_sign(OWNER1_KEY, hash), _sign(OWNER2_KEY, hash));
        assertEq(wrapper.isValidSignature(hash, signatures), ERC1271_MAGIC_VALUE);
    }

    function test_isValidSignature_Contract_NonOwnerSignatures() public {
        SmartAccountWrapper wrapper = _deployWithContractOwner(2);
        bytes32 hash = keccak256("test message");
        bytes memory signatures = abi.encodePacked(_sign(NON_OWNER_KEY, hash), _sign(WRONG_PRIVATE_KEY, hash));
        assertEq(wrapper.isValidSignature(hash, signatures), ERC1271_INVALID);
    }
}
