// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {CommitDeposit} from "../src/CommitDeposit.sol";
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

/// @title DeployAllocators
/// @author 3F Protocol
/// @notice Deploys the two Smart Facilitators (`CommitDeposit` and `MorphoAllocator`) behind
///         upgradeable ERC1967 proxies via the Solady `ERC1967Factory`, initializing each in the
///         same call. Both implementations lock direct initialization (`_disableInitializers`), so a
///         usable instance only exists behind a proxy.
/// @dev Deploy + initialize only. Two grants remain for the respective owners after this script and
///      are NOT performed here: the Facility owner must grant `FACILITATOR_ROLE` to both proxies,
///      and the Morpho Vault V2 curator must `setIsAllocator(morphoAllocator, true)`.
contract DeployAllocators is Script {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         ADDRESSES                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Solady ERC1967Factory used to deploy the upgradeable proxies.
  IERC1967Factory internal constant FACTORY = IERC1967Factory(0x54F862fa0612A8709F6Dec4A7B39AF015CD4E82E);

  /// @notice Grunt Facility proxy both allocators coordinate (`facility_`).
  address internal constant FACILITY = 0x4e013ca8fF612a58F53C822904cDD0eC538a4A4F;

  /// @notice Morpho Vault V2 the MorphoAllocator allocates through (`morphoVault_`).
  address internal constant MORPHO_VAULT = 0xBEEf3f3A04e28895f3D5163d910474901981183D;

  /// @notice Owner granted on both allocators (3F_OWNER); controls EXECUTOR_ROLE.
  address internal constant OWNER = 0xC82003FC812F8eFE93cdA63d9f8Ee8c0A3EF5d60;

  /// @notice Address granted EXECUTOR_ROLE on both allocators (the only role allowed to call `run`).
  address internal constant EXECUTOR = 0x95026A338084241E739250f4F9d2F5745dE81bDd;

  /// @notice ERC1967 proxy upgrade admin (3F_ADMIN_PROTECTED); the only address allowed to upgrade
  ///         the proxies through the factory.
  address internal constant PROXY_ADMIN = 0xA9F5262c1aa97C6E519D6f8837658C8f9979bA24;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                            RUN                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Deploys and initializes both allocators behind ERC1967 proxies.
  function run() external {
    vm.startBroadcast();

    CommitDeposit commitImpl = new CommitDeposit();
    address commitProxy = FACTORY.deployAndCall(
      address(commitImpl), PROXY_ADMIN, abi.encodeCall(CommitDeposit.initialize, (OWNER, EXECUTOR, IFacility(FACILITY)))
    );

    MorphoAllocator morphoImpl = new MorphoAllocator();
    address morphoProxy = FACTORY.deployAndCall(
      address(morphoImpl),
      PROXY_ADMIN,
      abi.encodeCall(MorphoAllocator.initialize, (OWNER, EXECUTOR, IFacility(FACILITY), IVaultV2(MORPHO_VAULT)))
    );

    vm.stopBroadcast();

    console2.log("CommitDeposit   impl :", address(commitImpl));
    console2.log("CommitDeposit   proxy:", commitProxy);
    console2.log("MorphoAllocator impl :", address(morphoImpl));
    console2.log("MorphoAllocator proxy:", morphoProxy);
    console2.log("");
    console2.log("Post-deploy (not done here):");
    console2.log("- Facility owner: grant FACILITATOR_ROLE to both proxies");
    console2.log("- Vault curator : setIsAllocator(morphoAllocator, true)");
  }
}
