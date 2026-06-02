// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {LibClone} from "solady/utils/LibClone.sol";

import {IFacility} from "@grunt/interfaces/facility/IFacility.sol";
import {IntentProperties, Asset} from "@grunt/libs/facility/LibIntent.sol";

import {IVaultV2} from "@vault-v2/interfaces/IVaultV2.sol";
import {VaultV2Factory} from "@vault-v2/VaultV2Factory.sol";
import {MorphoMarketV1AdapterV2Factory} from "@vault-v2/adapters/MorphoMarketV1AdapterV2Factory.sol";
import {IMorphoMarketV1AdapterV2} from "@vault-v2/adapters/interfaces/IMorphoMarketV1AdapterV2.sol";
import {WAD, MAX_MAX_RATE} from "@vault-v2/libraries/ConstantsLib.sol";

import {IMorpho, MarketParams, Id, Market} from "@morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@morpho-blue/libraries/MarketParamsLib.sol";

import {MorphoAllocator} from "src/MorphoAllocator.sol";
import {IMorphoAllocator, Phase, Deallocation} from "src/interfaces/IMorphoAllocator.sol";

import {MockFacility, MockPositionManager} from "./MorphoAllocator.t.sol";

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                       LOCAL TOKEN MOCKS                    */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/// @notice Minimal ERC20 (mint/approve/transfer) compatible with Morpho's SafeTransferLib.
contract TestERC20 {
  string public name = "Test Token";
  string public symbol = "TST";
  uint8 public immutable decimals;
  uint256 public totalSupply;
  mapping(address => uint256) public balanceOf;
  mapping(address => mapping(address => uint256)) public allowance;

  constructor(uint8 decimals_) {
    decimals = decimals_;
  }

  function mint(address to, uint256 amount) external {
    balanceOf[to] += amount;
    totalSupply += amount;
  }

  function approve(address spender, uint256 amount) external returns (bool) {
    allowance[msg.sender][spender] = amount;
    return true;
  }

  function transfer(address to, uint256 amount) external returns (bool) {
    _transfer(msg.sender, to, amount);
    return true;
  }

  function transferFrom(address from, address to, uint256 amount) external returns (bool) {
    uint256 a = allowance[from][msg.sender];
    if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
    _transfer(from, to, amount);
    return true;
  }

  function _transfer(address from, address to, uint256 amount) internal {
    balanceOf[from] -= amount;
    balanceOf[to] += amount;
  }
}

