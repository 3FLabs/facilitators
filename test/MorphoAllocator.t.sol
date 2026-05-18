// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {LibClone} from "solady/utils/LibClone.sol";

import {IFacility} from "@grunt/interfaces/facility/IFacility.sol";
import {IntentProperties, Asset} from "@grunt/libs/facility/LibIntent.sol";
import {Mode, Order} from "@grunt/libs/funds/Order.sol";
import {WithdrawalStrategy} from "@grunt/interfaces/manager/base/IPositionManagerAdmin.sol";

import {IVaultV2} from "@vault-v2/interfaces/IVaultV2.sol";

import {MorphoAllocator} from "src/MorphoAllocator.sol";
import {IMorphoAllocator, Phase, PendingWorkflow} from "src/interfaces/IMorphoAllocator.sol";
import {LibMorphoAllocatorErrors} from "src/libs/LibMorphoAllocatorErrors.sol";

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                            MOCKS                           */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/// @notice Minimal Facility mock. Implements only the methods MorphoAllocator calls.
contract MockFacility {
  error NotFacilitator();

  struct PullCall {
    uint256 id;
    uint256 amount;
  }

  struct CreateCall {
    uint256 id;
    uint256 amount;
    uint256 minAmountOut;
    Mode mode;
  }

  struct DepositManagerCall {
    uint256 id;
    uint256 depositAmount;
    uint256 borrowAmount;
    bool useTarget;
  }

  // Role gating
  mapping(address => bool) public isFacilitator;

  // Intent state knobs
  mapping(uint256 => IntentProperties) internal _props;
  mapping(uint256 => mapping(address => uint256)) internal _balances;
  mapping(uint256 => address[]) internal _tokens;
  mapping(uint256 => bool) internal _tokenSeen;
  mapping(uint256 => mapping(address => bool)) internal _tokenSeenByIntent;

  // Unlock knob: amount of `unlockToken` to credit to the intent on `unlock`.
  uint256 public unlockMintAmount;
  address public unlockToken;

  // Toggle to force `pull` to revert as if FACILITATOR_ROLE were missing.
  bool public pullRevertsForRoleMissing;

  // Recorded calls / ordering
  string[] public callOrder;
  PullCall public lastPull;
  CreateCall public lastCreate;
  uint256 public lastCommitId;
  uint256 public lastUnlockId;
  DepositManagerCall public lastDepositManager;
  uint256 public pullCount;
  uint256 public createCount;
  uint256 public commitCount;
  uint256 public unlockCount;
  uint256 public depositManagerCount;

  /*========== test setup helpers ==========*/

  function setFacilitator(address who, bool enabled) external {
    isFacilitator[who] = enabled;
  }

  function setIntent(uint256 id, IntentProperties memory props) external {
    _props[id] = props;
  }

  function setIntentBalance(uint256 id, address token, uint256 amount) external {
    if (!_tokenSeenByIntent[id][token]) {
      _tokenSeenByIntent[id][token] = true;
      _tokens[id].push(token);
    }
    _balances[id][token] = amount;
  }

  function setUnlockMint(address token, uint256 amount) external {
    unlockToken = token;
    unlockMintAmount = amount;
  }

  function setPullReverts(bool reverts) external {
    pullRevertsForRoleMissing = reverts;
  }

  function callOrderLength() external view returns (uint256) {
    return callOrder.length;
  }

  /*========== IFacility surface used by MorphoAllocator ==========*/

  modifier onlyFacilitator() {
    if (!isFacilitator[msg.sender]) revert NotFacilitator();
    _;
  }

  function pull(uint256 id, uint256 amount) external onlyFacilitator {
    if (pullRevertsForRoleMissing) revert NotFacilitator();
    callOrder.push("pull");
    pullCount++;
    lastPull = PullCall({id: id, amount: amount});
  }

  function create(uint256 id, uint256 amount, uint256 minAmountOut, Mode mode)
    external
    onlyFacilitator
    returns (Order memory order)
  {
    callOrder.push("create");
    createCount++;
    lastCreate = CreateCall({id: id, amount: amount, minAmountOut: minAmountOut, mode: mode});
    order = Order({mode: mode, owner: address(this), receiver: address(this), input: amount, output: 0, salt: 0});
  }

  function commit(uint256 id) external onlyFacilitator {
    callOrder.push("commit");
    commitCount++;
    lastCommitId = id;
  }

  function unlock(uint256 id) external onlyFacilitator {
    callOrder.push("unlock");
    unlockCount++;
    lastUnlockId = id;
    if (unlockMintAmount > 0 && unlockToken != address(0)) {
      if (!_tokenSeenByIntent[id][unlockToken]) {
        _tokenSeenByIntent[id][unlockToken] = true;
        _tokens[id].push(unlockToken);
      }
      _balances[id][unlockToken] += unlockMintAmount;
    }
  }

  function depositManager(uint256 id, uint256 depositAmount, uint256 borrowAmount, bool useTarget) external onlyFacilitator {
    callOrder.push("depositManager");
    depositManagerCount++;
    lastDepositManager = DepositManagerCall({id: id, depositAmount: depositAmount, borrowAmount: borrowAmount, useTarget: useTarget});
  }

  function getIntent(uint256 id)
    external
    view
    returns (IntentProperties memory properties, address fund, address request, bool resolved)
  {
    return (_props[id], address(0), address(0), false);
  }

  function intentBalances(uint256 id) external view returns (address[] memory tokens, uint256[] memory amounts) {
    address[] storage list = _tokens[id];
    uint256 len = list.length;
    tokens = new address[](len);
    amounts = new uint256[](len);
    for (uint256 i = 0; i < len; i++) {
      tokens[i] = list[i];
      amounts[i] = _balances[id][list[i]];
    }
  }
}

