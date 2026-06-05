// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Initializable} from "solady/utils/Initializable.sol";
import {OwnableRoles} from "solady/auth/OwnableRoles.sol";
import {Multicallable} from "solady/utils/Multicallable.sol";

import {IFacility} from "@grunt/interfaces/facility/IFacility.sol";
import {Mode, Order, State} from "@grunt/libs/funds/Order.sol";
import {IFund} from "@grunt/interfaces/funds/IFund.sol";

/// @title CommitDeposit
/// @author 3F Protocol
/// @notice Grunt Smart Facilitator script: pulls Bridge Facilitator funds from the Request, creates a
///         fund DEPOSIT order against the intent's fund, and commits it (asserting `PROCESSING`).
/// @dev Must hold `FACILITATOR_ROLE` on the target Facility. Proxy-ready via Solady `Initializable`
///      and ERC-7201 namespaced storage. Inherits `Multicallable` so the executor can batch calls.
contract CommitDeposit is OwnableRoles, Initializable, Multicallable {
  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           ROLES                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Role for addresses authorized to trigger the `run` workflow.
  uint256 internal constant EXECUTOR_ROLE = _ROLE_0;

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          EVENTS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Emitted when the pull + create + commit sequence succeeds for an intent.
  /// @param intentId     The intent ID.
  /// @param pullAmount   The amount pulled from the Request.
  /// @param commitAmount The fund order input amount that was created and committed.
  /// @param order        The fund order created and committed for the intent.
  event DepositCommitted(uint256 indexed intentId, uint256 pullAmount, uint256 commitAmount, Order order);

  /// @notice Emitted when the executor role is granted to or revoked from an address.
  /// @param executor The affected address.
  /// @param enabled  True if granted, false if revoked.
  event ExecutorSet(address indexed executor, bool enabled);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                          STORAGE                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @dev Storage slot for the CommitDeposit's namespaced storage struct.
  ///      Computed as `keccak256(abi.encode(uint256(keccak256("commit_deposit")) - 1)) & ~bytes32(uint256(0xff))`.
  ///      Follows the ERC-7201 namespaced storage pattern to prevent storage collisions in proxies
  ///      and inheritance hierarchies.
  bytes32 private constant STORAGE_SLOT = 0x1de377dc444a665e24c5e5d937129f713af4ba51721c858650e34bf6d9442200;

  /// @notice Storage struct containing all persistent state for the CommitDeposit contract.
  /// @dev Uses ERC-7201 namespaced storage for proxy compatibility, accessed via a fixed storage slot
  ///      to prevent collisions with inherited contracts.
  /// @param facility The Grunt Facility this script is a facilitator on.
  struct CommitDepositStorage {
    IFacility facility;
  }

  /// @dev Returns a reference to the contract's namespaced storage struct.
  ///      Loads the storage pointer from the fixed `STORAGE_SLOT`, ensuring a consistent
  ///      storage layout when used behind proxies.
  /// @return data A storage pointer to the `CommitDepositStorage` struct.
  function _depositStorage() private pure returns (CommitDepositStorage storage data) {
    assembly ("memory-safe") {
      data.slot := STORAGE_SLOT
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           ERRORS                           */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Thrown when the owner address is zero during initialization.
  error OwnerZeroAddress();

  /// @notice Thrown when the Facility address has no code during initialization.
  error FacilityNotContract();

  /// @notice Thrown when the fund order is not in the expected state after the commit.
  /// @param expected The required order state.
  /// @param actual   The order state actually observed.
  error UnexpectedOrderState(State expected, State actual);

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                       INITIALIZATION                       */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Locks the implementation contract from being initialized directly.
  /// @dev Required when the contract is deployed behind a proxy.
  constructor() {
    _disableInitializers();
  }

  /// @notice Initializes the CommitDeposit.
  /// @dev Can only be called once due to the `initializer` modifier. Grants `EXECUTOR_ROLE`
  ///      to `executor_` when it is non-zero. The Facility owner must separately grant
  ///      `FACILITATOR_ROLE` to this contract.
  /// @param owner_    Address granted owner privileges.
  /// @param executor_ Address granted EXECUTOR_ROLE (pass address(0) to skip).
  /// @param facility_ The Grunt Facility this script coordinates.
  function initialize(address owner_, address executor_, IFacility facility_) external initializer {
    _initializeOwner(owner_);

    require(owner_ != address(0), OwnerZeroAddress());
    require(address(facility_).code.length > 0, FacilityNotContract());

    CommitDepositStorage storage $ = _depositStorage();
    $.facility = facility_;

    if (executor_ != address(0)) {
      _grantRoles(executor_, EXECUTOR_ROLE);
      emit ExecutorSet(executor_, true);
    }
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                           VIEWS                            */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Returns the configured Facility address.
  /// @return The Grunt Facility this script coordinates.
  function facility() external view returns (IFacility) {
    return _depositStorage().facility;
  }

  /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
  /*                            RUN                             */
  /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

  /// @notice Pull Request funds, create a DEPOSIT fund order against the intent's fund, and commit it.
  /// @dev Atomic sequence: `Facility.pull(pullAmount)` → `Facility.create(commitAmount, DEPOSIT)`
  ///      → `Facility.commit` → assert the order is in `State.PROCESSING`.
  /// @param intentId     The intent ID.
  /// @param pullAmount   The amount of bridge-loan asset to pull from the Request.
  /// @param commitAmount The DEPOSIT order input amount to create and commit (may differ from pullAmount).
  /// @param minSharesOut Minimum shares the DEPOSIT order must mint (slippage guard on fund side).
  function run(uint256 intentId, uint256 pullAmount, uint256 commitAmount, uint256 minSharesOut)
    external
    onlyRoles(EXECUTOR_ROLE)
  {
    IFacility _facility = _depositStorage().facility;
    _facility.pull(intentId, pullAmount);
    Order memory order = _facility.create(intentId, commitAmount, minSharesOut, Mode.DEPOSIT);
    _facility.commit(intentId);

    (, address fund,,) = _facility.getIntent(intentId);
    State orderState = IFund(fund).state(order);
    if (orderState != State.PROCESSING) revert UnexpectedOrderState(State.PROCESSING, orderState);

    emit DepositCommitted(intentId, pullAmount, commitAmount, order);
  }
}
