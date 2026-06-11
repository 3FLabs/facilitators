// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {LibClone} from "solady/utils/LibClone.sol";

import {IFacility} from "@grunt/interfaces/facility/IFacility.sol";
import {Mode, Order, State} from "@grunt/libs/funds/Order.sol";

import {CommitDeposit} from "src/CommitDeposit.sol";

import {MockFacility} from "./MorphoAllocator.t.sol";

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                            TESTS                           */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

contract CommitDepositTest is Test {
  CommitDeposit internal implementation;
  CommitDeposit internal commitDeposit;
  MockFacility internal facility;

  address internal owner = address(0xA11CE);
  address internal executor = address(0xB0B);
  address internal stranger = address(0xDEAD);

  uint256 internal constant INTENT_ID = 7;

  event DepositCommitted(uint256 indexed intentId, uint256 pullAmount, uint256 commitAmount, Order order);
  event ExecutorSet(address indexed executor, bool enabled);

  function setUp() public {
    facility = new MockFacility();

    implementation = new CommitDeposit();
    commitDeposit = CommitDeposit(LibClone.clone(address(implementation)));
    commitDeposit.initialize(owner, executor, IFacility(address(facility)));

    facility.setFacilitator(address(commitDeposit), true);
  }

  /*========== helpers ==========*/

  /// @dev The deterministic order MockFacility.create returns for a given commit amount.
  function _expectedOrder(uint256 commitAmount) internal view returns (Order memory) {
    return Order({
      mode: Mode.DEPOSIT,
      owner: address(facility),
      receiver: address(facility),
      input: commitAmount,
      output: 0,
      salt: bytes32(0)
    });
  }

  /*========== initialization ==========*/

  function test_initialize_setsState() public view {
    assertEq(address(commitDeposit.facility()), address(facility), "facility");
    assertEq(commitDeposit.owner(), owner, "owner");
    assertTrue(commitDeposit.hasAnyRole(executor, 1), "executor role");
  }

  function test_initialize_revertsOnSecondCall() public {
    vm.expectRevert();
    commitDeposit.initialize(owner, executor, IFacility(address(facility)));
  }

  function test_initialize_zeroExecutorIsAllowed() public {
    CommitDeposit fresh = CommitDeposit(LibClone.clone(address(implementation)));
    fresh.initialize(owner, address(0), IFacility(address(facility)));
    assertFalse(fresh.hasAnyRole(address(0), 1));
  }

  /*========== run ==========*/

  function test_run_happyPath() public {
    // pullAmount and commitAmount differ to prove `create` is wired to commitAmount.
    vm.expectEmit(true, false, false, true, address(commitDeposit));
    emit DepositCommitted(INTENT_ID, 1_000e6, 900e6, _expectedOrder(900e6));

    vm.prank(executor);
    commitDeposit.run(INTENT_ID, 1_000e6, 900e6, 880e6);

    assertEq(facility.pullCount(), 1);
    assertEq(facility.createCount(), 1);
    assertEq(facility.commitCount(), 1);

    (, uint256 pAmt) = facility.lastPull();
    assertEq(pAmt, 1_000e6, "pull uses pullAmount");

    (uint256 cId, uint256 cAmt, uint256 cMin, Mode cMode) = facility.lastCreate();
    assertEq(cId, INTENT_ID);
    assertEq(cAmt, 900e6, "create uses commitAmount");
    assertEq(cMin, 880e6);
    assertEq(uint256(cMode), uint256(Mode.DEPOSIT));

    assertEq(facility.lastCommitId(), INTENT_ID);

    // Ordering: pull → create → commit
    assertEq(facility.callOrder(0), "pull");
    assertEq(facility.callOrder(1), "create");
    assertEq(facility.callOrder(2), "commit");
  }

  function test_run_emitsOrder() public {
    // The created+committed order is surfaced in the event; its `input` is the commitAmount
    // (distinct from pullAmount here to prove the wiring).
    vm.expectEmit(true, false, false, true, address(commitDeposit));
    emit DepositCommitted(INTENT_ID, 2_000e6, 1_234e6, _expectedOrder(1_234e6));

    vm.prank(executor);
    commitDeposit.run(INTENT_ID, 2_000e6, 1_234e6, 0);
  }

  function test_run_revertsWhenOrderNotProcessing() public {
    facility.setCommitState(State.UNLOCKING);
    vm.expectRevert(
      abi.encodeWithSelector(CommitDeposit.UnexpectedOrderState.selector, State.PROCESSING, State.UNLOCKING)
    );
    vm.prank(executor);
    commitDeposit.run(INTENT_ID, 1_000e6, 1_000e6, 0);
  }

  function test_run_revertsWhenNotExecutor() public {
    vm.expectRevert();
    vm.prank(stranger);
    commitDeposit.run(INTENT_ID, 1_000e6, 1_000e6, 0);
  }

  function test_run_revertsWhenFacilityRoleMissing() public {
    facility.setFacilitator(address(commitDeposit), false);
    vm.expectRevert(MockFacility.NotFacilitator.selector);
    vm.prank(executor);
    commitDeposit.run(INTENT_ID, 1_000e6, 1_000e6, 0);
  }

  /*========== multiple intents ==========*/

  function test_multipleIntentsIndependent() public {
    uint256 id1 = INTENT_ID;
    uint256 id2 = INTENT_ID + 1;

    vm.prank(executor);
    commitDeposit.run(id1, 1_000e6, 1_000e6, 0);
    vm.prank(executor);
    commitDeposit.run(id2, 2_000e6, 2_000e6, 0);

    assertEq(facility.commitCount(), 2, "both intents committed");
  }
}
