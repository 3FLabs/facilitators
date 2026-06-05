// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {LibClone} from "solady/utils/LibClone.sol";

import {IFacility} from "@grunt/interfaces/facility/IFacility.sol";
import {IntentProperties, Asset} from "@grunt/libs/facility/LibIntent.sol";
import {Mode, Order, State} from "@grunt/libs/funds/Order.sol";

import {IVaultV2} from "@vault-v2/interfaces/IVaultV2.sol";

import {MarketParams, Id, Market} from "@morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@morpho-blue/libraries/MarketParamsLib.sol";

import {MorphoAllocator} from "src/MorphoAllocator.sol";

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                            MOCKS                           */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/// @notice Minimal Facility mock. Implements only the methods MorphoAllocator calls, and doubles as
///         the intent's `IFund` by exposing `state(Order)`. `commit`/`unlock` drive the order state
///         to configurable values so the allocator's PROCESSING/ENDED assertions can be exercised.
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
  mapping(uint256 => mapping(address => bool)) internal _tokenSeenByIntent;
  mapping(uint256 => Order) internal _orders;

  // Unlock knob: amount of `unlockToken` to credit to the intent on `unlock`.
  uint256 public unlockMintAmount;
  address public unlockToken;

  // Order-state knobs: state the order moves to after commit() / unlock().
  State public orderState;
  State public commitState = State.PROCESSING;
  State public unlockState = State.ENDED;

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

  function setCommitState(State s) external {
    commitState = s;
  }

  function setUnlockState(State s) external {
    unlockState = s;
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
    _orders[id] = order;
  }

  function commit(uint256 id) external onlyFacilitator {
    callOrder.push("commit");
    commitCount++;
    lastCommitId = id;
    orderState = commitState;
  }

  function unlock(uint256 id) external onlyFacilitator {
    callOrder.push("unlock");
    unlockCount++;
    lastUnlockId = id;
    orderState = unlockState;
    if (unlockMintAmount > 0 && unlockToken != address(0)) {
      if (!_tokenSeenByIntent[id][unlockToken]) {
        _tokenSeenByIntent[id][unlockToken] = true;
        _tokens[id].push(unlockToken);
      }
      _balances[id][unlockToken] += unlockMintAmount;
    }
  }

  function depositManager(uint256 id, uint256 depositAmount, uint256 borrowAmount, bool useTarget)
    external
    onlyFacilitator
  {
    callOrder.push("depositManager");
    depositManagerCount++;
    lastDepositManager =
      DepositManagerCall({id: id, depositAmount: depositAmount, borrowAmount: borrowAmount, useTarget: useTarget});
  }

  function getIntent(uint256 id)
    external
    view
    returns (IntentProperties memory properties, address fund, address request, bool resolved)
  {
    // The facility itself plays the IFund role for the allocator's state assertions.
    return (_props[id], address(this), address(0), false);
  }

  function getOrder(uint256 id) external view returns (Order memory order, bytes32 orderId) {
    return (_orders[id], bytes32(0));
  }

  /// @notice Stand-in for `IFund.state(Order)` — the allocator queries this after commit/unlock.
  function state(Order calldata) external view returns (State) {
    return orderState;
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

/// @notice Minimal Morpho Vault V2 mock recording `allocate`/`deallocate` under the allocator-role check.
contract MockVaultV2 {
  error NotAllocator();

  mapping(address => bool) public isAllocator;

  struct MoveCall {
    address adapter;
    bytes data;
    uint256 assets;
  }

  MoveCall public lastAllocate;
  MoveCall public lastDeallocate;
  uint256 public allocateCount;
  uint256 public deallocateCount;

  function setIsAllocator(address who, bool enabled) external {
    isAllocator[who] = enabled;
  }

  function allocate(address adapter, bytes memory data, uint256 assets) external {
    if (!isAllocator[msg.sender]) revert NotAllocator();
    lastAllocate = MoveCall({adapter: adapter, data: data, assets: assets});
    allocateCount++;
  }

  function deallocate(address adapter, bytes memory data, uint256 assets) external {
    if (!isAllocator[msg.sender]) revert NotAllocator();
    lastDeallocate = MoveCall({adapter: adapter, data: data, assets: assets});
    deallocateCount++;
  }
}

/// @notice Minimal Morpho Blue mock returning settable per-market totals for utilisation checks.
contract MockMorpho {
  mapping(bytes32 => Market) internal _markets;

  function setMarket(Id id, uint128 totalSupplyAssets, uint128 totalBorrowAssets) external {
    Market storage m = _markets[Id.unwrap(id)];
    m.totalSupplyAssets = totalSupplyAssets;
    m.totalBorrowAssets = totalBorrowAssets;
  }

  function market(Id id) external view returns (Market memory) {
    return _markets[Id.unwrap(id)];
  }
}

/// @notice Minimal Morpho V1 Market adapter mock exposing only `morpho()`, used by the utilisation check.
contract MockMarketAdapter {
  address public morpho;

  constructor(address morpho_) {
    morpho = morpho_;
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
  using MarketParamsLib for MarketParams;

  MorphoAllocator internal implementation;
  MorphoAllocator internal allocator;
  MockFacility internal facility;
  MockVaultV2 internal vault;
  MockPositionManager internal pm;
  MockMorpho internal morpho;
  MockMarketAdapter internal dealAdapter;

  address internal owner = address(0xA11CE);
  address internal executor = address(0xB0B);
  address internal stranger = address(0xDEAD);

  address internal collateralToken = address(0xC011);
  address internal debtToken = address(0xDEB7);

  // Allocation destination adapter; vault.allocate is mocked so it need not be a real adapter.
  address internal allocAdapter = address(0xA110C);

  MarketParams internal sourceMarket;
  MarketParams internal targetMarket;

  uint256 internal constant INTENT_ID = 7;
  uint256 internal constant WAD = 1e18;

  event Allocated(
    uint256 indexed intentId, uint256 unlocked, address allocateAdapter, uint256 allocatedTotal, uint256 borrowAmount
  );
  event ExecutorSet(address indexed executor, bool enabled);

  function setUp() public {
    facility = new MockFacility();
    vault = new MockVaultV2();
    pm = new MockPositionManager(collateralToken, debtToken);
    morpho = new MockMorpho();
    dealAdapter = new MockMarketAdapter(address(morpho));

    sourceMarket = MarketParams({
      loanToken: collateralToken,
      collateralToken: address(0xC1),
      oracle: address(0xC2),
      irm: address(0xC3),
      lltv: 0.8e18
    });
    targetMarket = MarketParams({
      loanToken: collateralToken,
      collateralToken: address(0xD1),
      oracle: address(0xD2),
      irm: address(0xD3),
      lltv: 0.86e18
    });

    // Default source market: utilisation 0.1e18, well under any cap used in happy-path tests.
    morpho.setMarket(sourceMarket.id(), 1_000e6, 100e6);

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

  /// @dev A single market-sourced deallocation from the default `sourceMarket` via `dealAdapter`.
  function _deals(uint256 amount, uint256 maxUtilisation)
    internal
    view
    returns (MorphoAllocator.Deallocation[] memory deals)
  {
    deals = new MorphoAllocator.Deallocation[](1);
    deals[0] = MorphoAllocator.Deallocation({
      adapter: address(dealAdapter), marketParams: sourceMarket, amount: amount, maxUtilisation: maxUtilisation
    });
  }

  function _noDeals() internal pure returns (MorphoAllocator.Deallocation[] memory deals) {
    deals = new MorphoAllocator.Deallocation[](0);
  }

  /*========== initialization ==========*/

  function test_initialize_setsState() public {
    assertEq(address(allocator.facility()), address(facility), "facility");
    assertEq(address(allocator.morphoVault()), address(vault), "vault");
    assertEq(allocator.owner(), owner, "owner");
    assertTrue(allocator.hasAnyRole(executor, 1), "executor role");
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

  /*========== run ==========*/

  function test_run_runsStandalone() public {
    // `run` only needs a committed, matured order; the commit may have been performed by any
    // facilitator (e.g. the CommitDeposit script). With the intent configured and unlock crediting
    // collateral, the call goes through.
    _configureIntentWithTargetPm();
    facility.setUnlockMint(collateralToken, 1_000e6);

    vm.prank(executor);
    allocator.run(INTENT_ID, _deals(500e6, WAD), allocAdapter, targetMarket, 1_000e6, 700e6, true, 0);

    assertEq(vault.deallocateCount(), 1);
    assertEq(vault.allocateCount(), 1);
    assertEq(facility.depositManagerCount(), 1);
  }

  function test_run_happyPath_useTarget() public {
    _configureIntentWithTargetPm();
    facility.setUnlockMint(collateralToken, 950e6);

    vm.expectEmit(true, false, false, true, address(allocator));
    emit Allocated(INTENT_ID, 950e6, allocAdapter, 500e6, 700e6);

    vm.prank(executor);
    allocator.run(INTENT_ID, _deals(500e6, WAD), allocAdapter, targetMarket, 950e6, 700e6, true, 900e6);

    // Deallocation withdrew 500e6 from the source market.
    assertEq(vault.deallocateCount(), 1);
    (address dAdapter, bytes memory dData, uint256 dAssets) = vault.lastDeallocate();
    assertEq(dAdapter, address(dealAdapter), "deallocate adapter");
    assertEq(dData, abi.encode(sourceMarket), "deallocate data");
    assertEq(dAssets, 500e6, "deallocate amount");

    // The gathered total (500e6) was allocated into the destination market.
    assertEq(vault.allocateCount(), 1);
    (address aAdapter, bytes memory aData, uint256 aAssets) = vault.lastAllocate();
    assertEq(aAdapter, allocAdapter, "allocate adapter");
    assertEq(aData, abi.encode(targetMarket), "allocate data");
    assertEq(aAssets, 500e6, "allocate total");

    assertEq(facility.depositManagerCount(), 1);
    (uint256 dId, uint256 dDeposit, uint256 dBorrow, bool dUseTarget) = facility.lastDepositManager();
    assertEq(dId, INTENT_ID);
    assertEq(dDeposit, 950e6);
    assertEq(dBorrow, 700e6);
    assertTrue(dUseTarget);
  }

  function test_run_depositAmountIndependentOfUnlocked() public {
    _configureIntentWithTargetPm();
    facility.setUnlockMint(collateralToken, 1_000e6); // full unlock = 1_000e6

    // Deposit only 600e6 of the 1_000e6 unlocked; the event still reports the full unlocked amount.
    vm.expectEmit(true, false, false, true, address(allocator));
    emit Allocated(INTENT_ID, 1_000e6, allocAdapter, 500e6, 700e6);

    vm.prank(executor);
    allocator.run(INTENT_ID, _deals(500e6, WAD), allocAdapter, targetMarket, 600e6, 700e6, true, 0);

    (, uint256 dDeposit,,) = facility.lastDepositManager();
    assertEq(dDeposit, 600e6, "depositManager uses the provided amount, not unlocked");
  }

  function test_run_happyPath_useDeposit_noRebalance() public {
    _configureIntentWithDepositPm();
    facility.setUnlockMint(collateralToken, 1_000e6);

    vm.prank(executor);
    allocator.run(INTENT_ID, _noDeals(), address(0), targetMarket, 1_000e6, 700e6, false, 0);

    assertEq(vault.deallocateCount(), 0, "no deallocation");
    assertEq(vault.allocateCount(), 0, "allocate skipped (no sources)");

    (uint256 dId, uint256 dDeposit, uint256 dBorrow, bool dUseTarget) = facility.lastDepositManager();
    assertEq(dId, INTENT_ID);
    assertEq(dDeposit, 1_000e6);
    assertEq(dBorrow, 700e6);
    assertFalse(dUseTarget);
  }

  function test_run_idleSourceSkipsDeallocate() public {
    _configureIntentWithTargetPm();
    facility.setUnlockMint(collateralToken, 1_000e6);

    // adapter == address(0): the 300e6 is sourced from idle liquidity, no deallocate / util check.
    MorphoAllocator.Deallocation[] memory deals = new MorphoAllocator.Deallocation[](1);
    deals[0] =
      MorphoAllocator.Deallocation({adapter: address(0), marketParams: sourceMarket, amount: 300e6, maxUtilisation: 0});

    vm.prank(executor);
    allocator.run(INTENT_ID, deals, allocAdapter, targetMarket, 1_000e6, 0, true, 0);

    assertEq(vault.deallocateCount(), 0, "no deallocate for idle source");
    assertEq(vault.allocateCount(), 1, "allocate of gathered total");
    (,, uint256 aAssets) = vault.lastAllocate();
    assertEq(aAssets, 300e6, "allocated total = idle amount");
  }

  function test_run_multiSourceSumsIntoAllocate() public {
    _configureIntentWithTargetPm();
    facility.setUnlockMint(collateralToken, 1_000e6);

    MorphoAllocator.Deallocation[] memory deals = new MorphoAllocator.Deallocation[](2);
    deals[0] = MorphoAllocator.Deallocation({
      adapter: address(dealAdapter), marketParams: sourceMarket, amount: 200e6, maxUtilisation: WAD
    });
    deals[1] =
      MorphoAllocator.Deallocation({adapter: address(0), marketParams: sourceMarket, amount: 300e6, maxUtilisation: 0});

    vm.prank(executor);
    allocator.run(INTENT_ID, deals, allocAdapter, targetMarket, 1_000e6, 0, true, 0);

    assertEq(vault.deallocateCount(), 1, "only the market source deallocates");
    assertEq(vault.allocateCount(), 1);
    (,, uint256 aAssets) = vault.lastAllocate();
    assertEq(aAssets, 500e6, "allocated total = 200e6 + 300e6");
  }

  function test_run_skipsAllocateWhenAdapterZero() public {
    _configureIntentWithTargetPm();
    facility.setUnlockMint(collateralToken, 1_000e6);

    // Gather 500e6 from a market but leave it idle (allocateAdapter == 0).
    vm.prank(executor);
    allocator.run(INTENT_ID, _deals(500e6, WAD), address(0), targetMarket, 1_000e6, 0, true, 0);

    assertEq(vault.deallocateCount(), 1, "still deallocates the source");
    assertEq(vault.allocateCount(), 0, "allocate skipped when adapter == 0");
    assertEq(facility.depositManagerCount(), 1);
  }

  function test_run_skipsAllocateWhenNoSources() public {
    _configureIntentWithTargetPm();
    facility.setUnlockMint(collateralToken, 1_000e6);

    vm.prank(executor);
    allocator.run(INTENT_ID, _noDeals(), allocAdapter, targetMarket, 1_000e6, 700e6, true, 0);

    assertEq(vault.allocateCount(), 0, "total is zero, allocate skipped");
    assertEq(facility.depositManagerCount(), 1);
  }

  function test_run_revertsOnMaxUtilisation() public {
    _configureIntentWithTargetPm();
    facility.setUnlockMint(collateralToken, 1_000e6);

    // Source market at 90% utilisation (900e6 / 1000e6); cap at 50%.
    morpho.setMarket(sourceMarket.id(), 1_000e6, 900e6);

    vm.expectRevert(
      abi.encodeWithSelector(MorphoAllocator.MaxUtilisationExceeded.selector, address(dealAdapter), 0.9e18, 0.5e18)
    );
    vm.prank(executor);
    allocator.run(INTENT_ID, _deals(500e6, 0.5e18), allocAdapter, targetMarket, 0, 0, true, 0);
    assertEq(facility.depositManagerCount(), 0, "depositManager not called");
  }

  function test_run_revertsWhenOrderNotEnded() public {
    _configureIntentWithTargetPm();
    facility.setUnlockMint(collateralToken, 1_000e6);
    facility.setUnlockState(State.PROCESSING); // unlock leaves a non-ENDED state

    vm.expectRevert(
      abi.encodeWithSelector(MorphoAllocator.UnexpectedOrderState.selector, State.ENDED, State.PROCESSING)
    );
    vm.prank(executor);
    allocator.run(INTENT_ID, _deals(500e6, WAD), allocAdapter, targetMarket, 0, 0, true, 0);

    assertEq(vault.deallocateCount(), 0, "rebalance not reached");
    assertEq(facility.depositManagerCount(), 0);
  }

  function test_run_revertsOnSlippage() public {
    _configureIntentWithTargetPm();
    facility.setUnlockMint(collateralToken, 800e6);

    vm.expectRevert(abi.encodeWithSelector(MorphoAllocator.SlippageExceeded.selector, 900e6, 800e6));
    vm.prank(executor);
    allocator.run(INTENT_ID, _deals(500e6, WAD), allocAdapter, targetMarket, 950e6, 700e6, true, 900e6);

    assertEq(vault.deallocateCount(), 0, "rebalance not reached");
    assertEq(vault.allocateCount(), 0, "allocate not called");
    assertEq(facility.depositManagerCount(), 0, "depositManager not called");
  }

  function test_run_revertsIfTargetNotPM() public {
    IntentProperties memory props;
    props.depositAsset = Asset({asset: address(0xDA), isPositionManager: false});
    props.targetAsset = Asset({asset: address(0xFA), isPositionManager: false});
    facility.setIntent(INTENT_ID, props);

    facility.setUnlockMint(collateralToken, 1_000e6);

    vm.expectRevert(abi.encodeWithSelector(MorphoAllocator.TargetNotPositionManager.selector, INTENT_ID, true));
    vm.prank(executor);
    allocator.run(INTENT_ID, _noDeals(), allocAdapter, targetMarket, 0, 0, true, 0);
  }

  function test_run_revertsWhenAllocatorRoleMissing() public {
    _configureIntentWithTargetPm();
    facility.setUnlockMint(collateralToken, 1_000e6);

    vault.setIsAllocator(address(allocator), false);

    // The first vault interaction (deallocate) reverts on the missing allocator role.
    vm.expectRevert(MockVaultV2.NotAllocator.selector);
    vm.prank(executor);
    allocator.run(INTENT_ID, _deals(500e6, WAD), allocAdapter, targetMarket, 1_000e6, 700e6, true, 0);
    assertEq(facility.depositManagerCount(), 0, "depositManager not called");
  }

  function test_run_orderingUnlockBeforeDeposit() public {
    _configureIntentWithTargetPm();
    facility.setUnlockMint(collateralToken, 1_000e6);

    uint256 callsBefore = facility.callOrderLength();

    vm.prank(executor);
    allocator.run(INTENT_ID, _deals(500e6, WAD), allocAdapter, targetMarket, 1_000e6, 700e6, true, 0);

    // unlock lands first, depositManager last; the vault deallocate/allocate happen in between.
    assertEq(facility.callOrder(callsBefore), "unlock");
    assertEq(facility.callOrder(callsBefore + 1), "depositManager");
    assertEq(vault.deallocateCount(), 1);
    assertEq(vault.allocateCount(), 1);
  }

  function test_run_revertsWhenNotExecutor() public {
    _configureIntentWithTargetPm();
    facility.setUnlockMint(collateralToken, 1_000e6);

    vm.expectRevert();
    vm.prank(stranger);
    allocator.run(INTENT_ID, _noDeals(), allocAdapter, targetMarket, 0, 0, true, 0);
  }

  /*========== multiple intents ==========*/

  function test_multipleIntentsIndependent() public {
    uint256 id1 = INTENT_ID;
    uint256 id2 = INTENT_ID + 1;

    IntentProperties memory props;
    props.targetAsset = Asset({asset: address(pm), isPositionManager: true});
    facility.setIntent(id1, props);
    facility.setIntent(id2, props);

    // Running id2 routes id2's own rebalance and deposit, independent of id1.
    facility.setUnlockMint(collateralToken, 1_500e6);
    vm.prank(executor);
    allocator.run(id2, _deals(100e6, WAD), allocAdapter, targetMarket, 1_500e6, 0, true, 0);

    (,, uint256 aAssets) = vault.lastAllocate();
    assertEq(aAssets, 100e6, "id2 allocation routed");
    (uint256 dId,,,) = facility.lastDepositManager();
    assertEq(dId, id2, "depositManager ran for id2");
  }

  /*========== fuzz ==========*/

  function testFuzz_slippageBoundary(uint256 minOut, uint128 actual128) public {
    minOut = bound(minOut, 0, type(uint128).max);
    uint256 actual = uint256(actual128);

    _configureIntentWithTargetPm();
    facility.setUnlockMint(collateralToken, actual);

    if (actual < minOut) {
      vm.expectRevert(abi.encodeWithSelector(MorphoAllocator.SlippageExceeded.selector, minOut, actual));
      vm.prank(executor);
      allocator.run(INTENT_ID, _noDeals(), address(0), targetMarket, actual, 0, true, minOut);
      assertEq(facility.depositManagerCount(), 0, "no deposit on slippage revert");
    } else {
      vm.prank(executor);
      allocator.run(INTENT_ID, _noDeals(), address(0), targetMarket, actual, 0, true, minOut);
      assertEq(facility.depositManagerCount(), 1, "deposit on success");
    }
  }
}
