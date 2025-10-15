# Title

AlchemistTokenVault: ERC20 return values ignored in deposit/withdraw cause silent payout failures (USDT-class tokens)

## Brief/Intro
`AlchemistTokenVault` ignores ERC20 boolean return values in both `deposit` and `withdraw` (it calls `IERC20.transferFrom` / `IERC20.transfer` and does not check the returned bool). For USDT-style tokens that return `false` instead of reverting on failure (insufficient balance, insufficient allowance, paused token, etc.), the vault will emit success events and other callers will proceed as if the transfer succeeded while no tokens actually moved. In production this causes payouts or deposits to be silently unfulfilled (funds remain in the vault and users/keepers/liquidators do not receive tokens), breaking UX, off-chain reconciliation, and third-party automations.

## Vulnerability Details
`AlchemistTokenVault.deposit(amount)` calls `IERC20(token).transferFrom(msg.sender, address(this), amount);` and immediately emits `Deposited` without checking the returned bool. Likewise `AlchemistTokenVault.withdraw(recipient, amount)` calls `IERC20(token).transfer(recipient, amount);` and emits `Withdrawn` while ignoring the bool result. Many non-standard ERC20s (notably USDT and similar) return `false` on failure instead of reverting; ignoring that return value makes the contract treat a failed transfer as success.

The transaction emits `Deposited`/`Withdrawn` and reports success to external systems, but no tokens move on-chain, leaving users or liquidators unpaid.

Context

* deposit: AlchemistTokenVault.sol:28
* withdraw: AlchemistTokenVault.sol:41

Recommended fix

Import OpenZeppelin `SafeERC20` and replace raw ERC20 calls with safe versions. In `AlchemistTokenVault.deposit` use `IERC20(token).safeTransferFrom` and in `AlchemistTokenVault.withdraw` use `IERC20(token).safeTransfer(recipient, amount);`.

In the case of a `false` return, `deposit` and `withdraw` should revert, which is what changing to the safe versions will achieve.

## Impact Details
Vault functions emit success and record payouts even when transfers fail. Users receive no tokens but no value is lost. Fits Low – “Contract fails to deliver promised returns, but doesn’t lose value.”

Note: downstream effect is that liquidators may go unpaid while events claim payment.

## References
Note that `AlchemistETHVault.depositWETH` uses `safeTransferFrom`, providing more evidence that `AlchemistTokenVault` is missing the safe function calls.

## Proof of Concept
The below PoC does these steps:
1. Deploy USDT-like token and a fresh vault instance wired to it
2. Give the user some USDT-like balance and approve the vault
3. BUG: deposit "succeeds" (no revert), but transferFrom returns false, so nothing moves
4. Deposit succeeded but delivered nothing
5. Repeat for withdraw

Place the below mock in `src/test/AlchemistTokenVault.t.sol`.

```solidity
// USDT-like ERC20 that returns false instead of reverting on transfer/transferFrom
contract FalseReturningUSDT is ERC20 {
    constructor() ERC20("USDT False", "USDTF") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address, /*to*/ uint256 /*amount*/ ) public pure override returns (bool) {
        return false; // silently fail
    }

    function transferFrom(address, /*from*/ address, /*to*/ uint256 /*amount*/ ) public pure override returns (bool) {
        return false; // silently fail
    }
}
```

Place the below test in `AlchemistTokenVaultTest`.

```solidity
function test_USDTLikeFalseReturn_SilentSuccess_NoValueLoss() public {
        // Deploy USDT-like token and a fresh vault instance wired to it
        FalseReturningUSDT usdt = new FalseReturningUSDT();

        vm.prank(owner);
        AlchemistTokenVault usdtVault = new AlchemistTokenVault(address(usdt), alchemist, owner);

        // -------------------- DEPOSIT PATH --------------------
        // Give the user some USDT-like balance and approve the vault
        usdt.mint(user, AMOUNT);

        vm.prank(user);
        usdt.approve(address(usdtVault), AMOUNT);

        // Snapshot balances and totalDeposits
        uint256 vaultBalBeforeDep = usdt.balanceOf(address(usdtVault));
        uint256 userBalBeforeDep = usdt.balanceOf(user);
        uint256 totalBeforeDep = usdtVault.totalDeposits();

        // BUG: deposit "succeeds" (no revert), but transferFrom returns false, so nothing moves
        vm.prank(user);
        usdtVault.deposit(AMOUNT);

        // Assert: deposit promised success but delivered nothing; no value was lost
        assertEq(usdt.balanceOf(address(usdtVault)), vaultBalBeforeDep, "deposit: vault balance should be unchanged");
        assertEq(usdt.balanceOf(user), userBalBeforeDep, "deposit: user balance should be unchanged");
        assertEq(usdtVault.totalDeposits(), totalBeforeDep, "deposit: totalDeposits should be unchanged");

        // -------------------- WITHDRAW PATH --------------------
        // Seed the vault directly so it CAN pay if transfer worked
        usdt.mint(address(usdtVault), AMOUNT);

        uint256 vaultBalBeforeW = usdt.balanceOf(address(usdtVault));
        uint256 userBalBeforeW = usdt.balanceOf(user);
        uint256 totalBeforeW = usdtVault.totalDeposits();

        // BUG: withdraw "succeeds" (no revert), but transfer returns false, so nothing moves
        vm.prank(alchemist); // onlyAuthorized in the vault
        usdtVault.withdraw(user, AMOUNT / 2);

        // Assert: withdraw promised payout but delivered nothing; no value was lost
        assertEq(usdt.balanceOf(address(usdtVault)), vaultBalBeforeW, "withdraw: vault tokens not sent");
        assertEq(usdt.balanceOf(user), userBalBeforeW, "withdraw: user did not receive tokens");
        assertEq(usdtVault.totalDeposits(), totalBeforeW, "withdraw: totalDeposits should be unchanged");
    }
```

