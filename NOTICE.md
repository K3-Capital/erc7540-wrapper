# License Notice

This repository intentionally uses mixed licensing.

## BUSL-1.1 K3 code

The following K3-authored files are marked with `SPDX-License-Identifier: BUSL-1.1` and are governed by the Business Source License 1.1 terms in `LICENSE.md`, using the same license form used by Euler Vault Kit with K3-specific parameters:

- `src/EpochStagedERC7540Vault.sol`
- `src/IEpochStagedERC7540Vault.sol`
- `src/Staging.sol`
- `test/EpochStagedERC7540.t.sol`
- `test/EpochStagedERC7540Fuzz.t.sol`

The current public history may contain earlier versions of some of these files marked MIT. This notice is intended to govern new versions from the commit that introduces the `BUSL-1.1` headers onward, and does not attempt to revoke rights already granted for older MIT-marked public versions.

## MIT upstream-derived code

The following lightly modified upstream-derived Solidity and deployment helper files retain `SPDX-License-Identifier: MIT` and are governed by the MIT terms in `LICENSE-MIT.md`:

- `script/Deploy.s.sol`
- `script/Upgrade.s.sol`
- `script/utils/DeployHelper.sol`
- `src/SmartAccountWrapper.sol`

The MIT notice on those files applies to those files only. It does not grant rights to BUSL-1.1 files imported by, inherited by, compiled with, or deployed alongside them. Any production use of a combined work that includes BUSL-1.1 files requires compliance with the Business Source License in `LICENSE.md` and any separate written commercial license from K3 Capital.

## Third-party dependencies

Dependencies under `lib/` retain their own upstream licenses and notices, including OpenZeppelin, forge-std, and Solady. Review those dependency license files before redistributing third-party code.