/// @notice Minimal Morpho Vault V2 mock for the `allocate` allocator-role check.
contract MockVaultV2 {
  error NotAllocator();

  mapping(address => bool) public isAllocator;

  struct AllocateCall {
    address adapter;
    bytes data;
    uint256 assets;
  }

  AllocateCall public lastAllocate;
  uint256 public allocateCount;

  function setIsAllocator(address who, bool enabled) external {
    isAllocator[who] = enabled;
  }

  function allocate(address adapter, bytes memory data, uint256 assets) external {
    if (!isAllocator[msg.sender]) revert NotAllocator();
    lastAllocate = AllocateCall({adapter: adapter, data: data, assets: assets});
    allocateCount++;
  }
}

/// @notice Minimal PositionManager mock returning fixed `(collateral, debt)`.
contract MockPositionManager {
  address public collateralAsset;
  address public debtAsset;

  constructor(address collateral_, address debt_) {
    collateralAsset = collateral_;
    debtAsset = debt_;
  }

  function assets() external view returns (address, address) {
    return (collateralAsset, debtAsset);
  }
}

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                            TESTS                           */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

contract MorphoAllocatorTest is Test {
  MorphoAllocator internal implementation;
  MorphoAllocator internal allocator;
  MockFacility internal facility;
  MockVaultV2 internal vault;
  MockPositionManager internal pm;

  address internal owner = address(0xA11CE);
  address internal executor = address(0xB0B);
  address internal stranger = address(0xDEAD);

  address internal collateralToken = address(0xC011);
  address internal debtToken = address(0xDEB7);

  address internal adapter = address(0xADAA);
  bytes internal adapterData = abi.encode(bytes32("market-id"));

  uint256 internal constant INTENT_ID = 7;

  event WorkflowStarted(uint256 indexed intentId, uint256 pullAmount, address adapter);
  event WorkflowCompleted(uint256 indexed intentId, uint256 unlocked, uint256 allocateAmount, uint256 borrowAmount);
  event ExecutorSet(address indexed executor, bool enabled);

  function setUp() public {
    facility = new MockFacility();
    vault = new MockVaultV2();
    pm = new MockPositionManager(collateralToken, debtToken);

    implementation = new MorphoAllocator();
    allocator = MorphoAllocator(LibClone.clone(address(implementation)));
    allocator.initialize(owner, executor, IFacility(address(facility)), IVaultV2(address(vault)));

    facility.setFacilitator(address(allocator), true);
    vault.setIsAllocator(address(allocator), true);
  }

  /*========== helpers ==========*/

  function _configureIntentWithTargetPm() internal {
    IntentProperties memory props;
    props.depositAsset = Asset({asset: address(0xDA), isPositionManager: false});
    props.targetAsset = Asset({asset: address(pm), isPositionManager: true});
    facility.setIntent(INTENT_ID, props);
  }

  function _configureIntentWithDepositPm() internal {
    IntentProperties memory props;
    props.depositAsset = Asset({asset: address(pm), isPositionManager: true});
    props.targetAsset = Asset({asset: address(0xDA), isPositionManager: false});
    facility.setIntent(INTENT_ID, props);
  }

  function _startPhase1(uint256 pullAmount, uint256 minSharesOut) internal {
    vm.prank(executor);
    allocator.startWorkflow(INTENT_ID, pullAmount, minSharesOut, adapter, adapterData);
  }

  function _expectInvalidPhase(Phase expected, Phase actual) internal {
    vm.expectRevert(abi.encodeWithSelector(LibMorphoAllocatorErrors.InvalidPhase.selector, INTENT_ID, expected, actual));
  }

  /*========== initialization ==========*/

  function test_initialize_setsState() public {
    assertEq(address(allocator.facility()), address(facility), "facility");
    assertEq(address(allocator.morphoVault()), address(vault), "vault");
    assertEq(allocator.owner(), owner, "owner");
    assertTrue(allocator.hasAnyRole(executor, 1), "executor role");
    PendingWorkflow memory wf = allocator.workflow(INTENT_ID);
    assertEq(uint256(wf.phase), uint256(Phase.IDLE), "phase idle");
  }

  function test_initialize_revertsOnSecondCall() public {
    vm.expectRevert();
    allocator.initialize(owner, executor, IFacility(address(facility)), IVaultV2(address(vault)));
  }

  function test_initialize_zeroExecutorIsAllowed() public {
    MorphoAllocator fresh = MorphoAllocator(LibClone.clone(address(implementation)));
    fresh.initialize(owner, address(0), IFacility(address(facility)), IVaultV2(address(vault)));
    assertFalse(fresh.hasAnyRole(address(0), 1));
  }

  /*========== startWorkflow ==========*/

  function test_startWorkflow_happyPath() public {
    vm.expectEmit(true, false, false, true, address(allocator));
    emit WorkflowStarted(INTENT_ID, 1_000e6, adapter);

    _startPhase1(1_000e6, 990e6);

    assertEq(facility.pullCount(), 1);
    assertEq(facility.createCount(), 1);
    assertEq(facility.commitCount(), 1);

    (uint256 pId, uint256 pAmt) = facility.lastPull();
    assertEq(pId, INTENT_ID);
    assertEq(pAmt, 1_000e6);

    (uint256 cId, uint256 cAmt, uint256 cMin, Mode cMode) = facility.lastCreate();
    assertEq(cId, INTENT_ID);
    assertEq(cAmt, 1_000e6);
    assertEq(cMin, 990e6);
    assertEq(uint256(cMode), uint256(Mode.DEPOSIT));

    assertEq(facility.lastCommitId(), INTENT_ID);

    PendingWorkflow memory wf = allocator.workflow(INTENT_ID);
    assertEq(uint256(wf.phase), uint256(Phase.COMMITTED));
    assertEq(wf.adapter, adapter);
    assertEq(wf.adapterData, adapterData);

    // Ordering: pull → create → commit
    assertEq(facility.callOrder(0), "pull");
    assertEq(facility.callOrder(1), "create");
    assertEq(facility.callOrder(2), "commit");
  }

  function test_startWorkflow_revertsWhenNotIdle() public {
    _startPhase1(1_000e6, 0);

    _expectInvalidPhase(Phase.IDLE, Phase.COMMITTED);
    vm.prank(executor);
    allocator.startWorkflow(INTENT_ID, 1_000e6, 0, adapter, adapterData);
  }

  function test_startWorkflow_revertsWhenNotExecutor() public {
    vm.expectRevert();
    vm.prank(stranger);
    allocator.startWorkflow(INTENT_ID, 1_000e6, 0, adapter, adapterData);
  }

  function test_startWorkflow_revertsWhenFacilityRoleMissing() public {
    facility.setFacilitator(address(allocator), false);
    vm.expectRevert(MockFacility.NotFacilitator.selector);
    vm.prank(executor);
    allocator.startWorkflow(INTENT_ID, 1_000e6, 0, adapter, adapterData);
  }

  /*========== completeWorkflow ==========*/

  function test_completeWorkflow_revertsWhenNotCommitted() public {
    _configureIntentWithTargetPm();
    _expectInvalidPhase(Phase.COMMITTED, Phase.IDLE);
    vm.prank(executor);
    allocator.completeWorkflow(INTENT_ID, 500e6, 700e6, true, 0);
  }

  function test_completeWorkflow_happyPath_useTarget() public {
    _configureIntentWithTargetPm();
    _startPhase1(1_000e6, 0);

    facility.setUnlockMint(collateralToken, 950e6);

    vm.expectEmit(true, false, false, true, address(allocator));
    emit WorkflowCompleted(INTENT_ID, 950e6, 500e6, 700e6);

    vm.prank(executor);
    allocator.completeWorkflow(INTENT_ID, 500e6, 700e6, true, 900e6);

    assertEq(vault.allocateCount(), 1);
    (address aAdapter, bytes memory aData, uint256 aAssets) = vault.lastAllocate();
    assertEq(aAdapter, adapter, "allocate adapter");
    assertEq(aData, adapterData, "allocate data");
    assertEq(aAssets, 500e6, "allocate amount");

    assertEq(facility.depositManagerCount(), 1);
    (uint256 dId, uint256 dDeposit, uint256 dBorrow, bool dUseTarget) = facility.lastDepositManager();
    assertEq(dId, INTENT_ID);
    assertEq(dDeposit, 950e6);
    assertEq(dBorrow, 700e6);
    assertTrue(dUseTarget);

    PendingWorkflow memory wf = allocator.workflow(INTENT_ID);
    assertEq(uint256(wf.phase), uint256(Phase.IDLE), "phase reset");
    assertEq(wf.adapter, address(0));
    assertEq(wf.adapterData.length, 0);
  }

  function test_completeWorkflow_happyPath_useDeposit() public {
    _configureIntentWithDepositPm();
    _startPhase1(1_000e6, 0);

    facility.setUnlockMint(collateralToken, 1_000e6);

    vm.prank(executor);
    allocator.completeWorkflow(INTENT_ID, 0, 700e6, false, 0);

    assertEq(vault.allocateCount(), 0, "allocate skipped when amount=0");

    (uint256 dId, uint256 dDeposit, uint256 dBorrow, bool dUseTarget) = facility.lastDepositManager();
    assertEq(dId, INTENT_ID);
    assertEq(dDeposit, 1_000e6);
    assertEq(dBorrow, 700e6);
    assertFalse(dUseTarget);
  }

  function test_completeWorkflow_revertsOnSlippage() public {
    _configureIntentWithTargetPm();
    _startPhase1(1_000e6, 0);

    facility.setUnlockMint(collateralToken, 800e6);

    vm.expectRevert(abi.encodeWithSelector(LibMorphoAllocatorErrors.SlippageExceeded.selector, 900e6, 800e6));
    vm.prank(executor);
    allocator.completeWorkflow(INTENT_ID, 500e6, 700e6, true, 900e6);

    assertEq(vault.allocateCount(), 0, "allocate not called");
    assertEq(facility.depositManagerCount(), 0, "depositManager not called");

    PendingWorkflow memory wf = allocator.workflow(INTENT_ID);
    assertEq(uint256(wf.phase), uint256(Phase.COMMITTED), "still committed");
  }

  function test_completeWorkflow_revertsIfTargetNotPM() public {
    IntentProperties memory props;
    props.depositAsset = Asset({asset: address(0xDA), isPositionManager: false});
    props.targetAsset = Asset({asset: address(0xFA), isPositionManager: false});
    facility.setIntent(INTENT_ID, props);

    _startPhase1(1_000e6, 0);
    facility.setUnlockMint(collateralToken, 1_000e6);

    vm.expectRevert(abi.encodeWithSelector(LibMorphoAllocatorErrors.TargetNotPositionManager.selector, INTENT_ID, true));
    vm.prank(executor);
    allocator.completeWorkflow(INTENT_ID, 0, 0, true, 0);
  }

  function test_completeWorkflow_revertsWhenAllocatorRoleMissing() public {
    _configureIntentWithTargetPm();
    _startPhase1(1_000e6, 0);
    facility.setUnlockMint(collateralToken, 1_000e6);

    vault.setIsAllocator(address(allocator), false);

    vm.expectRevert(MockVaultV2.NotAllocator.selector);
    vm.prank(executor);
    allocator.completeWorkflow(INTENT_ID, 500e6, 700e6, true, 0);

    PendingWorkflow memory wf = allocator.workflow(INTENT_ID);
    assertEq(uint256(wf.phase), uint256(Phase.COMMITTED), "still committed");
    assertEq(facility.depositManagerCount(), 0, "depositManager not called");
  }

  function test_completeWorkflow_skipsAllocateWhenZero() public {
    _configureIntentWithTargetPm();
    _startPhase1(1_000e6, 0);
    facility.setUnlockMint(collateralToken, 1_000e6);

    vm.prank(executor);
    allocator.completeWorkflow(INTENT_ID, 0, 700e6, true, 0);

    assertEq(vault.allocateCount(), 0);
    assertEq(facility.depositManagerCount(), 1);
  }

  function test_completeWorkflow_adapterLockedIn() public {
    _configureIntentWithTargetPm();
    _startPhase1(1_000e6, 0);
    facility.setUnlockMint(collateralToken, 1_000e6);

    // Phase 2 takes no adapter argument: the locked-in `(adapter, adapterData)` must reach the vault.
    vm.prank(executor);
    allocator.completeWorkflow(INTENT_ID, 123, 0, true, 0);

    (address aAdapter, bytes memory aData,) = vault.lastAllocate();
    assertEq(aAdapter, adapter);
    assertEq(aData, adapterData);
  }

  function test_completeWorkflow_orderingUnlockBeforeAllocate() public {
    _configureIntentWithTargetPm();
    _startPhase1(1_000e6, 0);
    facility.setUnlockMint(collateralToken, 1_000e6);

    uint256 phase1End = facility.callOrderLength();

    vm.prank(executor);
    allocator.completeWorkflow(INTENT_ID, 500e6, 700e6, true, 0);

    // The vault.allocate call does not land in MockFacility.callOrder; verify that
    // unlock occurred before depositManager (allocate happens between them).
    assertEq(facility.callOrder(phase1End), "unlock");
    assertEq(facility.callOrder(phase1End + 1), "depositManager");
    // Vault.allocate was invoked exactly once between unlock and depositManager.
    assertEq(vault.allocateCount(), 1);
  }

  function test_completeWorkflow_revertsWhenNotExecutor() public {
    _configureIntentWithTargetPm();
    _startPhase1(1_000e6, 0);
    facility.setUnlockMint(collateralToken, 1_000e6);

    vm.expectRevert();
    vm.prank(stranger);
    allocator.completeWorkflow(INTENT_ID, 0, 0, true, 0);
  }

  /*========== executor admin ==========*/

  function test_setExecutor_onlyOwner() public {
    vm.expectRevert();
    vm.prank(stranger);
    allocator.setExecutor(stranger, true);

    vm.expectEmit(true, false, false, true, address(allocator));
    emit ExecutorSet(stranger, true);
    vm.prank(owner);
    allocator.setExecutor(stranger, true);
    assertTrue(allocator.hasAnyRole(stranger, 1));

    vm.expectEmit(true, false, false, true, address(allocator));
    emit ExecutorSet(stranger, false);
    vm.prank(owner);
    allocator.setExecutor(stranger, false);
    assertFalse(allocator.hasAnyRole(stranger, 1));
  }

  /*========== multiple intents ==========*/

  function test_multipleIntentsIndependent() public {
    uint256 id1 = INTENT_ID;
    uint256 id2 = INTENT_ID + 1;

    IntentProperties memory props;
    props.targetAsset = Asset({asset: address(pm), isPositionManager: true});
    facility.setIntent(id1, props);
    facility.setIntent(id2, props);

    address adapter2 = address(0xBEEF);
    bytes memory data2 = abi.encode(bytes32("other-market"));

    vm.prank(executor);
    allocator.startWorkflow(id1, 1_000e6, 0, adapter, adapterData);
    vm.prank(executor);
    allocator.startWorkflow(id2, 2_000e6, 0, adapter2, data2);

    PendingWorkflow memory wf1 = allocator.workflow(id1);
    PendingWorkflow memory wf2 = allocator.workflow(id2);
    assertEq(wf1.adapter, adapter);
    assertEq(wf1.adapterData, adapterData);
    assertEq(wf2.adapter, adapter2);
    assertEq(wf2.adapterData, data2);

    // Complete id2 first; id1 must remain COMMITTED.
    facility.setUnlockMint(collateralToken, 1_500e6);
    vm.prank(executor);
    allocator.completeWorkflow(id2, 100, 0, true, 0);

    (address aAdapter, bytes memory aData,) = vault.lastAllocate();
    assertEq(aAdapter, adapter2);
    assertEq(aData, data2);

    assertEq(uint256(allocator.workflow(id1).phase), uint256(Phase.COMMITTED));
    assertEq(uint256(allocator.workflow(id2).phase), uint256(Phase.IDLE));
  }

  /*========== fuzz ==========*/

  function testFuzz_slippageBoundary(uint256 minOut, uint128 actual128) public {
    minOut = bound(minOut, 0, type(uint128).max);
    uint256 actual = uint256(actual128);

    _configureIntentWithTargetPm();
    _startPhase1(1_000e6, 0);
    facility.setUnlockMint(collateralToken, actual);

    if (actual < minOut) {
      vm.expectRevert(abi.encodeWithSelector(LibMorphoAllocatorErrors.SlippageExceeded.selector, minOut, actual));
      vm.prank(executor);
      allocator.completeWorkflow(INTENT_ID, 0, 0, true, minOut);
      assertEq(uint256(allocator.workflow(INTENT_ID).phase), uint256(Phase.COMMITTED));
    } else {
      vm.prank(executor);
      allocator.completeWorkflow(INTENT_ID, 0, 0, true, minOut);
      assertEq(uint256(allocator.workflow(INTENT_ID).phase), uint256(Phase.IDLE));
    }
  }
}
