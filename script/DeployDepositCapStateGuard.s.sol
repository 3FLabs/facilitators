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
/// @dev The already-deployed address depends on the original init code, including its Solidity
///      metadata hash. Restore that hash before calling the canonical factory, and verify the full
///      init code hash so changes to executable code cannot silently deploy an outdated contract.
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

  /// @dev The first 930 bytes of the 973-byte init code are executable code. The next 32 bytes
  ///      are the IPFS digest in Solidity's CBOR metadata, which can vary between build contexts.
  bytes32 internal constant DEPLOYED_METADATA_DIGEST =
    0x0cf1aea5547025eafdd9a16c8ed54a7ff01a00dbcc5c313365d3208df9a9ff44;
  bytes32 internal constant EXPECTED_INIT_CODE_HASH =
    0x45021accaf3fbe28289aa96bae09aee2851c456f5b3d5d130b5c6374805ffa26;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           ERRORS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when the expected address has no deployed code after the factory call.
  error GuardCodeMissing(address expected);

  /// @notice Thrown if the compiled init code differs from the code deployed on existing chains.
  error UnexpectedGuardInitCode();

  /// @notice Thrown if the canonical CREATE2 factory rejects the deployment.
  error GuardDeploymentFailed();

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                            RUN                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Deploys the guard via CREATE2 and asserts the deterministic address.
  function run() external {
    bytes memory initCode = type(DepositCapStateGuard).creationCode;
    if (initCode.length != 973) revert UnexpectedGuardInitCode();

    bytes32 metadataDigest = DEPLOYED_METADATA_DIGEST;
    assembly ("memory-safe") {
      mstore(add(add(initCode, 0x20), 930), metadataDigest)
    }
    if (keccak256(initCode) != EXPECTED_INIT_CODE_HASH) revert UnexpectedGuardInitCode();

    vm.startBroadcast();
    (bool success,) = CREATE2_FACTORY.call(abi.encodePacked(SALT, initCode));
    vm.stopBroadcast();
    if (!success) revert GuardDeploymentFailed();

    if (EXPECTED_ADDRESS.code.length == 0) revert GuardCodeMissing(EXPECTED_ADDRESS);

    console2.log("DepositCapStateGuard:", EXPECTED_ADDRESS);
  }
}
