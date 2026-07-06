// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Narrow custody helper for staged request assets and shares.
contract Staging {
    using SafeERC20 for IERC20;

    address public immutable vault;

    error ST__NotVault();

    constructor(address vault_) {
        vault = vault_;
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert ST__NotVault();
        _;
    }

    function transferToken(address token, address to, uint256 amount) external onlyVault {
        IERC20(token).safeTransfer(to, amount);
    }
}
