// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {IFacility} from "@grunt/interfaces/facility/IFacility.sol";
import {IVaultV2} from "@vault-v2/interfaces/IVaultV2.sol";

import {PendingWorkflow} from "../interfaces/IMorphoAllocator.sol";
import {STORAGE_SLOT} from "./LibConstants.sol";

/// @notice Storage struct containing all persistent state for the MorphoAllocator contract.
/// @dev Uses ERC-7201 namespaced storage for proxy compatibility. All fields are grouped
///      and accessed via a fixed storage slot to prevent collisions with inherited contracts.
/// @param facility    The Grunt Facility this allocator is a facilitator on.
/// @param morphoVault The Morpho Vault V2 this allocator can reallocate.
/// @param workflows   Per-intent workflow state.
struct MorphoAllocatorStorageData {
  IFacility facility;
  IVaultV2 morphoVault;
  mapping(uint256 intentId => PendingWorkflow) workflows;
}

/// @title LibStorage
/// @author 3F Protocol
/// @notice Library providing the storage accessor for the MorphoAllocator contract.
/// @dev Uses a custom storage slot pattern for upgradeability.
library LibStorage {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       STORAGE ACCESS                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Returns a reference to the contract's storage struct.
  ///      Uses assembly to load the storage pointer from the fixed storage slot.
  ///      This pattern ensures a consistent storage layout when used behind proxies.
  /// @return data A storage pointer to the `MorphoAllocatorStorageData` struct.
  function allocatorStorage() internal pure returns (MorphoAllocatorStorageData storage data) {
    assembly ("memory-safe") {
      data.slot := STORAGE_SLOT
    }
  }
}
