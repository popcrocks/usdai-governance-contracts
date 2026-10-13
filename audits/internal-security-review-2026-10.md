# USDai Governance Contracts — Internal Security Review

**Date:** 2026-10-13
**Commit baseline:** `6e24b5c` (Chip v1.2) on branch `claude/wizardly-euler-u3yhbp`
**Scope:** `src/Chip.sol`, `src/StakedChip.sol`, `src/ChipGovernor.sol`, `src/TimelockController.sol`, `src/omnichain/{OAdapter,OToken,OLockAdapter}.sol`, and all `script/` deploy/upgrade tooling.
**Out of scope:** Unmodified OpenZeppelin v5.5 and LayerZero-v2 library code (reviewed only for correct usage), the `usdai-contracts` submodule (treated as a trusted dependency).

## Methodology

This review combined:

1. **A multi-agent adversarial audit workflow** — 7 independent expert auditors (one per contract/dimension) produced raw findings; a triage pass de-duplicated them into 16 unique findings; each finding was then cross-examined by a 3-lens panel (exploitability, adversarial refutation, impact/severity), keeping a finding only when a majority judged it real.
2. **Independent manual review** of every externally reachable function and the key economic/governance invariants.
3. **Executable proof** — 60 new Foundry tests (see “Test coverage” below), including PoCs that exercise the anti-inflation property, the full governance lifecycle, and the bridge/pause interaction. All **192 tests pass**.

## Summary of results

**No critical or high severity issues were found.** The architecture is sound: the ERC4626 vault uses storage-tracked assets that structurally defeat donation/inflation attacks, the bridge preserves a strict lock==mint supply invariant, and the governor/timelock composition is correct. The findings below are centralization/governance design points, operational (deploy-time) risks, and informational notes.

> **Important:** The core contracts are already deployed (Arbitrum: Chip, StakedChip, ChipGovernor, TimelockController; Base & Mainnet: the spoke OTokens). Contract-source recommendations (F4, F13, F14, F16) are therefore written as guidance for a **future implementation version** and are **not** applied here. Only deploy-script and documentation issues — which are tooling, not deployed bytecode — were fixed in this branch.

### Findings

| ID | Severity | Title | Status |
|----|----------|-------|--------|
| F1 | Medium | Admin multisig holds PROPOSER+EXECUTOR+CANCELLER on the Timelock (can bypass/censor the Governor) | Documented — by design, disclosed |
| F2 | Medium | A blacklisted delegatee keeps voting power delegated to it by non-blacklisted holders | Documented — design limitation |
| F3 | Low | `Deploy.s.sol` builds the StakedChip impl with CHIP asset = `address(0)` (bricked vault) | **Fixed** |
| F4 | Low | StakedChip `mint()` rounds the asset cost down (floor) instead of up (ERC4626 deviation) | Documented — latent, 0 impact today |
| F5 | Low | `Deploy.s.sol` leaves the deployer EOA with permanent CANCELLER_ROLE / diverges from production | Mitigated (labeled dev-only) |
| F6 | Low | OToken pause can freeze a spoke’s bridge in both directions (unilateral, recoverable) | Documented + tested |
| F7 | Low | Inbound credit (hub unlock) is not rate-limited; custody relies on the spoke’s outbound limit + peer integrity | Documented — defense-in-depth |
| F8 | Low | Proposal threshold deployed as 100M but documented as 10M | **Fixed** (docs) |
| F9 | Low | No deploy script wires LayerZero peers / enforced options | Documented — deploy runbook gap |
| F10 | Info | Deploy scripts grant the now-dead `TRANSFER_ADMIN_ROLE` (removed in Chip v1.2) | **Fixed** |
| F11 | Info | Spoke→hub transfer to a blacklisted hub recipient reverts after the OToken is burned | Documented — known tradeoff |
| F12 | Info | Every CHIP transfer/delegation staticcalls `USDai.isBlacklisted` (liveness coupling) | Documented — trust assumption |
| F13 | Info | Direct CHIP transfers to the vault are permanently stuck (no sweep) | Documented — by design |
| F14 | Info | First-deposit conversion reverts with an arithmetic panic for `assets <= LOCKED_SHARES` | Documented + tested |
| F15 | Info | `OAdapter` constructor reads `token.decimals()` (deploy-ordering dependency) | Documented |
| F16 | Info | Dead code: internal `_sharePrice()` is never referenced | Documented |

## Verified-safe properties (what was checked and holds)

- **No inflation/donation attack.** `StakedChip.totalAssets()` returns a storage-tracked balance, not `token.balanceOf(this)`, so direct CHIP donations cannot move the share price. The classic first-depositor inflation attack fails (PoC: `test__ClassicInflationAttackFails`, `test__DonationDoesNotChangeSharePrice`). 1e6 locked shares are minted to `0xdead` on first deposit and are permanently unredeemable, so `totalSupply()` never returns to 0.
- **1:1 vault invariant.** `totalAssets() == totalSupply()` and `chip.balanceOf(vault) >= totalAssets()` across arbitrary deposit/withdraw sequences (fuzzed: `testFuzz__OneToOneInvariant`).
- **Bridge supply invariant.** CHIP locked in `OLockAdapter` on the hub equals OToken minted on the spoke; dust below 1e12 (sharedDecimals=6) is removed symmetrically so burn==mint.
- **OFT burn is allowance-safe.** `OToken.burn(from, amount)` takes no allowance but `OFTCore.send` always passes `_from = msg.sender`, so a caller can only burn their own tokens.
- **Governor composition is correct.** The full propose → delegate → vote → queue → 3-day timelock → execute lifecycle works; quorum counts For+Abstain (not Against); late-quorum extension works; the proposal guardian can cancel at any stage while the base rule still lets a proposer cancel a Pending proposal (PoCs in `test/ChipGovernor.t.sol`).
- **No flash-loan governance.** Voting power is read from timestamp-based past checkpoints at the proposal snapshot.
- **Timelock is self-governed in production** (`admin = address(0)`), executors are `[governor, admin]` (not the open `address(0)` executor).
- **ERC-7201 storage slot** for `stakedChip.deposits` matches `cast index-erc7201` (`0x54aad2…d800`); StakedChip adds no colliding regular state, so upgrades are layout-safe.

