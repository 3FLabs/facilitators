// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {MarketParams} from "@morpho-blue/interfaces/IMorpho.sol";

/// @notice A single source from which Phase 2 gathers liquidity before allocating the total.
/// @dev `adapter == address(0)` means `amount` is taken from the vault's idle liquidity: no
///      `deallocate` call is made and `marketParams`/`maxUtilisation` are ignored. Otherwise the
///      Morpho Vault V2 `deallocate(adapter, abi.encode(marketParams), amount)` withdraws `amount`
///      from the market, after which that market's utilisation must be `<= maxUtilisation`.
/// @param adapter        Morpho V1 Market adapter to deallocate from, or address(0) for idle liquidity.
/// @param marketParams   Source market identifier (ignored when `adapter == address(0)`).
/// @param amount         Assets to source from this entry; contributes to the allocated total.
/// @param maxUtilisation Post-deallocation utilisation cap in WAD (ignored when `adapter == address(0)`).
struct Deallocation {
  address adapter;
  MarketParams marketParams;
  uint256 amount;
  uint256 maxUtilisation;
}

/// @title IMorphoAllocator
/// @author 3F Protocol
/// @notice External API for the MorphoAllocator Smart Facilitator.
/// @dev Exposes events and the two workflow phase functions. The contract
///      implementing this interface must hold `FACILITATOR_ROLE` on the target Facility and
///      `isAllocator = true` on the target Morpho Vault V2.
interface IMorphoAllocator {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          EVENTS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Emitted when Phase 1 (pull + create + commit) succeeds for an intent.
  /// @param intentId     The intent ID.
  /// @param pullAmount   The amount pulled from the Request.
  /// @param commitAmount The fund order input amount that was created and committed.
  event WorkflowStarted(uint256 indexed intentId, uint256 pullAmount, uint256 commitAmount);

  /// @notice Emitted when Phase 2 (unlock + deallocate + allocate + depositManager) succeeds.
  /// @param intentId        The intent ID.
  /// @param unlocked        The amount of collateral credited to the intent by `unlock`.
  /// @param allocateAdapter The adapter the gathered total was allocated through (address(0) if skipped).
  /// @param allocatedTotal  The total gathered from the deallocations and allocated (0 if skipped).
  /// @param borrowAmount    The amount borrowed via `Facility.depositManager`.
  event WorkflowCompleted(
    uint256 indexed intentId, uint256 unlocked, address allocateAdapter, uint256 allocatedTotal, uint256 borrowAmount
  );

  /// @notice Emitted when the executor role is granted to or revoked from an address.
  /// @param executor The affected address.
  /// @param enabled  True if granted, false if revoked.
  event ExecutorSet(address indexed executor, bool enabled);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          PHASES                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Phase 1 — pull Bridge Facilitator funds from the Request, create a DEPOSIT fund
  ///         order against the intent's fund, and commit it.
  /// @dev Reverts unless the order is in `State.PROCESSING` after the commit.
  /// @param intentId     The intent ID.
  /// @param pullAmount   The amount of bridge-loan asset to pull from the Request.
  /// @param commitAmount The DEPOSIT order input amount to create and commit (may differ from pullAmount).
  /// @param minSharesOut Minimum shares the DEPOSIT order must mint (slippage guard on fund side).
  function start(uint256 intentId, uint256 pullAmount, uint256 commitAmount, uint256 minSharesOut) external;

  /// @notice Phase 2 — unlock the matured fund order, rebalance Morpho Vault V2 liquidity by
  ///         deallocating from a set of source markets (or idle) and allocating the total into a
  ///         single destination market, then deposit the unlocked collateral and borrow.
  /// @dev Ordering inside the call is
  ///      unlock → (assert order ENDED) → deallocate(+utilisation checks) → allocate → depositManager.
  ///      The allocated total is the sum of `deallocations[i].amount`. Allocation is skipped when
  ///      `allocateAdapter == address(0)` (the gathered total stays as idle liquidity).
  /// @param intentId          The intent ID.
  /// @param deallocations     Sources to gather liquidity from (markets and/or idle); see {Deallocation}.
  /// @param allocateAdapter   Destination Morpho V1 Market adapter, or address(0) to skip allocation.
  /// @param allocateMarket    Destination market identifier (ignored when `allocateAdapter == address(0)`).
  /// @param borrowAmount      Amount to borrow via `Facility.depositManager`.
  /// @param useTarget         True to use the intent's target asset as the PositionManager,
  ///                          false to use the deposit asset.
  /// @param minSharesUnlocked Minimum amount that must be unlocked (slippage guard on unlock).
  function complete(
    uint256 intentId,
    Deallocation[] calldata deallocations,
    address allocateAdapter,
    MarketParams calldata allocateMarket,
    uint256 borrowAmount,
    bool useTarget,
    uint256 minSharesUnlocked
  ) external;
}