/// @notice Minimal Morpho oracle returning a fixed price.
contract TestOracle {
  uint256 public price;

  function setPrice(uint256 newPrice) external {
    price = newPrice;
  }
}

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                      INTEGRATION TESTS                     */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/// @notice End-to-end tests of MorphoAllocator.complete against a REAL Morpho Vault V2 +
///         MorphoMarketV1AdapterV2 + Morpho Blue. Only the Grunt Facility leg is mocked; the
///         deallocate/allocate rebalance and the utilisation check run against real contracts.
contract MorphoAllocatorIntegrationTest is Test {
  using MarketParamsLib for MarketParams;

  // Real stack
  IMorpho internal morpho;
  address internal irm;
  IVaultV2 internal vault;
  IMorphoMarketV1AdapterV2 internal adapter;
  TestERC20 internal underlying; // vault asset / market loan token
  TestERC20 internal collateral; // market collateral token
  TestOracle internal oracle;
  MarketParams internal sourceMarket;
  MarketParams internal targetMarket;

  // Allocator + mocked Grunt leg
  MorphoAllocator internal allocator;
  MockFacility internal facility;
  MockPositionManager internal pm;

  address internal executor = address(this); // also vault owner/curator/allocator
  address internal gruntCollateral = address(0xC0FFEE); // PM collateral tracked by MockFacility
  uint256 internal constant INTENT_ID = 1;
  uint256 internal constant ORACLE_PRICE_SCALE = 1e36;
  uint256 internal constant DEPOSIT = 3_000e6;
  uint256 internal constant SEED = 1_000e6;

  function setUp() public {
    // --- Real Morpho Blue + IRM (deployed via deployCode; pinned to solc 0.8.19) ---
    morpho = IMorpho(deployCode("Morpho.sol", abi.encode(address(this))));
    irm = deployCode("AdaptiveCurveIrm.sol", abi.encode(address(morpho)));

    underlying = new TestERC20(6);
    collateral = new TestERC20(6);
    oracle = new TestOracle();
    oracle.setPrice(ORACLE_PRICE_SCALE);

    sourceMarket = MarketParams({
      loanToken: address(underlying),
      collateralToken: address(collateral),
      oracle: address(oracle),
      irm: irm,
      lltv: 0.8e18
    });
    targetMarket = MarketParams({
      loanToken: address(underlying),
      collateralToken: address(collateral),
      oracle: address(oracle),
      irm: irm,
      lltv: 0.9e18
    });

    morpho.enableIrm(irm);
    morpho.enableLltv(0.8e18);
    morpho.enableLltv(0.9e18);
    morpho.createMarket(sourceMarket);
    morpho.createMarket(targetMarket);

    // --- Real Vault V2 + adapter ---
    vault = IVaultV2(new VaultV2Factory().createVaultV2(address(this), address(underlying), bytes32(0)));
    adapter = IMorphoMarketV1AdapterV2(
      new MorphoMarketV1AdapterV2Factory(address(morpho), irm).createMorphoMarketV1AdapterV2(address(vault))
    );

    // --- Allocator + mocked Grunt facility ---
    facility = new MockFacility();
    pm = new MockPositionManager(gruntCollateral, address(0xDEB7));
    allocator = MorphoAllocator(LibClone.clone(address(new MorphoAllocator())));
    allocator.initialize(address(this), executor, IFacility(address(facility)), vault);

    // --- Vault wiring: curator/allocators, adapter, maxRate, caps ---
    vault.setCurator(address(this));
    _submitExec(abi.encodeCall(IVaultV2.setIsAllocator, (address(this), true)));
    _submitExec(abi.encodeCall(IVaultV2.setIsAllocator, (address(allocator), true)));
    _submitExec(abi.encodeCall(IVaultV2.addAdapter, (address(adapter))));
    vault.setMaxRate(MAX_MAX_RATE);

    _setMaxCaps(abi.encode("this", address(adapter)));
    _setMaxCaps(abi.encode("collateralToken", address(collateral)));
    _setMaxCaps(abi.encode("this/marketParams", address(adapter), sourceMarket));
    _setMaxCaps(abi.encode("this/marketParams", address(adapter), targetMarket));

    // --- Fund the vault: deposit idle, seed the source market ---
    underlying.mint(address(this), DEPOSIT);
    underlying.approve(address(vault), DEPOSIT);
    vault.deposit(DEPOSIT, address(this));
    vault.allocate(address(adapter), abi.encode(sourceMarket), SEED);

    // --- Grunt leg: configure the intent (target = PositionManager) and start the workflow ---
    facility.setFacilitator(address(allocator), true);
    IntentProperties memory props;
    props.depositAsset = Asset({asset: address(0xDA), isPositionManager: false});
    props.targetAsset = Asset({asset: address(pm), isPositionManager: true});
    facility.setIntent(INTENT_ID, props);

    allocator.start(INTENT_ID, 1_000e6, 1_000e6, 0);
    facility.setUnlockMint(gruntCollateral, 500e6);
  }

  /*========== helpers ==========*/

  function _submitExec(bytes memory call) internal {
    vault.submit(call);
    (bool ok,) = address(vault).call(call);
    require(ok, "exec failed");
  }

  function _setMaxCaps(bytes memory idData) internal {
    _submitExec(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (idData, type(uint128).max)));
    _submitExec(abi.encodeCall(IVaultV2.increaseRelativeCap, (idData, WAD)));
  }

  function _supply(MarketParams memory mp) internal view returns (uint256) {
    return morpho.market(mp.id()).totalSupplyAssets;
  }

  function _deal(address adapterAddr, MarketParams memory mp, uint256 amount, uint256 maxUtil)
    internal
    pure
    returns (Deallocation[] memory deals)
  {
    deals = new Deallocation[](1);
    deals[0] = Deallocation({adapter: adapterAddr, marketParams: mp, amount: amount, maxUtilisation: maxUtil});
  }

  /// @dev Borrow `amount` from `mp` (backed by ample collateral) to create real utilisation.
  function _createUtilisation(MarketParams memory mp, uint256 amount) internal {
    address borrower = makeAddr("borrower");
    uint256 collat = amount * 2; // price 1e36, lltv >= 0.8 → 2x collateral is ample
    collateral.mint(borrower, collat);
    vm.startPrank(borrower);
    collateral.approve(address(morpho), collat);
    morpho.supplyCollateral(mp, collat, borrower, "");
    morpho.borrow(mp, amount, 0, borrower, borrower);
    vm.stopPrank();
  }

  /*========== tests ==========*/

  function test_integration_movesLiquidityBetweenRealMarkets() public {
    assertEq(_supply(sourceMarket), SEED, "source seeded");
    assertEq(_supply(targetMarket), 0, "target empty");

    // Deallocate 400e6 from source, allocate the total (400e6) into target.
    allocator.complete(
      INTENT_ID, _deal(address(adapter), sourceMarket, 400e6, WAD), address(adapter), targetMarket, 0, true, 0
    );

    assertEq(_supply(sourceMarket), SEED - 400e6, "source reduced by deallocation");
    assertEq(_supply(targetMarket), 400e6, "target received the allocation");
    assertEq(facility.depositManagerCount(), 1, "depositManager ran");
    assertEq(uint256(allocator.workflow(INTENT_ID)), uint256(Phase.IDLE), "workflow reset");
  }

  function test_integration_idleSourceAllocatesIntoRealMarket() public {
    // adapter == address(0): source the amount from the vault's idle liquidity, allocate into target.
    Deallocation[] memory deals = new Deallocation[](1);
    deals[0] = Deallocation({adapter: address(0), marketParams: sourceMarket, amount: 250e6, maxUtilisation: 0});

    allocator.complete(INTENT_ID, deals, address(adapter), targetMarket, 0, true, 0);

    assertEq(_supply(sourceMarket), SEED, "source untouched (idle was the source)");
    assertEq(_supply(targetMarket), 250e6, "target funded from idle");
  }

  function test_integration_maxUtilisationPassesUnderCap() public {
    _createUtilisation(sourceMarket, 700e6); // utilisation 0.7e18

    // Deallocate 100e6 → source supply 900e6, utilisation 700/900 ≈ 0.777e18 < 0.9e18 cap.
    allocator.complete(
      INTENT_ID, _deal(address(adapter), sourceMarket, 100e6, 0.9e18), address(adapter), targetMarket, 0, true, 0
    );

    assertEq(_supply(sourceMarket), SEED - 100e6, "source reduced");
    assertEq(_supply(targetMarket), 100e6, "target funded");
  }

  function test_integration_maxUtilisationRevertsOverCap() public {
    _createUtilisation(sourceMarket, 700e6); // utilisation 0.7e18

    // Deallocate 300e6 → source supply 700e6, utilisation 700/700 = 1e18 > 0.9e18 cap.
    uint256 expectedUtil = uint256(700e6) * 1e18 / uint256(700e6);
    vm.expectRevert(
      abi.encodeWithSelector(MorphoAllocator.MaxUtilisationExceeded.selector, address(adapter), expectedUtil, 0.9e18)
    );
    allocator.complete(
      INTENT_ID, _deal(address(adapter), sourceMarket, 300e6, 0.9e18), address(adapter), targetMarket, 0, true, 0
    );

    // Atomic revert: nothing moved, workflow still committed.
    assertEq(_supply(sourceMarket), SEED, "source unchanged");
    assertEq(_supply(targetMarket), 0, "target unchanged");
    assertEq(uint256(allocator.workflow(INTENT_ID)), uint256(Phase.COMMITTED), "still committed");
  }

  function test_integration_dataEncodingAcceptedByRealAdapter() public {
    // If the abi.encode(MarketParams) the allocator emits did not match what the real adapter
    // decodes, the real morpho.withdraw/supply would revert. A clean run proves the seam works.
    uint256 targetBefore = _supply(targetMarket);
    allocator.complete(
      INTENT_ID, _deal(address(adapter), sourceMarket, 123e6, WAD), address(adapter), targetMarket, 0, true, 0
    );
    assertEq(_supply(targetMarket) - targetBefore, 123e6, "exact amount routed into the target market");
  }
}
