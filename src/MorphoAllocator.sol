// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Initializable} from "solady/utils/Initializable.sol";
import {OwnableRoles} from "solady/auth/OwnableRoles.sol";
import {Multicallable} from "solady/utils/Multicallable.sol";

import {IFacility} from "@grunt/interfaces/facility/IFacility.sol";
import {IPositionManager} from "@grunt/interfaces/manager/IPositionManager.sol";
import {IntentProperties, Asset} from "@grunt/libs/facility/LibIntent.sol";
import {Mode, Order, State} from "@grunt/libs/funds/Order.sol";
import {IFund} from "@grunt/interfaces/funds/IFund.sol";

import {IVaultV2} from "@vault-v2/interfaces/IVaultV2.sol";
import {IMorphoMarketV1AdapterV2} from "@vault-v2/adapters/interfaces/IMorphoMarketV1AdapterV2.sol";

import {IMorpho, MarketParams, Id, Market} from "@morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@morpho-blue/libraries/MarketParamsLib.sol";

import {IMorphoAllocator, Deallocation} from "./interfaces/IMorphoAllocator.sol";

/// @title MorphoAllocator
/// @author 3F Protocol
/// @notice First Grunt Smart Facilitator: atomically commits a fund DEPOSIT order in Phase 1,
///         then in Phase 2 unlocks the matured shares, rebalances Morpho Vault V2 liquidity
///         (deallocating from source markets or idle and allocating the total into one market),
///         and runs `Facility.depositManager`.
/// @dev Must hold `FACILITATOR_ROLE` on the target Facility and `isAllocator = true` on the
///      target Morpho Vault V2. Proxy-ready via Solady `Initializable` and ERC-7201 namespaced
///      storage. `start` and `complete` are independent — `complete` may run even if `start` was
///      performed by another facilitator — and the Grunt order state is asserted (`PROCESSING`
///      after commit, `ENDED` after unlock). Inherits `Multicallable` so the executor can batch
///      calls. Assumes Morpho V1 Market adapters.
contract MorphoAllocator is IMorphoAllocator, OwnableRoles, Initializable, Multicallable {
  using MarketParamsLib for MarketParams;

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
  struct MorphoAllocatorStorage {
    IFacility facility;
    IVaultV2 morphoVault;
  }

  /// @dev Returns a reference to the contract's namespaced storage struct.
  ///      Loads the storage pointer from the fixed `STORAGE_SLOT`, ensuring a consistent
  ///      storage layout when used behind proxies.
  /// @return data A storage pointer to the `MorphoAllocatorStorage` struct.
  function _allocatorStorage() private pure returns (MorphoAllocatorStorage storage data) {
    assembly ("memory-safe") {
      data.slot := STORAGE_SLOT
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           ERRORS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

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

  /// @notice Thrown when the fund order is not in the expected state at a phase boundary.
  /// @param expected The required order state.
  /// @param actual   The order state actually observed.
  error UnexpectedOrderState(State expected, State actual);

  /// @notice Thrown when a source market's post-deallocation utilisation exceeds the cap.
  /// @param adapter        The Morpho V1 Market adapter deallocated from.
  /// @param utilisation    The market's utilisation after the withdrawal (WAD).
  /// @param maxUtilisation The maximum allowed utilisation (WAD).
  error MaxUtilisationExceeded(address adapter, uint256 utilisation, uint256 maxUtilisation);

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

    MorphoAllocatorStorage storage $ = _allocatorStorage();
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
  /// @dev Atomic sequence: `Facility.pull(pullAmount)` → `Facility.create(commitAmount, DEPOSIT)`
  ///      → `Facility.commit` → assert the order is in `State.PROCESSING`.
  function start(uint256 intentId, uint256 pullAmount, uint256 commitAmount, uint256 minSharesOut)
    external
    override
    onlyRoles(EXECUTOR_ROLE)
  {
    IFacility _facility = _allocatorStorage().facility;
    _facility.pull(intentId, pullAmount);
    Order memory order = _facility.create(intentId, commitAmount, minSharesOut, Mode.DEPOSIT);
    _facility.commit(intentId);

    (, address fund,,) = _facility.getIntent(intentId);
    State orderState = IFund(fund).state(order);
    if (orderState != State.PROCESSING) revert UnexpectedOrderState(State.PROCESSING, orderState);

    emit WorkflowStarted(intentId, pullAmount, commitAmount);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          PHASE 2                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @inheritdoc IMorphoAllocator
  /// @dev Atomic sequence: `Facility.unlock` → assert order `State.ENDED` → deallocate each source
  ///      market (validating post-withdrawal utilisation) → `MorphoVaultV2.allocate` of the gathered
  ///      total (skipped when `allocateAdapter == address(0)`) → `Facility.depositManager`. Any revert
  ///      (slippage, utilisation, unexpected state) reverts the whole call so it can be retried.
  function complete(
    uint256 intentId,
    Deallocation[] calldata deallocations,
    address allocateAdapter,
    MarketParams calldata allocateMarket,
    uint256 borrowAmount,
    bool useTarget,
    uint256 minSharesUnlocked
  ) external override onlyRoles(EXECUTOR_ROLE) {
    MorphoAllocatorStorage storage $ = _allocatorStorage();
    IFacility _facility = $.facility;

    (IntentProperties memory props, address fund,,) = _facility.getIntent(intentId);
    Asset memory pmAsset = useTarget ? props.targetAsset : props.depositAsset;
    if (!pmAsset.isPositionManager) revert TargetNotPositionManager(intentId, useTarget);

    (address collateralAsset,) = IPositionManager(pmAsset.asset).assets();
    (Order memory order,) = _facility.getOrder(intentId);
    uint256 balanceBefore = _intentBalanceOf(_facility, intentId, collateralAsset);

    _facility.unlock(intentId);

    State orderState = IFund(fund).state(order);
    if (orderState != State.ENDED) revert UnexpectedOrderState(State.ENDED, orderState);

    uint256 balanceAfter = _intentBalanceOf(_facility, intentId, collateralAsset);
    if (balanceAfter < balanceBefore) {
      revert UnlockBalanceDecreased(intentId, balanceBefore, balanceAfter);
    }
    uint256 unlocked = balanceAfter - balanceBefore;
    if (unlocked < minSharesUnlocked) revert SlippageExceeded(minSharesUnlocked, unlocked);

    uint256 allocatedTotal = _rebalance($.morphoVault, deallocations, allocateAdapter, allocateMarket);

    _facility.depositManager(intentId, unlocked, borrowAmount, useTarget);

    emit WorkflowCompleted(intentId, unlocked, allocateAdapter, allocatedTotal, borrowAmount);
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                         INTERNALS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Gathers liquidity from each deallocation source, then allocates the total into one market.
  ///      A source with `adapter == address(0)` contributes its `amount` from idle liquidity (no
  ///      `deallocate`, no utilisation check). Allocation is skipped when `allocateAdapter == address(0)`
  ///      or the total is zero, leaving the gathered liquidity idle.
  /// @param vault           The Morpho Vault V2 to rebalance.
  /// @param deallocations   The sources to withdraw from (markets and/or idle).
  /// @param allocateAdapter The destination adapter, or address(0) to skip allocation.
  /// @param allocateMarket  The destination market (ignored when `allocateAdapter == address(0)`).
  /// @return total          The total gathered across all sources.
  function _rebalance(
    IVaultV2 vault,
    Deallocation[] calldata deallocations,
    address allocateAdapter,
    MarketParams calldata allocateMarket
  ) private returns (uint256 total) {
    uint256 length = deallocations.length;
    for (uint256 i = 0; i < length; i++) {
      Deallocation calldata d = deallocations[i];
      total += d.amount;
      if (d.adapter != address(0)) {
        vault.deallocate(d.adapter, abi.encode(d.marketParams), d.amount);
        _checkUtilisation(d.adapter, d.marketParams, d.maxUtilisation);
      }
    }

    if (allocateAdapter != address(0) && total > 0) {
      vault.allocate(allocateAdapter, abi.encode(allocateMarket), total);
    }
  }

  /// @dev Reverts if `marketParams`' utilisation exceeds `maxUtilisation` (WAD). Must be called
  ///      after the deallocation so the market totals already reflect the withdrawal and the
  ///      interest Morpho accrues during `withdraw`. Utilisation = totalBorrowAssets * 1e18 /
  ///      totalSupplyAssets; with zero supply it is treated as 0 (no borrow) or infinite (any borrow).
  /// @param adapter        The Morpho V1 Market adapter that was deallocated from.
  /// @param marketParams   The source market identifier.
  /// @param maxUtilisation The maximum allowed post-deallocation utilisation (WAD).
  function _checkUtilisation(address adapter, MarketParams calldata marketParams, uint256 maxUtilisation) private view {
    Id id = marketParams.id();
    Market memory market = IMorpho(IMorphoMarketV1AdapterV2(adapter).morpho()).market(id);

    uint256 utilisation;
    if (market.totalSupplyAssets == 0) {
      utilisation = market.totalBorrowAssets == 0 ? 0 : type(uint256).max;
    } else {
      utilisation = uint256(market.totalBorrowAssets) * 1e18 / market.totalSupplyAssets;
    }

    if (utilisation > maxUtilisation) revert MaxUtilisationExceeded(adapter, utilisation, maxUtilisation);
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
