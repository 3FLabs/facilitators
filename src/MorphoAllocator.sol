// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Initializable} from "solady/utils/Initializable.sol";
import {OwnableRoles} from "solady/auth/OwnableRoles.sol";

import {IFacility} from "@grunt/interfaces/facility/IFacility.sol";
import {IPositionManager} from "@grunt/interfaces/manager/IPositionManager.sol";
import {IntentProperties, Asset} from "@grunt/libs/facility/LibIntent.sol";
import {Mode} from "@grunt/libs/funds/Order.sol";

import {IVaultV2} from "@vault-v2/interfaces/IVaultV2.sol";

import {IMorphoAllocator, Phase, PendingWorkflow} from "./interfaces/IMorphoAllocator.sol";

/// @title MorphoAllocator
/// @author 3F Protocol
/// @notice First Grunt Smart Facilitator: atomically commits a fund DEPOSIT order in Phase 1,
///         then in Phase 2 unlocks the matured shares, reallocates Morpho Vault V2 liquidity
///         into the target Morpho Blue market, and runs `Facility.depositManager`.
/// @dev Must hold `FACILITATOR_ROLE` on the target Facility and `isAllocator = true` on the
///      target Morpho Vault V2. Proxy-ready via Solady `Initializable` and ERC-7201 namespaced
///      storage. Per-intent state guards Phase 2 behind Phase 1 and locks in the adapter/data
///      chosen at Phase 1 so the executor cannot retarget allocation between phases.
contract MorphoAllocator is IMorphoAllocator, OwnableRoles, Initializable {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           ROLES                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Role for addresses authorized to trigger workflow phases.
  uint256 internal constant EXECUTOR_ROLE = _ROLE_0;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          STORAGE                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Storage slot for the MorphoAllocator's namespaced storage struct.
  ///      Computed as `keccak256(abi.encode(uint256(keccak256("morpho_allocator")) - 1)) & ~bytes32(uint256(0xff))`.
  ///      Follows the ERC-7201 namespaced storage pattern to prevent storage collisions in proxies
  ///      and inheritance hierarchies.
  bytes32 private constant STORAGE_SLOT = 0x14521fccd051e83be9d169ec3fd9a9c40aeae5d721183d031a3f782c79172800;
  
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

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           ERRORS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when an intent's workflow is not in the required phase.
  /// @param intentId The intent ID.
  /// @param expected The phase the call requires.
  /// @param actual   The phase currently stored.
  error InvalidPhase(uint256 intentId, Phase expected, Phase actual);

  /// @notice Thrown when the amount credited to the intent on unlock is below the executor minimum.
  /// @param minOut Minimum expected amount.
  /// @param actual Amount actually credited to the intent.
  error SlippageExceeded(uint256 minOut, uint256 actual);

  /// @notice Thrown when the intent's collateral balance decreased across an unlock.
  /// @param intentId      The intent ID.
  /// @param balanceBefore The balance before unlock.
  /// @param balanceAfter  The balance after unlock.
  error UnlockBalanceDecreased(uint256 intentId, uint256 balanceBefore, uint256 balanceAfter);

  /// @notice Thrown when the selected asset is not a position manager.
  /// @param intentId  The intent ID.
  /// @param useTarget True if the target asset was selected, false if the deposit asset.
  error TargetNotPositionManager(uint256 intentId, bool useTarget);

  /// @notice Thrown when the owner address is zero during initialization.
  error OwnerZeroAddress();

  /// @notice Thrown when the Facility address has no code during initialization.
  error FacilityNotContract();

  /// @notice Thrown when the Morpho Vault address has no code during initialization.
  error MorphoVaultNotContract();

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       INITIALIZATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Locks the implementation contract from being initialized directly.
  /// @dev Required when the contract is deployed behind a proxy.
  constructor() {
    _disableInitializers();
  }

  /// @notice Initializes the MorphoAllocator.
  /// @dev Can only be called once due to the `initializer` modifier. Grants `EXECUTOR_ROLE`
  ///      to `executor_` when it is non-zero. The Facility owner must separately grant
  ///      `FACILITATOR_ROLE` to this contract, and the Vault curator must whitelist it as
  ///      an allocator.
  /// @param owner_       Address granted owner privileges.
  /// @param executor_    Address granted EXECUTOR_ROLE (pass address(0) to skip).
  /// @param facility_    The Grunt Facility this allocator coordinates.
  /// @param morphoVault_ The Morpho Vault V2 this allocator allocates through.
  function initialize(address owner_, address executor_, IFacility facility_, IVaultV2 morphoVault_)
    external
    initializer
  {
    _initializeOwner(owner_);

    require(owner_ != address(0), OwnerZeroAddress());
    require(address(facility_).code.length > 0, FacilityNotContract());
    require(address(morphoVault_).code.length > 0, MorphoVaultNotContract());

    MorphoAllocatorStorageData storage $ = _allocatorStorage();
    $.facility = facility_;
    $.morphoVault = morphoVault_;

    if (executor_ != address(0)) {
      _grantRoles(executor_, EXECUTOR_ROLE);
      emit ExecutorSet(executor_, true);
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           VIEWS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IMorphoAllocator
  function workflow(uint256 intentId) external view override returns (PendingWorkflow memory) {
    return _allocatorStorage().workflows[intentId];
  }

  /// @notice Returns the configured Facility address.
  /// @return The Grunt Facility this allocator coordinates.
  function facility() external view returns (IFacility) {
    return _allocatorStorage().facility;
  }

  /// @notice Returns the configured Morpho Vault V2 address.
  /// @return The Morpho Vault V2 this allocator allocates through.
  function morphoVault() external view returns (IVaultV2) {
    return _allocatorStorage().morphoVault;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          PHASE 1                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IMorphoAllocator
  /// @dev Atomic sequence: `Facility.pull` → `Facility.create(DEPOSIT)` → `Facility.commit`.
  ///      Stores `adapter` and `adapterData` so the executor cannot retarget Phase 2.
  function start(
    uint256 intentId,
    uint256 pullAmount,
    uint256 minSharesOut,
    address adapter,
    bytes calldata adapterData
  ) external override onlyRoles(EXECUTOR_ROLE) {
    MorphoAllocatorStorageData storage $ = _allocatorStorage();
    PendingWorkflow storage wf = $.workflows[intentId];
    if (wf.phase != Phase.IDLE) revert InvalidPhase(intentId, Phase.IDLE, wf.phase);

    IFacility _facility = $.facility;
    _facility.pull(intentId, pullAmount);
    _facility.create(intentId, pullAmount, minSharesOut, Mode.DEPOSIT);
    _facility.commit(intentId);

    wf.phase = Phase.COMMITTED;
    wf.adapter = adapter;
    wf.adapterData = adapterData;

    emit WorkflowStarted(intentId, pullAmount, adapter);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          PHASE 2                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IMorphoAllocator
  /// @dev Atomic sequence: `Facility.unlock` → `MorphoVaultV2.allocate` (skipped when
  ///      `allocateAmount == 0`) → `Facility.depositManager`. Slippage on `unlock` reverts the
  ///      whole transaction so the workflow remains in `Phase.COMMITTED` and can be retried.
  function complete(
    uint256 intentId,
    uint256 allocateAmount,
    uint256 borrowAmount,
    bool useTarget,
    uint256 minSharesUnlocked
  ) external override onlyRoles(EXECUTOR_ROLE) {
    MorphoAllocatorStorageData storage $ = _allocatorStorage();
    PendingWorkflow memory wf = $.workflows[intentId];
    if (wf.phase != Phase.COMMITTED) revert InvalidPhase(intentId, Phase.COMMITTED, wf.phase);

    IFacility _facility = $.facility;

    (IntentProperties memory props,,,) = _facility.getIntent(intentId);
    Asset memory pmAsset = useTarget ? props.targetAsset : props.depositAsset;
    if (!pmAsset.isPositionManager) revert TargetNotPositionManager(intentId, useTarget);

    (address collateralAsset,) = IPositionManager(pmAsset.asset).assets();
    uint256 balanceBefore = _intentBalanceOf(_facility, intentId, collateralAsset);

    _facility.unlock(intentId);

    uint256 balanceAfter = _intentBalanceOf(_facility, intentId, collateralAsset);
    if (balanceAfter < balanceBefore) {
      revert UnlockBalanceDecreased(intentId, balanceBefore, balanceAfter);
    }
    uint256 unlocked = balanceAfter - balanceBefore;
    if (unlocked < minSharesUnlocked) revert SlippageExceeded(minSharesUnlocked, unlocked);

    if (allocateAmount > 0) {
      $.morphoVault.allocate(wf.adapter, wf.adapterData, allocateAmount);
    }

    _facility.depositManager(intentId, unlocked, borrowAmount, useTarget);

    delete $.workflows[intentId];
    emit WorkflowCompleted(intentId, unlocked, allocateAmount, borrowAmount);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         INTERNALS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Returns a reference to the contract's namespaced storage struct.
  ///      Loads the storage pointer from the fixed `STORAGE_SLOT`, ensuring a consistent
  ///      storage layout when used behind proxies.
  /// @return data A storage pointer to the `MorphoAllocatorStorageData` struct.
  function _allocatorStorage() private pure returns (MorphoAllocatorStorageData storage data) {
    assembly ("memory-safe") {
      data.slot := STORAGE_SLOT
    }
  }

  /// @dev Reads an intent's balance for a specific token by iterating `intentBalances`.
  ///      Reading `IERC20.balanceOf(facility)` would aggregate across all intents and be wrong;
  ///      the per-intent map is the only correct source. Iteration cost is bounded by the
  ///      intent's token set (≤ ~6 entries for this workflow).
  /// @param _facility The Facility to query.
  /// @param intentId  The intent ID.
  /// @param token     The token whose intent-attributed balance to read.
  /// @return amount   The intent's balance of `token`, or zero if the token is absent.
  function _intentBalanceOf(IFacility _facility, uint256 intentId, address token)
    private
    view
    returns (uint256 amount)
  {
    (address[] memory tokens, uint256[] memory amounts) = _facility.intentBalances(intentId);
    uint256 length = tokens.length;
    for (uint256 i = 0; i < length; i++) {
      if (tokens[i] == token) return amounts[i];
    }
    return 0;
  }
}
