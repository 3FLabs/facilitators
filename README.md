# Facilitators

Smart Facilitator scripts for the Grunt Protocol. Each contract in `src/` is a permissioned automation script that holds `FACILITATOR_ROLE` on a Grunt Facility and executes one multi-step phase of an intent's deposit lifecycle atomically: either every step succeeds, or the whole call reverts and can be retried.

Two facilitators exist today, covering the two ends of a fund DEPOSIT order's life:

| Contract | Phase | Sequence |
|---|---|---|
| `CommitDeposit` | Order creation | pull bridge funds → create DEPOSIT order → commit |
| `MorphoAllocator` | Order maturation | unlock → rebalance Morpho Vault V2 → deposit collateral & borrow |

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

## Roles & trust assumptions

- **Owner / executor.** Both contracts use Solady `OwnableRoles`. The owner (set at initialization) grants and revokes `EXECUTOR_ROLE`; only executors can call `run`. Executors are trusted operators: parameters like the pull/commit split, `depositAmount`, and the rebalance shape are their judgment calls — the contracts enforce invariants (order states, slippage minima, utilisation caps, balance audits), not strategy.
- **External grants.** The Facility owner must grant each script `FACILITATOR_ROLE`; the Vault V2 curator must additionally whitelist `MorphoAllocator` as an allocator.
- **Atomicity.** Every `run` is all-or-nothing: any failed assertion reverts the entire sequence, leaving the protocol in its prior state so the executor can adjust parameters and retry.
- **Deployment.** Both contracts are proxy-ready: Solady `Initializable` with locked implementations and ERC-7201 namespaced storage. Initialization validates the owner is non-zero and that the Facility (and Morpho Vault) addresses have code.
