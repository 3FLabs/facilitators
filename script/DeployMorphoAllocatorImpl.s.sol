// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {MorphoAllocator} from "../src/MorphoAllocator.sol";

/// @notice Minimal view of the Solady `ERC1967Factory` (deployed on mainnet). Inlined rather than
///         imported so the script does not pull in or compile the full factory implementation.
/// @dev `upgrade` points `proxy` at `implementation`; only the proxy's recorded admin may call it.
interface IERC1967Factory {
  function upgrade(address proxy, address implementation) external payable;
}

/// @title DeployMorphoAllocatorImpl
/// @author 3F Protocol
/// @notice Deploys a new `MorphoAllocator` implementation for the live mainnet proxy and prints the
///         `ERC1967Factory.upgrade` calldata the proxy admin must execute to switch to it.
/// @dev Deploy only. The upgrade itself is NOT broadcast: only `PROXY_ADMIN` can call it. The script
///      simulates it from `PROXY_ADMIN` on the fork to check the calldata works. No re-initialization
///      is needed: storage is ERC-7201 namespaced and the proxy keeps its owner, executor, Facility
///      and Vault.
contract DeployMorphoAllocatorImpl is Script {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         ADDRESSES                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Solady ERC1967Factory the proxy was deployed through.
  IERC1967Factory internal constant FACTORY = IERC1967Factory(0x0000000000006396FF2a80c067f99B3d2Ab4Df24);

  /// @notice Live MorphoAllocator proxy on mainnet.
  address internal constant PROXY = 0xb8947d2725D3E9De9b19fC720f053300c50981e5;

  /// @notice ERC1967 proxy upgrade admin (3F_ADMIN_PROTECTED); the only address allowed to upgrade
  ///         the proxy through the factory.
  address internal constant PROXY_ADMIN = 0xA9F5262c1aa97C6E519D6f8837658C8f9979bA24;

  /// @notice ERC1967 implementation slot: `bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1)`.
  bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                            RUN                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Deploys the new implementation and prints the upgrade call for the proxy admin.
  function run() external {
    vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
    MorphoAllocator impl = new MorphoAllocator();
    vm.stopBroadcast();

    bytes memory upgradeData = abi.encodeCall(IERC1967Factory.upgrade, (PROXY, address(impl)));

    // Fork-only sanity check: the admin's upgrade call succeeds and repoints the proxy.
    vm.prank(PROXY_ADMIN);
    (bool ok,) = address(FACTORY).call(upgradeData);
    require(ok, "upgrade simulation failed");
    require(address(uint160(uint256(vm.load(PROXY, IMPLEMENTATION_SLOT)))) == address(impl), "impl not set");

    console2.log("MorphoAllocator impl:", address(impl));
    console2.log("");
    console2.log("Proxy admin must execute (not done here):");
    console2.log("- to  :", address(FACTORY));
    console2.log("- data:");
    console2.logBytes(upgradeData);
  }
}
