// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Phase} from "../interfaces/IMorphoAllocator.sol";

/// @title LibMorphoAllocatorErrors
/// @author 3F Protocol
/// @notice Error definitions for the MorphoAllocator contract.
library LibMorphoAllocatorErrors {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                        WORKFLOW STATE                      */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when an intent's workflow is not in the required phase.
  /// @param intentId The intent ID.
  /// @param expected The phase the call requires.
  /// @param actual   The phase currently stored.
  error InvalidPhase(uint256 intentId, Phase expected, Phase actual);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          SLIPPAGE                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when the amount credited to the intent on unlock is below the executor minimum.
  /// @param minOut Minimum expected amount.
  /// @param actual Amount actually credited to the intent.
  error SlippageExceeded(uint256 minOut, uint256 actual);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       ASSET VALIDATION                     */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when the selected asset is not a position manager.
  /// @param intentId  The intent ID.
  /// @param useTarget True if the target asset was selected, false if the deposit asset.
  error TargetNotPositionManager(uint256 intentId, bool useTarget);
}
