# Title

Unconsented `stakeOnBehalf` enables **unbounded gas consumption** via `userValidators[]` growth, causing DoS at scale in `claimAll()` / `withdraw()`

# Target

https://github.com/immunefi-team/attackathon-plume-network/blob/main/plume/src/facets/StakingFacet.sol

# Impact(s)

Unbounded gas consumption

# PoC Link

https://gist.github.com/wylis-hodor/a183e7d1b051c1a2cd30b89178f88fee

# Description

## Inro
Anyone can call `stakeOnBehalf()` with ≥ `minStakeAmount`, which forcibly appends `validatorId` to `userValidators[]` without the user’s consent. Core user flows iterate this array, so the attacker can arbitrarily increase a victim’s gas costs. In our test, pushing a user from 1 → 15 validators raised claimAll() gas from 68,613 to 395,829 (~5.77×). At higher validator counts the same paths can hit block gas limits, turning this from a cost-imposition into a functional DoS.

## Vulnerability Details
**Root cause:** `stakeOnBehalf` records stake for an arbitrary user and adds that validator to `userValidators[user]` with no beneficiary approval. Gas-critical code paths iterate that array:
* RewardsFacet
   * `claimAll()`: for each reward token, calls an internal that loops `userValidators[msg.sender]` to settle rewards across all validators.
   * `claim()`: Single-token version, but still loops over validators for that token.
* StakingFacet
   * `withdraw()`: calls `_processMaturedCooldowns()` which loops `userValidators[user]` to move matured cooldown balances.
   * `restakeRewards()`: also triggers `_processMaturedCooldowns(user)`.
   * `amountWithdrawable()`: uses `_calculateTotalWithdrawableAmount()` which loops `userValidators[user]` to sum matured cooldowns.
**Complexity:**
   * `claimAll()` ≈ O(#rewardTokens × #userValidators)
   * Other API ≈ O(#userValidators)
**Attacker control:**
Attacker repeats `stakeOnBehalf()` for each validator ID (enumerated via `getValidatorsList()`), paying only `minStakeAmount` each time. This permanently bloats `userValidators[]` until the victim performs gas-heavy clean-up.

**Economics:**
Grief cost upper bound = `minStakeAmount × validatorCount` (attacker capital stays staked as the victim’s balance). With low `minStakeAmount` or many validators, this is practical.

## Impact Details
* **Primary** (defensible): High — Unbounded gas consumption
The attacker can arbitrarily increase `userValidators[]`.  Gas scales linearly across multiple core functions.
* **Potential escalation** (evidence-dependent): High — Temporary freezing of funds (≥ 24h)
APIs (e.g. `claimAll()`) could exceed block gas limits at high parameters (e.g., 50–100 validators).  The victim could not complete normal flows.
* **Not claimed** (impact tied to slashing): Though it does not expose attacker-controlled loss of a victim’s existing funds, it should be noted that victim's gifted funds are exposed to slashing and not necissarily available to them.

## Proof of Concept
1. **Setup**
   * Deploy/initialize as in project tests (e.g. 15 validators; 1 reward token).
   * In test: Record baseline gas for the victim calling `claimAll()` once (~68,613).
2. **Attack**
   * Attacker enumerates validators with `getValidatorsList()`.
   * For each ID, attacker calls `stakeOnBehalf(vid, victim)` sending exactly `minStakeAmount`.
   * Confirm `validators.getUserValidators(victim).length` increased to the validator count.
3. **Impact**
   * Victim calls `claimAll()`.
   * Observe gas increase with e.g. 15 validators (5.8 times).  Gas increase to ~395,829.

Note: Attack scales with validator count to approaching/exceeding block gas limits.

