// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {MorphoAllocator} from "../src/MorphoAllocator.sol";

import {IFacility} from "@grunt/interfaces/facility/IFacility.sol";
import {IVaultV2} from "@vault-v2/interfaces/IVaultV2.sol";

/// @notice Minimal view of the Solady `ERC1967Factory` (deployed on mainnet). Inlined rather than
///         imported so the script does not pull in or compile the full factory implementation.
/// @dev `deployAndCall` deploys an ERC1967 proxy pointing at `implementation`, records `admin` as
///      the upgrade admin (the only address allowed to later call `upgrade`/`upgradeAndCall` on the
///      proxy via the factory), and delegatecalls `data` on the new proxy — atomically initializing
///      it in the same transaction.
interface IERC1967Factory {
  function deployAndCall(address implementation, address admin, bytes calldata data)
    external
    payable
    returns (address proxy);
}

/// @title DeployMorphoAllocator
/// @author 3F Protocol
/// @notice Deploys the `MorphoAllocator` Smart Facilitator behind an upgradeable ERC1967 proxy via
///         the Solady `ERC1967Factory`, initializing it in the same call. The implementation locks
///         direct initialization (`_disableInitializers`), so a usable instance only exists behind a
///         proxy.
/// @dev Deploy + initialize only. Two grants remain for the respective owners after this script and
///      are NOT performed here: the Facility owner must grant `FACILITATOR_ROLE` to the proxy, and
///      the Morpho Vault V2 curator must `setIsAllocator(morphoAllocator, true)`.
contract DeployMorphoAllocator is Script {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         ADDRESSES                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Solady ERC1967Factory used to deploy the upgradeable proxy.
  IERC1967Factory internal constant FACTORY = IERC1967Factory(0x0000000000006396FF2a80c067f99B3d2Ab4Df24);

  /// @notice Grunt Facility proxy the allocator coordinates (`facility_`).
  address internal constant FACILITY = 0x4e013ca8fF612a58F53C822904cDD0eC538a4A4F;

  /// @notice Morpho Vault V2 the MorphoAllocator allocates through (`morphoVault_`).
  address internal constant MORPHO_VAULT = 0xBEEf3f3A04e28895f3D5163d910474901981183D;

  /// @notice Owner granted on the allocator (3F_OWNER); controls EXECUTOR_ROLE.
  address internal constant OWNER = 0xC82003FC812F8eFE93cdA63d9f8Ee8c0A3EF5d60;

  /// @notice Address granted EXECUTOR_ROLE on the allocator (the only role allowed to call `run`).
  address internal constant EXECUTOR = 0x95026A338084241E739250f4F9d2F5745dE81bDd;

  /// @notice ERC1967 proxy upgrade admin (3F_ADMIN_PROTECTED); the only address allowed to upgrade
  ///         the proxy through the factory.
  address internal constant PROXY_ADMIN = 0xA9F5262c1aa97C6E519D6f8837658C8f9979bA24;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                            RUN                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Deploys and initializes the MorphoAllocator behind an ERC1967 proxy.
  function run() external {
    vm.startBroadcast();

    MorphoAllocator morphoImpl = new MorphoAllocator();
    address morphoProxy = FACTORY.deployAndCall(
      address(morphoImpl),
      PROXY_ADMIN,
      abi.encodeCall(MorphoAllocator.initialize, (OWNER, EXECUTOR, IFacility(FACILITY), IVaultV2(MORPHO_VAULT)))
    );

    vm.stopBroadcast();

    console2.log("MorphoAllocator impl :", address(morphoImpl));
    console2.log("MorphoAllocator proxy:", morphoProxy);
    console2.log("");
    console2.log("Post-deploy (not done here):");
    console2.log("- Facility owner: grant FACILITATOR_ROLE to the proxy");
    console2.log("- Vault curator : setIsAllocator(morphoAllocator, true)");
  }
}
