// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {DepositCapStateGuard} from "../src/checks/DepositCapStateGuard.sol";

/// @title DeployDepositCapStateGuard
/// @author 3F Protocol
/// @notice Deploys the stateless `DepositCapStateGuard` through the canonical CREATE2 factory
///         (`0x4e59b44847b379578588920cA78FbF26c0B4956C`, forge-std's `CREATE2_FACTORY`), so the
///         guard lands at the same address on every chain. The contract holds no state, takes no
///         constructor arguments, and needs no proxy or initialization.
/// @dev Salted `new` inside a broadcast is routed through the canonical factory by forge. The
///      resulting address is pinned in `EXPECTED_ADDRESS` and asserted after deployment: it is a
///      pure function of the init code, so it only moves if the source or the compiler profile
///      (solc 0.8.28, via-ir, 200 optimizer runs, cancun) changes — a mismatch means this script's
///      constant and the README are stale and must be recomputed.
contract DeployDepositCapStateGuard is Script {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         ADDRESSES                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice CREATE2 salt, ground so the guard's address starts with `0x3fa77e57` ("3F ATTEST").
  /// @dev `cast create2 --deployer 0x4e59b44847b379578588920cA78FbF26c0B4956C --starts-with 3fa77e57
  ///      --init-code-hash keccak256(creationCode)` with the profile-default compiler settings.
  bytes32 internal constant SALT = 0x7fde142edeac1c4c898e276a070df232a649cda0a4e930355b1f72abb019de8a;

  /// @notice Deterministic deployment address of the guard on every chain.
  address internal constant EXPECTED_ADDRESS = 0x3Fa77E57baC28940621d1aaE1a136058c4064623;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           ERRORS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when the CREATE2 deployment does not land on `EXPECTED_ADDRESS`.
  /// @param expected The pinned deterministic address.
  /// @param actual   The address the guard actually deployed to.
  error UnexpectedGuardAddress(address expected, address actual);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                            RUN                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Deploys the guard via CREATE2 and asserts the deterministic address.
  function run() external {
    vm.startBroadcast();
    DepositCapStateGuard guard = new DepositCapStateGuard{salt: SALT}();
    vm.stopBroadcast();

    if (address(guard) != EXPECTED_ADDRESS) {
      revert UnexpectedGuardAddress(EXPECTED_ADDRESS, address(guard));
    }

    console2.log("DepositCapStateGuard:", address(guard));
  }
}
