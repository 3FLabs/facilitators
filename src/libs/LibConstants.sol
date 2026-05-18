// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

/// @title LibConstants
/// @author 3F Protocol
/// @notice Shared constants used across the MorphoAllocator contracts.
/// @dev This file contains compile-time constants that are inlined by the compiler for gas efficiency.
///      Constants are defined at the file level (outside of contracts) to enable direct imports
///      and avoid contract deployment overhead as well as enabling use in assembly blocks.

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                         STORAGE                            */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/// @dev Storage slot for the MorphoAllocator's namespaced storage struct.
///      Computed as `keccak256(abi.encode(uint256(keccak256("morpho_allocator")) - 1)) & ~bytes32(uint256(0xff))`.
///      Follows the ERC-7201 namespaced storage pattern to prevent storage collisions in proxies
///      and inheritance hierarchies.
/// @custom:value 0x14521fccd051e83be9d169ec3fd9a9c40aeae5d721183d031a3f782c79172800
bytes32 constant STORAGE_SLOT = 0x14521fccd051e83be9d169ec3fd9a9c40aeae5d721183d031a3f782c79172800;
