// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";

import {IFacility} from "@grunt/interfaces/facility/IFacility.sol";
import {IntentProperties} from "@grunt/libs/facility/LibIntent.sol";

import {DepositCapStateGuard} from "src/checks/DepositCapStateGuard.sol";

import {MockFacility} from "./MorphoAllocator.t.sol";

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                            TESTS                           */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

contract DepositCapStateGuardTest is Test {
  DepositCapStateGuard internal guard;
  MockFacility internal facility;

  uint256 internal constant INTENT_ID = 7;
  uint256 internal constant CAP = 1_000_000e6;
  uint256 internal constant SUPPLY = 400_000e6;

  function setUp() public {
    facility = new MockFacility();
    guard = new DepositCapStateGuard();

    _setIntent(INTENT_ID, CAP, SUPPLY);
  }

  /*========== helpers ==========*/

  function _setIntent(uint256 id, uint256 cap, uint256 supply) internal {
    IntentProperties memory props;
    props.depositCap = cap;
    facility.setIntent(id, props);
    facility.setTotalSupply(id, supply);
  }

  function _check(uint256 id, uint256 expectedCap, uint256 minSupply, uint256 maxSupply)
    internal
    pure
    returns (DepositCapStateGuard.Check memory)
  {
    return DepositCapStateGuard.Check({id: id, expectedCap: expectedCap, minSupply: minSupply, maxSupply: maxSupply});
  }

  function _requireState(DepositCapStateGuard.Check[] memory checks) internal view {
    guard.requireState(IFacility(address(facility)), checks);
  }

  /*========== passing checks ==========*/

  function test_requireState_passesWithinRange() public view {
    DepositCapStateGuard.Check[] memory checks = new DepositCapStateGuard.Check[](1);
    checks[0] = _check(INTENT_ID, CAP, SUPPLY - 100e6, SUPPLY + 100e6);
    _requireState(checks);
  }

  function test_requireState_passesOnExactBounds() public view {
    // minSupply == maxSupply == supply degenerates to an exact-supply check.
    DepositCapStateGuard.Check[] memory checks = new DepositCapStateGuard.Check[](1);
    checks[0] = _check(INTENT_ID, CAP, SUPPLY, SUPPLY);
    _requireState(checks);
  }

  function test_requireState_passesOnInclusiveEdges() public {
    DepositCapStateGuard.Check[] memory checks = new DepositCapStateGuard.Check[](1);

    facility.setTotalSupply(INTENT_ID, SUPPLY);
    checks[0] = _check(INTENT_ID, CAP, SUPPLY, SUPPLY + 1);
    _requireState(checks);

    checks[0] = _check(INTENT_ID, CAP, SUPPLY - 1, SUPPLY);
    _requireState(checks);
  }

  function test_requireState_passesOnEmptyChecks() public view {
    _requireState(new DepositCapStateGuard.Check[](0));
  }

  function test_requireState_passesOnMultipleIntents() public {
    _setIntent(8, CAP * 2, SUPPLY * 2);

    DepositCapStateGuard.Check[] memory checks = new DepositCapStateGuard.Check[](2);
    checks[0] = _check(INTENT_ID, CAP, 0, SUPPLY);
    checks[1] = _check(8, CAP * 2, SUPPLY, type(uint256).max);
    _requireState(checks);
  }

  /*========== reverting checks ==========*/

  function test_requireState_revertsWhenSupplyBelowRange() public {
    DepositCapStateGuard.Check[] memory checks = new DepositCapStateGuard.Check[](1);
    checks[0] = _check(INTENT_ID, CAP, SUPPLY + 1, SUPPLY + 100e6);

    vm.expectRevert(
      abi.encodeWithSelector(
        DepositCapStateGuard.SupplyOutOfRange.selector, INTENT_ID, SUPPLY + 1, SUPPLY + 100e6, SUPPLY
      )
    );
    _requireState(checks);
  }

  function test_requireState_revertsWhenSupplyAboveRange() public {
    DepositCapStateGuard.Check[] memory checks = new DepositCapStateGuard.Check[](1);
    checks[0] = _check(INTENT_ID, CAP, 0, SUPPLY - 1);

    vm.expectRevert(
      abi.encodeWithSelector(DepositCapStateGuard.SupplyOutOfRange.selector, INTENT_ID, 0, SUPPLY - 1, SUPPLY)
    );
    _requireState(checks);
  }

  function test_requireState_revertsOnStaleCap() public {
    DepositCapStateGuard.Check[] memory checks = new DepositCapStateGuard.Check[](1);
    checks[0] = _check(INTENT_ID, CAP + 1, 0, type(uint256).max);

    vm.expectRevert(abi.encodeWithSelector(DepositCapStateGuard.StaleCap.selector, INTENT_ID, CAP + 1, CAP));
    _requireState(checks);
  }

  function test_requireState_revertsOnInvertedRange() public {
    DepositCapStateGuard.Check[] memory checks = new DepositCapStateGuard.Check[](1);
    checks[0] = _check(INTENT_ID, CAP, SUPPLY + 1, SUPPLY - 1);

    vm.expectRevert(
      abi.encodeWithSelector(DepositCapStateGuard.InvalidSupplyRange.selector, INTENT_ID, SUPPLY + 1, SUPPLY - 1)
    );
    _requireState(checks);
  }

  function test_requireState_revertsWhenAnyCheckFails() public {
    // First intent passes; the second intent's stale cap must still revert the whole call.
    _setIntent(8, CAP * 2, SUPPLY * 2);

    DepositCapStateGuard.Check[] memory checks = new DepositCapStateGuard.Check[](2);
    checks[0] = _check(INTENT_ID, CAP, 0, type(uint256).max);
    checks[1] = _check(8, CAP, 0, type(uint256).max);

    vm.expectRevert(abi.encodeWithSelector(DepositCapStateGuard.StaleCap.selector, 8, CAP, CAP * 2));
    _requireState(checks);
  }

  /*========== fuzz ==========*/

  function testFuzz_requireState_supplyRange(uint256 supply, uint256 minSupply, uint256 maxSupply) public {
    vm.assume(minSupply <= maxSupply);
    facility.setTotalSupply(INTENT_ID, supply);

    DepositCapStateGuard.Check[] memory checks = new DepositCapStateGuard.Check[](1);
    checks[0] = _check(INTENT_ID, CAP, minSupply, maxSupply);

    if (supply < minSupply || supply > maxSupply) {
      vm.expectRevert(
        abi.encodeWithSelector(DepositCapStateGuard.SupplyOutOfRange.selector, INTENT_ID, minSupply, maxSupply, supply)
      );
    }
    _requireState(checks);
  }
}
