// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {IFacility} from "@grunt/interfaces/facility/IFacility.sol";
import {IntentProperties} from "@grunt/libs/facility/LibIntent.sol";

/// @dev `Facility.totalSupply(uint256)` is a public getter on the Facility implementation but is
///      not declared on `IFacility`, so the guard declares the single view it needs here.
interface IFacilityTotalSupply {
  /// @notice Returns the total supply tracked for an intent.
  /// @param id The intent ID.
  function totalSupply(uint256 id) external view returns (uint256);
}

/// @title DepositCapStateGuard
/// @author 3F Protocol
/// @notice Stateless, read-only guard that asserts a Facility intent's deposit cap and total
///         supply match caller expectations, reverting otherwise.
/// @dev MUST be used as the FIRST call of a batch transaction (e.g. an EIP-7702 batch) executed
///      in the mode where any failing call reverts the whole batch. The batch calls this
///      read-only function first; if the observed on-chain state does not match the expectations
///      encoded when the batch was signed (e.g. a deposit cap changed, or deposits/withdrawals
///      moved the supply outside the tolerated range), the guard reverts and the rest of the
///      batch reverts with it. The guard holds no state and grants no permissions, so it is safe
///      to call by anyone with any arguments.
///
///      The deposit cap is checked for exact equality, while the total supply is checked against
///      an inclusive `[minSupply, maxSupply]` range so that benign concurrent deposits or
///      withdrawals within the tolerated band do not make the batch fail.
contract DepositCapStateGuard {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           STRUCTS                          */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Expected state for a single intent.
  /// @param id          The intent ID.
  /// @param expectedCap The exact deposit cap the intent must have.
  /// @param minSupply   Inclusive lower bound on the intent's total supply.
  /// @param maxSupply   Inclusive upper bound on the intent's total supply. Use
  ///                    `minSupply == maxSupply` to require an exact supply.
  struct Check {
    uint256 id;
    uint256 expectedCap;
    uint256 minSupply;
    uint256 maxSupply;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           ERRORS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when a check's supply bounds are inverted (`minSupply > maxSupply`).
  /// @param id        The intent ID.
  /// @param minSupply The provided lower bound.
  /// @param maxSupply The provided upper bound.
  error InvalidSupplyRange(uint256 id, uint256 minSupply, uint256 maxSupply);

  /// @notice Thrown when an intent's deposit cap differs from the expected value.
  /// @param id          The intent ID.
  /// @param expectedCap The deposit cap expected by the caller.
  /// @param actualCap   The deposit cap currently set on the intent.
  error StaleCap(uint256 id, uint256 expectedCap, uint256 actualCap);

  /// @notice Thrown when an intent's total supply is outside the tolerated range.
  /// @param id           The intent ID.
  /// @param minSupply    Inclusive lower bound expected by the caller.
  /// @param maxSupply    Inclusive upper bound expected by the caller.
  /// @param actualSupply The total supply currently tracked for the intent.
  error SupplyOutOfRange(uint256 id, uint256 minSupply, uint256 maxSupply, uint256 actualSupply);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           CHECKS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Reverts unless every intent in `checks` has exactly the expected deposit cap and a
  ///         total supply within the inclusive `[minSupply, maxSupply]` range.
  /// @dev Call this first in a revert-on-failure batch so a revert here aborts the whole batch
  ///      before any state-changing call executes. Read-only: performs no writes and succeeds
  ///      silently when all checks pass. An empty `checks` array is a no-op.
  /// @param facility The Facility to read intent state from.
  /// @param checks   The per-intent expectations to enforce.
  function requireState(IFacility facility, Check[] calldata checks) external view {
    uint256 length = checks.length;
    for (uint256 i; i < length; i++) {
      Check calldata c = checks[i];
      if (c.minSupply > c.maxSupply) revert InvalidSupplyRange(c.id, c.minSupply, c.maxSupply);

      uint256 supply = IFacilityTotalSupply(address(facility)).totalSupply(c.id);
      if (supply < c.minSupply || supply > c.maxSupply) {
        revert SupplyOutOfRange(c.id, c.minSupply, c.maxSupply, supply);
      }

      (IntentProperties memory props,,,) = facility.getIntent(c.id);
      if (props.depositCap != c.expectedCap) revert StaleCap(c.id, c.expectedCap, props.depositCap);
    }
  }
}
