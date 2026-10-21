# Facilitators

Smart Facilitator scripts for the Grunt Protocol. The facilitator contracts in `src/` are permissioned automation scripts that hold `FACILITATOR_ROLE` on a Grunt Facility and execute phases of an intent's deposit lifecycle atomically: either every step succeeds, or the whole call reverts and can be retried.

Two facilitators exist today, covering the two ends of a fund DEPOSIT order's life:

| Contract | Phase | Sequence |
|---|---|---|
| `CommitDeposit` | Order creation | pull bridge funds → create DEPOSIT order → commit |
| `MorphoAllocator` | Order maturation | unlock → rebalance Morpho Vault V2 → deposit collateral & borrow |

`src/checks/` additionally holds permissionless, read-only guard contracts meant to be called as the first step of a batch transaction to make the rest of the batch revert on stale state; they hold no roles and no storage.

## CommitDeposit (`src/CommitDeposit.sol`)

`run(intentId, pullAmount, commitAmount, minSharesOut)`:

1. `Facility.pull(intentId, pullAmount)` — pull `pullAmount` of the bridge-loan asset from the Request.
2. `Facility.create(intentId, commitAmount, minSharesOut, Mode.DEPOSIT)` — create the fund order. `commitAmount` may intentionally differ from `pullAmount` (the executor controls the split, e.g. for fees or amounts already held).
3. `Facility.commit(intentId)` — advance the order, then assert the fund reports it as `PROCESSING` (revert with `UnexpectedOrderState` otherwise).

`minSharesOut` is the slippage guard on the fund side: the minimum shares the DEPOSIT order must mint. Success emits `DepositCommitted(intentId, pullAmount, commitAmount, order)` with the full order struct.

## MorphoAllocator (`src/MorphoAllocator.sol`)

`run(intentId, deallocations, allocateAdapter, allocateMarket, depositAmount, borrowAmount, useTarget, minSharesUnlocked)`:

1. **Select the PositionManager.** `useTarget` picks the intent's target asset (true) or deposit asset (false); it must be a position manager (`TargetNotPositionManager` otherwise). Its `assets()` gives the collateral asset used for the balance audit.
2. **Unlock.** Snapshot the intent's collateral balance, call `Facility.unlock(intentId)`, assert the order is `ENDED`. Balances are read from `Facility.intentBalances` per intent — never `balanceOf(facility)`, which aggregates across all intents. The balance must not decrease (`UnlockBalanceDecreased`), and the credited delta must satisfy `minSharesUnlocked` (`SlippageExceeded`).
3. **Rebalance the Morpho Vault V2.** Each `Deallocation` entry contributes `amount` to a gathered total:
   - `adapter == address(0)` — the amount comes from the vault's idle liquidity; no call, no checks.
   - otherwise — `Vault.deallocate(adapter, marketParams, amount)` withdraws from that Morpho Blue market, then the market's post-withdrawal utilisation (`totalBorrow / totalSupply`, WAD) must be `<= maxUtilisation` (`MaxUtilisationExceeded`). The check runs after the withdrawal so it reflects the new totals plus accrued interest. An empty market counts as 0 utilisation with no borrows, infinite with any borrow.

   The gathered total is then allocated into the single destination market via `Vault.allocate(allocateAdapter, allocateMarket, total)` — skipped when `allocateAdapter == address(0)` or the total is zero, in which case the gathered liquidity stays idle in the vault.
4. **Deposit & borrow.** `Facility.depositManager(intentId, depositAmount, borrowAmount, useTarget)` locks collateral and takes on debt through the selected PositionManager. `depositAmount` is the executor's choice and is independent of the measured unlocked amount (it may be less, leaving collateral idle on the intent).

Success emits `Allocated(intentId, unlocked, allocateAdapter, gatheredTotal, borrowAmount)`.

