// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

/// @notice Lifecycle phase of an intent's workflow on the MorphoAllocator.
/// @dev IDLE indicates no in-flight workflow; COMMITTED indicates Phase 1 has succeeded
///      and Phase 2 is the only valid next step.
enum Phase {
  /// @notice No workflow is in flight for this intent.
  IDLE,
  /// @notice Phase 1 completed: a DEPOSIT fund order has been committed for this intent.
  COMMITTED
}

/// @title IMorphoAllocator
/// @author 3F Protocol
/// @notice External API for the MorphoAllocator Smart Facilitator.
/// @dev Exposes events, views, admin, and the two workflow phase functions. The contract
///      implementing this interface must hold `FACILITATOR_ROLE` on the target Facility and
///      `isAllocator = true` on the target Morpho Vault V2.
interface IMorphoAllocator {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          EVENTS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Emitted when Phase 1 (pull + create + commit) succeeds for an intent.
  /// @param intentId   The intent ID.
  /// @param pullAmount The amount pulled from the Request and used as the fund order input.
  event WorkflowStarted(uint256 indexed intentId, uint256 pullAmount);

  /// @notice Emitted when Phase 2 (unlock + allocate + depositManager) succeeds for an intent.
  /// @param intentId       The intent ID.
  /// @param unlocked       The amount of collateral credited to the intent by `unlock`.
  /// @param adapter        The adapter liquidity was allocated through (ignored when allocateAmount == 0).
  /// @param allocateAmount The amount reallocated through `adapter` (0 if skipped).
  /// @param borrowAmount   The amount borrowed via `Facility.depositManager`.
  event WorkflowCompleted(
    uint256 indexed intentId, uint256 unlocked, address adapter, uint256 allocateAmount, uint256 borrowAmount
  );

  /// @notice Emitted when the executor role is granted to or revoked from an address.
  /// @param executor The affected address.
  /// @param enabled  True if granted, false if revoked.
  event ExecutorSet(address indexed executor, bool enabled);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           VIEWS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Returns the workflow phase stored for an intent.
  /// @param intentId The intent ID.
  /// @return The current `Phase` (IDLE or COMMITTED).
  function workflow(uint256 intentId) external view returns (Phase);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          PHASES                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Phase 1 — pull Bridge Facilitator funds from the Request, create a DEPOSIT fund
  ///         order against the intent's fund, and commit it.
  /// @dev Requires the intent's workflow to be in `Phase.IDLE`.
  /// @param intentId     The intent ID.
  /// @param pullAmount   The amount of bridge-loan asset to pull and use as the order input.
  /// @param minSharesOut Minimum shares the DEPOSIT order must mint (slippage guard on fund side).
  function start(uint256 intentId, uint256 pullAmount, uint256 minSharesOut) external;

  /// @notice Phase 2 — unlock the matured fund order, reallocate Morpho Vault V2 liquidity into
  ///         the target Morpho Blue market, then deposit the unlocked collateral and borrow.
  /// @dev Requires the intent's workflow to be in `Phase.COMMITTED`. Ordering inside the call is
  ///      unlock → allocate → depositManager. Allocation is skipped when `allocateAmount == 0`.
  /// @param intentId          The intent ID.
  /// @param adapter           The Morpho Vault V2 adapter to allocate through (ignored when allocateAmount == 0).
  /// @param adapterData       ABI-encoded adapter parameters identifying the target market.
  /// @param allocateAmount    Amount to allocate through `adapter` (0 to skip).
  /// @param borrowAmount      Amount to borrow via `Facility.depositManager`.
  /// @param useTarget         True to use the intent's target asset as the PositionManager,
  ///                          false to use the deposit asset.
  /// @param minSharesUnlocked Minimum amount that must be unlocked (slippage guard on unlock).
  function complete(
    uint256 intentId,
    address adapter,
    bytes calldata adapterData,
    uint256 allocateAmount,
    uint256 borrowAmount,
    bool useTarget,
    uint256 minSharesUnlocked
  ) external;
}