## Fixes applied in this branch

- **F3** — `script/Deploy.s.sol`: construct the StakedChip implementation with `address(chip)` instead of the still-unset `_deployment.chip` (which is guaranteed `address(0)` by the `AlreadyDeployed` guard). Without this, any vault deployed via this script has `asset() == address(0)` and reverts on every deposit, unrecoverably (the asset is fixed in the one-shot initializer). The production script was already correct.
- **F10** — removed the dead `TRANSFER_ADMIN_ROLE` grant from `Deploy.s.sol` and `DeployProductionEnvironment.s.sol`, and the corresponding lines in `docs/PARAMETERS.md`; added a note that CHIP transfers are unrestricted since v1.2 (subject only to the USDai blacklist).
- **F8** — reconciled `docs/PARAMETERS.md` proposal threshold to `100 million (1% of supply)`, matching both deploy scripts.
- **F5** — added a header comment to `Deploy.s.sol` marking it development/single-chain and directing production deployments to `DeployProductionEnvironment.s.sol`.

No deployed contract bytecode was changed.

## Recommendations (not applied — for a future contract version or operations)

- **F4** — in `StakedChip._mint`, compute the asset cost with `Math.Rounding.Ceil` (i.e. `previewMint`) so minting rounds in the vault’s favor, matching ERC4626 and the StakedUSDai reference. Harmless today (price pinned to 1.0) but important if yield is ever introduced.
- **F1 / F2** — if full sanction neutralization is a goal, gate governance participation on the blacklist directly (treat a blacklisted delegatee’s voting weight as zero and/or revert `castVote` for blacklisted voters) rather than only on delegation pointers; and reconsider whether the admin multisig should hold PROPOSER/EXECUTOR or only CANCELLER on the timelock. Both are currently intentional, disclosed trust assumptions.
- **F6 / F7** — gate `PAUSE_ADMIN_ROLE` behind a multisig/timelock; consider a receive-side rate limit on `OLockAdapter._credit` for custody-side defense-in-depth.
- **F9** — add an explicit `setPeer` / `setEnforcedOptions` wiring script and a post-deploy verification gate for the omnichain environment.
- **F11 / F13** — consider admin-gated rescue paths (re-credit a burned-but-stuck bridge message to a non-blacklisted address; sweep only the un-accounted `balanceOf(this) - _depositBalance()` surplus).
- **F14** — add `require(assets > LOCKED_SHARES)` with the `InvalidAmount` custom error in the empty-vault branch for a clear revert reason.
- **F16** — remove the unused `_sharePrice()` helper.

## Test coverage added

60 new tests were added (192 total, all passing). Line coverage of the audited contracts rose substantially, most notably **ChipGovernor from 0% to ~90%**.

| File | Tests | Covers |
|------|-------|--------|
| `test/ChipGovernor.t.sol` | 18 | Full governance lifecycle, threshold, quorum (For+Abstain), late-quorum extension, guardian/proposer cancellation |
| `test/OToken.t.sol` | 13 | `onlyOAdapter` mint/burn authorization + the v1.1 pause/unpause additions |
| `test/StakedChipSlippageInvariant.t.sol` | 11 | Slippage overloads (minShares/maxAmount), first-deposit edges, 1:1 invariant (fuzz), anti-inflation PoC |
| `test/ChipBridgePause.t.sol` | 2 (+16 inherited) | Paused-destination strand-and-recover; hub lock accounting under a paused spoke |

## Appendix: finding locations

- F1: `script/DeployProductionEnvironment.s.sol` (timelock `accounts=[governor, admin]` as proposers+executors)
- F2: `src/Chip.sol:169-215` (`_update`, `_delegate`, `revokeDelegate`)
- F3: `script/Deploy.s.sol:67` (fixed)
- F4: `src/StakedChip.sol:251` + `:326-334`
- F5: `script/Deploy.s.sol` role wiring
- F6: `src/omnichain/OToken.sol:114-147`
- F7: `src/omnichain/OLockAdapter.sol` (`_debit` limited; inherited `_credit` not)
- F8: deploy scripts vs `docs/PARAMETERS.md` (fixed)
- F9: `script/Deploy{Home,Away}OmnichainEnvironment.s.sol`
- F10: deploy scripts + `docs/PARAMETERS.md` (fixed)
- F11: `src/omnichain/OLockAdapter.sol` + `src/Chip.sol` blacklist
- F12: `src/Chip.sol:112-116`
- F13: `src/StakedChip.sol:339-341`
- F14: `src/StakedChip.sol:318`, `:331`
- F15: `src/omnichain/OAdapter.sol:45-52`
- F16: `src/StakedChip.sol:198-200`