`runInKind(intentId, deallocations, allocateAdapter, allocateMarket, depositAmount, borrowAmount, useTarget)` serves in-kind deposit intents, where the depositor supplied the PositionManager's collateral directly to the intent and there is no fund order to unlock. It runs steps 1, 3 and 4 above (PositionManager check, vault rebalance, `depositManager` with the given `depositAmount`) and skips the unlock, order-state and slippage checks. It emits the same `Allocated` event with `unlocked = depositAmount`.

### Deployment

`script/DeployMorphoAllocator.s.sol` deploys the implementation and an ERC1967 proxy through the Solady canonical `ERC1967Factory` (`0x0000000000006396FF2a80c067f99B3d2Ab4Df24`). Ethereum mainnet:

```text
MorphoAllocator (proxy):          0xb8947d2725D3E9De9b19fC720f053300c50981e5
MorphoAllocator (implementation): 0x4372540f89Ef3a83eB83365C508C4fb775fA449F
```

To ship a new implementation, `script/DeployMorphoAllocatorImpl.s.sol` deploys it and prints the `ERC1967Factory.upgrade(proxy, impl)` calldata. The proxy admin (`0xA9F5262c1aa97C6E519D6f8837658C8f9979bA24`) must execute that call; the script only simulates it on the fork.

## DepositCapStateGuard (`src/checks/DepositCapStateGuard.sol`)

`requireState(facility, checks)` — a stateless, read-only guard that reverts unless every intent in `checks` matches the caller's expectations:

- **Deposit cap** must equal `expectedCap` exactly (`StaleCap` otherwise) — cap changes are precisely the state transitions the guard exists to catch.
- **Total supply** must lie within the inclusive `[minSupply, maxSupply]` range (`SupplyOutOfRange` otherwise), so benign concurrent deposits/withdrawals inside the tolerated band do not fail the batch. Pass `minSupply == maxSupply` for an exact check; an inverted range reverts with `InvalidSupplyRange`.

**Usage: this contract must be called as the FIRST transaction of a batch** (e.g. an EIP-7702 batch) executed in the mode where any failing call reverts the whole batch. The batch calls this read-only function first; if the on-chain cap/supply state no longer matches what was expected when the batch was signed, the guard reverts and the rest of the batch reverts with it, so no state-changing call executes against stale state.

The guard is unpermissioned (anyone may call it with any arguments), holds no storage, and takes the Facility as a call parameter, so one deployment serves any Facility.

### Deployment

`script/DeployDepositCapStateGuard.s.sol` deploys the guard through the canonical CREATE2 factory (`0x4e59b44847b379578588920cA78FbF26c0B4956C`) with a salt ground for a `0x3fa77e57` ("3F ATTEST") vanity prefix, giving the same address on every chain:

```text
DepositCapStateGuard: 0x3Fa77E57baC28940621d1aaE1a136058c4064623
```

The script restores the metadata digest used by the already deployed init code, verifies its full hash, and checks that code exists at this address after deployment. This keeps the address stable when only compiler metadata changes. Executable-code changes require a new deployment address and updated integrations.

## Roles & trust assumptions

- **Owner / executor.** Both contracts use Solady `OwnableRoles`. The owner (set at initialization) grants and revokes `EXECUTOR_ROLE`; only executors can call `run` (and `MorphoAllocator.runInKind`). Executors are trusted operators: parameters like the pull/commit split, `depositAmount`, and the rebalance shape are their judgment calls — the contracts enforce invariants (order states, slippage minima, utilisation caps, balance audits), not strategy.
- **External grants.** The Facility owner must grant each script `FACILITATOR_ROLE`; the Vault V2 curator must additionally whitelist `MorphoAllocator` as an allocator.
- **Atomicity.** Every `run` is all-or-nothing: any failed assertion reverts the entire sequence, leaving the protocol in its prior state so the executor can adjust parameters and retry.
- **Deployment.** Both contracts are proxy-ready: Solady `Initializable` with locked implementations and ERC-7201 namespaced storage. Initialization validates the owner is non-zero and that the Facility (and Morpho Vault) addresses have code.
