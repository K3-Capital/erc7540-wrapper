# License Notice

This repository intentionally uses mixed licensing.

## Business-licensed K3 code

The following K3-authored files are marked with `SPDX-License-Identifier: LicenseRef-K3-Capital-Business-1.0` and are governed by the K3 Capital Business License terms in `LICENSE.md`:

- `src/EpochStagedERC7540Vault.sol`
- `src/IEpochStagedERC7540Vault.sol`
- `src/Staging.sol`
- `test/EpochStagedERC7540.t.sol`
- `test/EpochStagedERC7540Fuzz.t.sol`

The current public history may contain earlier versions of some of these files marked MIT. This notice is intended to govern new versions from the commit that introduces the `LicenseRef-K3-Capital-Business-1.0` headers onward, and does not attempt to revoke rights already granted for older MIT-marked public versions.

## MIT upstream-derived code

The following lightly modified upstream-derived Solidity and deployment helper files retain `SPDX-License-Identifier: MIT`:

- `script/Deploy.s.sol`
- `script/Upgrade.s.sol`
- `script/utils/DeployHelper.sol`
- `src/SmartAccountWrapper.sol`

The MIT notice on those files applies to those files only. It does not grant rights to business-licensed files imported by, inherited by, compiled with, or deployed alongside them.

## Third-party dependencies

Dependencies under `lib/` retain their own upstream licenses and notices, including OpenZeppelin, forge-std, and Solady. Review those dependency license files before redistributing third-party code.
