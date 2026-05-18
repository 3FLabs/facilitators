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
import {LibStorage, MorphoAllocatorStorageData} from "./libs/LibStorage.sol";
import {LibMorphoAllocatorErrors} from "./libs/LibMorphoAllocatorErrors.sol";

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
  using LibStorage for MorphoAllocatorStorageData;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           ROLES                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Role for addresses authorized to trigger workflow phases.
  uint256 internal constant EXECUTOR_ROLE = _ROLE_0;

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

    MorphoAllocatorStorageData storage $ = LibStorage.allocatorStorage();
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
    return LibStorage.allocatorStorage().workflows[intentId];
  }

  /// @notice Returns the configured Facility address.
  /// @return The Grunt Facility this allocator coordinates.
  function facility() external view returns (IFacility) {
    return LibStorage.allocatorStorage().facility;
  }

  /// @notice Returns the configured Morpho Vault V2 address.
  /// @return The Morpho Vault V2 this allocator allocates through.
  function morphoVault() external view returns (IVaultV2) {
    return LibStorage.allocatorStorage().morphoVault;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           ADMIN                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IMorphoAllocator
  function setExecutor(address executor, bool enabled) external override onlyOwner {
    if (enabled) _grantRoles(executor, EXECUTOR_ROLE);
    else _removeRoles(executor, EXECUTOR_ROLE);
    emit ExecutorSet(executor, enabled);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          PHASE 1                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IMorphoAllocator
  /// @dev Atomic sequence: `Facility.pull` → `Facility.create(DEPOSIT)` → `Facility.commit`.
  ///      Stores `adapter` and `adapterData` so the executor cannot retarget Phase 2.
  function startWorkflow(
    uint256 intentId,
    uint256 pullAmount,
    uint256 minSharesOut,
    address adapter,
    bytes calldata adapterData
  ) external override onlyRoles(EXECUTOR_ROLE) {
    MorphoAllocatorStorageData storage $ = LibStorage.allocatorStorage();
    PendingWorkflow storage wf = $.workflows[intentId];
    if (wf.phase != Phase.IDLE) revert LibMorphoAllocatorErrors.InvalidPhase(intentId, Phase.IDLE, wf.phase);

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
  function completeWorkflow(
    uint256 intentId,
    uint256 allocateAmount,
    uint256 borrowAmount,
    bool useTarget,
    uint256 minSharesUnlocked
  ) external override onlyRoles(EXECUTOR_ROLE) {
    MorphoAllocatorStorageData storage $ = LibStorage.allocatorStorage();
    PendingWorkflow memory wf = $.workflows[intentId];
    if (wf.phase != Phase.COMMITTED) revert LibMorphoAllocatorErrors.InvalidPhase(intentId, Phase.COMMITTED, wf.phase);

    IFacility _facility = $.facility;

    (IntentProperties memory props,,,) = _facility.getIntent(intentId);
    Asset memory pmAsset = useTarget ? props.targetAsset : props.depositAsset;
    if (!pmAsset.isPositionManager) revert LibMorphoAllocatorErrors.TargetNotPositionManager(intentId, useTarget);

    (address collateralAsset,) = IPositionManager(pmAsset.asset).assets();
    uint256 balanceBefore = _intentBalanceOf(_facility, intentId, collateralAsset);

    _facility.unlock(intentId);

    uint256 unlocked;
    unchecked {
      // balanceAfter >= balanceBefore: unlock can only credit collateral to the intent,
      // never debit, so the subtraction never underflows.
      unlocked = _intentBalanceOf(_facility, intentId, collateralAsset) - balanceBefore;
    }
    if (unlocked < minSharesUnlocked) revert LibMorphoAllocatorErrors.SlippageExceeded(minSharesUnlocked, unlocked);

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
