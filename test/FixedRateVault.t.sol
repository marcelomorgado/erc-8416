// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {FixedRateVault} from "../src/FixedRateVault.sol";
import {IERC8416} from "../src/IERC8416.sol";
import {IERC7540Operator, IERC7540Redeem} from "../src/IERC7540.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockStrategy} from "./mocks/MockStrategy.sol";

abstract contract FixedRateVaultBase is Test {
    uint256 internal constant YEAR = 365 days;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant RATE = 0.1e18; // 10% APR
    uint256 internal constant CAP = 1_000e18;
    uint256 internal constant AMOUNT = 100e18;

    // Epoch layout relative to `start`.
    uint256 internal constant ENTRY = 7 days;
    uint256 internal constant ACCRUAL = 30 days;
    uint256 internal constant EXIT = 7 days;

    MockERC20 internal token;
    MockStrategy internal strategy;
    FixedRateVault internal vault;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint256 internal start;

    function setUp() public virtual {
        vm.warp(1_000_000);
        token = new MockERC20();
        strategy = new MockStrategy(token);
        vault = new FixedRateVault(token, strategy, "Fixed Rate Vault", "frVLT", owner);

        token.mint(address(strategy), 1_000_000e18); // yield reserve
        token.mint(alice, 10_000e18);
        token.mint(bob, 10_000e18);
        vm.prank(alice);
        token.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        token.approve(address(vault), type(uint256).max);

        start = block.timestamp + 1 days;
    }

    function _epoch(uint256 s, uint256 rate_, uint256 cap) internal pure returns (FixedRateVault.Epoch memory e) {
        e.rate = rate_;
        e.maxDeposits = cap;
        e.start = s;
        e.entryWindowEnd = s + ENTRY;
        e.accrualStart = s + ENTRY;
        e.accrualEnd = s + ENTRY + ACCRUAL;
        e.exitWindowStart = s + ENTRY + ACCRUAL;
        e.end = s + ENTRY + ACCRUAL + EXIT;
    }

    function _addEpoch(FixedRateVault.Epoch memory e) internal {
        vm.prank(owner);
        vault.addEpoch(e);
    }

    function _addEpoch(uint256 s) internal returns (FixedRateVault.Epoch memory e) {
        e = _epoch(s, RATE, CAP);
        _addEpoch(e);
    }

    function _deposit(address who, uint256 assets) internal returns (uint256 shares) {
        vm.prank(who);
        shares = vault.deposit(assets, who);
    }

    function _requestRedeem(address who, uint256 shares) internal {
        vm.prank(who);
        vault.requestRedeem(shares, who, who);
    }

    function _interest(uint256 principal, uint256 rate_, uint256 dt) internal pure returns (uint256) {
        return (principal * rate_ * dt) / (YEAR * WAD);
    }
}

contract AddEpochTest is FixedRateVaultBase {
    function test_addEpoch_storesEpochAndEmits() public {
        FixedRateVault.Epoch memory e = _epoch(start, RATE, CAP);
        e.deposited = 123; // must be ignored

        vm.expectEmit(address(vault));
        emit IERC8416.EpochAdded(
            1,
            e.rate,
            e.maxDeposits,
            e.start,
            e.entryWindowEnd,
            e.accrualStart,
            e.accrualEnd,
            e.exitWindowStart,
            e.end
        );
        _addEpoch(e);

        assertEq(vault.epochCount(), 1);
        assertEq(vault.rate(1), RATE);
        assertEq(vault.maxEpochDeposits(1), CAP);
        (uint256 s, uint256 end) = vault.epochPeriod(1);
        assertEq(s, e.start);
        assertEq(end, e.end);
        (s, end) = vault.entryWindow(1);
        assertEq(s, e.start);
        assertEq(end, e.entryWindowEnd);
        (s, end) = vault.accrualInterval(1);
        assertEq(s, e.accrualStart);
        assertEq(end, e.accrualEnd);
        (s, end) = vault.exitWindow(1);
        assertEq(s, e.exitWindowStart);
        assertEq(end, e.end);

        // `deposited` was reset: the full cap is available once the entry window opens.
        vm.warp(start);
        assertEq(vault.maxDeposit(alice), CAP);
    }

    function test_addEpoch_revertsIfNotOwner() public {
        FixedRateVault.Epoch memory e = _epoch(start, RATE, CAP);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.addEpoch(e);
    }

    function test_addEpoch_revertsIfStartInPast() public {
        _expectInvalid(_epoch(block.timestamp - 1, RATE, CAP));
    }

    function test_addEpoch_revertsIfStartNotBeforeEnd() public {
        FixedRateVault.Epoch memory e = _epoch(start, RATE, CAP);
        e.end = e.start;
        _expectInvalid(e);
    }

    function test_addEpoch_revertsIfOverlapsPrevious() public {
        FixedRateVault.Epoch memory first = _addEpoch(start);
        _expectInvalid(_epoch(first.end - 1, RATE, CAP));
    }

    function test_addEpoch_acceptsBackToBackEpochs() public {
        FixedRateVault.Epoch memory first = _addEpoch(start);
        _addEpoch(first.end);
        assertEq(vault.epochCount(), 2);
    }

    function test_addEpoch_revertsIfEntryWindowOutOfRange() public {
        FixedRateVault.Epoch memory e = _epoch(start, RATE, CAP);
        e.entryWindowEnd = e.start - 1;
        _expectInvalid(e);
        e.entryWindowEnd = e.end + 1;
        _expectInvalid(e);
    }

    function test_addEpoch_revertsIfAccrualOutOfRange() public {
        FixedRateVault.Epoch memory e = _epoch(start, RATE, CAP);
        e.accrualStart = e.start - 1;
        _expectInvalid(e);

        e = _epoch(start, RATE, CAP);
        e.accrualEnd = e.end + 1;
        _expectInvalid(e);

        e = _epoch(start, RATE, CAP);
        e.accrualStart = e.accrualEnd + 1;
        _expectInvalid(e);
    }

    function test_addEpoch_revertsIfExitWindowOutOfRange() public {
        FixedRateVault.Epoch memory e = _epoch(start, RATE, CAP);
        e.exitWindowStart = e.start - 1;
        _expectInvalid(e);
        e.exitWindowStart = e.end + 1;
        _expectInvalid(e);
    }

    function test_addEpoch_revertsIfTerminated() public {
        vm.prank(owner);
        vault.terminate();
        FixedRateVault.Epoch memory e = _epoch(start, RATE, CAP);
        vm.prank(owner);
        vm.expectRevert(FixedRateVault.VaultTerminated.selector);
        vault.addEpoch(e);
    }

    function _expectInvalid(FixedRateVault.Epoch memory e) internal {
        vm.prank(owner);
        vm.expectRevert(FixedRateVault.InvalidEpoch.selector);
        vault.addEpoch(e);
    }
}

contract ViewsTest is FixedRateVaultBase {
    function test_epochId_tracksLatestStartedEpoch() public {
        assertEq(vault.epochId(), 0);
        FixedRateVault.Epoch memory first = _addEpoch(start);
        _addEpoch(first.end);

        assertEq(vault.epochId(), 0);
        vm.warp(start);
        assertEq(vault.epochId(), 1);
        vm.warp(first.end - 1);
        assertEq(vault.epochId(), 1);
        vm.warp(first.end);
        assertEq(vault.epochId(), 2);
    }

    function test_currentRate_onlyDuringAccrual() public {
        FixedRateVault.Epoch memory e = _addEpoch(start);
        assertEq(vault.currentRate(), 0);
        vm.warp(e.start);
        assertEq(vault.currentRate(), 0);
        vm.warp(e.accrualStart);
        assertEq(vault.currentRate(), RATE);
        vm.warp(e.accrualEnd - 1);
        assertEq(vault.currentRate(), RATE);
        vm.warp(e.accrualEnd);
        assertEq(vault.currentRate(), 0);
    }

    function test_share_isVault() public view {
        assertEq(vault.share(), address(vault));
    }

    function test_strategy() public view {
        assertEq(address(vault.strategy()), address(strategy));
    }

    function test_supportsInterface() public view {
        assertTrue(vault.supportsInterface(type(IERC8416).interfaceId));
        assertTrue(vault.supportsInterface(type(IERC7540Redeem).interfaceId));
        assertTrue(vault.supportsInterface(type(IERC7540Operator).interfaceId));
        assertTrue(vault.supportsInterface(0x2f0a18c5)); // ERC-7575
        assertTrue(vault.supportsInterface(type(IERC165).interfaceId));
        assertFalse(vault.supportsInterface(0xdeadbeef));
    }

    function test_previewRedeemAndWithdraw_revert() public {
        vm.expectRevert(FixedRateVault.AsyncRedeem.selector);
        vault.previewRedeem(1);
        vm.expectRevert(FixedRateVault.AsyncRedeem.selector);
        vault.previewWithdraw(1);
    }
}

contract DepositTest is FixedRateVaultBase {
    FixedRateVault.Epoch internal e;

    function setUp() public override {
        super.setUp();
        e = _addEpoch(start);
    }

    function test_deposit_inEntryWindow_allocatesToStrategy() public {
        vm.warp(e.start);
        uint256 strategyBefore = token.balanceOf(address(strategy));

        uint256 shares = _deposit(alice, AMOUNT);

        assertEq(shares, AMOUNT);
        assertEq(vault.balanceOf(alice), AMOUNT);
        assertEq(vault.totalAssets(), AMOUNT);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(token.balanceOf(address(strategy)), strategyBefore + AMOUNT);
        assertEq(token.allowance(address(vault), address(strategy)), 0);
    }

    function test_mint_inEntryWindow() public {
        vm.warp(e.start);
        vm.prank(alice);
        uint256 assets = vault.mint(AMOUNT, alice);
        assertEq(assets, AMOUNT);
        assertEq(vault.balanceOf(alice), AMOUNT);
        assertEq(vault.maxDeposit(alice), CAP - AMOUNT);
    }

    function test_deposit_revertsBeforeEntryWindow() public {
        assertEq(vault.maxDeposit(alice), 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, alice, AMOUNT, 0));
        vault.deposit(AMOUNT, alice);
    }

    function test_deposit_revertsAfterEntryWindow() public {
        vm.warp(e.entryWindowEnd);
        assertEq(vault.maxDeposit(alice), 0);
        assertEq(vault.maxMint(alice), 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, alice, AMOUNT, 0));
        vault.deposit(AMOUNT, alice);
    }

    function test_deposit_enforcesEpochCap() public {
        vm.warp(e.start);
        _deposit(alice, CAP - AMOUNT);
        assertEq(vault.maxDeposit(bob), AMOUNT);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, bob, AMOUNT + 1, AMOUNT));
        vault.deposit(AMOUNT + 1, bob);

        _deposit(bob, AMOUNT);
        assertEq(vault.maxDeposit(bob), 0);
    }

    function test_deposit_unlimitedCap() public {
        FixedRateVault.Epoch memory e2 = _epoch(e.end, RATE, type(uint256).max);
        _addEpoch(e2);
        vm.warp(e2.start);
        assertEq(vault.maxDeposit(alice), type(uint256).max);
        assertEq(vault.maxMint(alice), type(uint256).max);

        _deposit(alice, 5_000e18);
        assertEq(vault.maxDeposit(alice), type(uint256).max);
    }

    function test_deposit_revertsIfStrategyPullsLess() public {
        vm.warp(e.start);
        strategy.setShortfall(1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FixedRateVault.AllocationFailed.selector, AMOUNT, AMOUNT - 1));
        vault.deposit(AMOUNT, alice);
    }

    function testFuzz_deposit_firstDepositorSharesEqualAssets(uint256 assets) public {
        assets = bound(assets, 1, CAP);
        vm.warp(e.start);
        assertEq(_deposit(alice, assets), assets);
        assertEq(vault.totalAssets(), assets);
    }
}

contract InterestTest is FixedRateVaultBase {
    FixedRateVault.Epoch internal e;

    function setUp() public override {
        super.setUp();
        e = _addEpoch(start);
        vm.warp(e.start);
        _deposit(alice, AMOUNT);
    }

    function test_noInterestBeforeAccrual() public {
        vm.warp(e.accrualStart);
        assertEq(vault.totalAssets(), AMOUNT);
    }

    function test_interestAccruesLinearlyDuringAccrual() public {
        vm.warp(e.accrualStart + 10 days);
        assertEq(vault.totalAssets(), AMOUNT + _interest(AMOUNT, RATE, 10 days));
    }

    function test_interestStopsAtAccrualEnd() public {
        uint256 expected = AMOUNT + _interest(AMOUNT, RATE, ACCRUAL);
        vm.warp(e.accrualEnd);
        assertEq(vault.totalAssets(), expected);
        vm.warp(e.end + 100 days);
        assertEq(vault.totalAssets(), expected);
    }

    function test_interestCompoundsAcrossEpochs() public {
        FixedRateVault.Epoch memory e2 = _addEpoch(e.end);
        uint256 afterFirst = AMOUNT + _interest(AMOUNT, RATE, ACCRUAL);

        vm.warp(e2.accrualEnd);
        assertEq(vault.totalAssets(), afterFirst + _interest(afterFirst, RATE, ACCRUAL));
    }

    function test_laterDepositorGetsFewerShares() public {
        FixedRateVault.Epoch memory e2 = _addEpoch(e.end);
        vm.warp(e2.start);

        uint256 shares = _deposit(bob, AMOUNT);
        assertLt(shares, AMOUNT);
        assertEq(shares, vault.convertToShares(AMOUNT));
        assertApproxEqAbs(vault.convertToAssets(shares), AMOUNT, 1);
    }

    function test_noInterestWithoutDeposits() public {
        FixedRateVault fresh = new FixedRateVault(token, strategy, "x", "x", owner);
        vm.prank(owner);
        fresh.addEpoch(_epoch(e.end, RATE, CAP));
        vm.warp(e.end + ENTRY + 10 days);
        assertEq(fresh.totalAssets(), 0);
    }

    function testFuzz_totalAssetsNonDecreasing(uint256 t1, uint256 t2) public {
        t1 = bound(t1, e.start, e.end + 365 days);
        t2 = bound(t2, t1, e.end + 365 days);
        vm.warp(t1);
        uint256 a1 = vault.totalAssets();
        vm.warp(t2);
        assertGe(vault.totalAssets(), a1);
    }

    function testFuzz_interestMatchesFormula(uint256 dt) public {
        dt = bound(dt, 0, ACCRUAL);
        vm.warp(e.accrualStart + dt);
        assertEq(vault.totalAssets(), AMOUNT + _interest(AMOUNT, RATE, dt));
    }
}

contract RedeemTest is FixedRateVaultBase {
    FixedRateVault.Epoch internal e;
    uint256 internal shares;

    function setUp() public override {
        super.setUp();
        e = _addEpoch(start);
        vm.warp(e.start);
        shares = _deposit(alice, AMOUNT);
    }

    function test_maxRequestRedeem_onlyInExitWindow() public {
        assertEq(vault.maxRequestRedeem(alice), 0);
        vm.warp(e.accrualStart);
        assertEq(vault.maxRequestRedeem(alice), 0);
        vm.warp(e.exitWindowStart);
        assertEq(vault.maxRequestRedeem(alice), shares);
        vm.warp(e.end);
        assertEq(vault.maxRequestRedeem(alice), 0);
    }

    function test_requestRedeem_revertsOutsideExitWindow() public {
        vm.prank(alice);
        vm.expectRevert(FixedRateVault.ExceededMaxRequestRedeem.selector);
        vault.requestRedeem(shares, alice, alice);
    }

    function test_requestRedeem_revertsAboveBalance() public {
        vm.warp(e.exitWindowStart);
        vm.prank(alice);
        vm.expectRevert(FixedRateVault.ExceededMaxRequestRedeem.selector);
        vault.requestRedeem(shares + 1, alice, alice);
    }

    function test_requestRedeem_escrowsSharesAndEmits() public {
        vm.warp(e.exitWindowStart);
        vm.expectEmit(address(vault));
        emit IERC7540Redeem.RedeemRequest(alice, alice, 0, alice, shares);
        vm.prank(alice);
        uint256 requestId = vault.requestRedeem(shares, alice, alice);

        assertEq(requestId, 0);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(address(vault)), shares);
        assertEq(vault.pendingRedeemRequest(0, alice), shares);
        assertEq(vault.claimableRedeemRequest(0, alice), 0);
        assertEq(vault.maxRedeem(alice), 0);
        assertEq(vault.maxWithdraw(alice), 0);
    }

    function test_requestRedeem_bySpenderWithAllowance() public {
        vm.warp(e.exitWindowStart);
        vm.prank(alice);
        vault.approve(carol, shares);

        vm.prank(carol);
        vault.requestRedeem(shares, carol, alice);
        assertEq(vault.pendingRedeemRequest(0, carol), shares);
        assertEq(vault.allowance(alice, carol), 0);
    }

    function test_requestRedeem_revertsWithoutAllowance() public {
        vm.warp(e.exitWindowStart);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, carol, 0, shares));
        vault.requestRedeem(shares, carol, alice);
    }

    function test_requestRedeem_byOperator() public {
        vm.warp(e.exitWindowStart);
        vm.prank(alice);
        vault.setOperator(bob, true);

        vm.prank(bob);
        vault.requestRedeem(shares, alice, alice);
        assertEq(vault.pendingRedeemRequest(0, alice), shares);
    }

    function test_fulfillRedeem_revertsIfNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.fulfillRedeem(alice);
    }

    function test_fulfillRedeem_noPendingReturnsZero() public {
        vm.prank(owner);
        assertEq(vault.fulfillRedeem(alice), 0);
    }

    function test_fullRedeemFlow_paysPrincipalPlusInterest() public {
        uint256 expected = AMOUNT + _interest(AMOUNT, RATE, ACCRUAL);
        vm.warp(e.exitWindowStart);
        _requestRedeem(alice, shares);

        vm.prank(owner);
        uint256 assets = vault.fulfillRedeem(alice);
        assertApproxEqAbs(assets, expected, 1);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.pendingRedeemRequest(0, alice), 0);
        assertEq(vault.claimableRedeemRequest(0, alice), shares);
        assertEq(vault.maxRedeem(alice), shares);
        assertEq(vault.maxWithdraw(alice), assets);
        assertEq(token.balanceOf(address(vault)), assets);

        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        assertEq(vault.redeem(shares, alice, alice), assets);
        assertEq(token.balanceOf(alice), before + assets);
        assertEq(vault.maxRedeem(alice), 0);
        assertEq(token.balanceOf(address(vault)), 0);
    }

    function test_redeem_partial() public {
        uint256 assets = _requestAndFulfill();
        vm.prank(alice);
        uint256 got = vault.redeem(shares / 2, alice, alice);
        assertEq(got, assets / 2);
        assertEq(vault.maxRedeem(alice), shares - shares / 2);
        assertEq(vault.maxWithdraw(alice), assets - got);
    }

    function test_withdraw_fullAndPartial() public {
        uint256 assets = _requestAndFulfill();

        vm.prank(alice);
        uint256 burned = vault.withdraw(assets / 3, bob, alice);
        assertGt(burned, 0);
        assertEq(token.balanceOf(bob), 10_000e18 + assets / 3);

        uint256 rest = vault.maxWithdraw(alice);
        vm.prank(alice);
        assertEq(vault.withdraw(rest, alice, alice), shares - burned);
        assertEq(vault.maxRedeem(alice), 0);
        assertEq(vault.maxWithdraw(alice), 0);
    }

    function test_redeem_revertsAboveClaimable() public {
        _requestAndFulfill();
        vm.prank(alice);
        vm.expectRevert(FixedRateVault.ExceededClaimable.selector);
        vault.redeem(shares + 1, alice, alice);
    }

    function test_withdraw_revertsAboveClaimable() public {
        uint256 assets = _requestAndFulfill();
        vm.prank(alice);
        vm.expectRevert(FixedRateVault.ExceededClaimable.selector);
        vault.withdraw(assets + 1, alice, alice);
    }

    function test_redeem_revertsIfNotControllerOrOperator() public {
        _requestAndFulfill();
        vm.prank(bob);
        vm.expectRevert(FixedRateVault.NotControllerOrOperator.selector);
        vault.redeem(shares, bob, alice);
    }

    function test_redeem_byOperator() public {
        uint256 assets = _requestAndFulfill();
        vm.prank(alice);
        vault.setOperator(bob, true);

        vm.prank(bob);
        vault.redeem(shares, bob, alice);
        assertEq(token.balanceOf(bob), 10_000e18 + assets);
    }

    function test_fulfillRedeem_revertsIfStrategyReturnsLess() public {
        vm.warp(e.exitWindowStart);
        _requestRedeem(alice, shares);
        strategy.setShortfall(1);
        vm.prank(owner);
        vm.expectPartialRevert(FixedRateVault.DeallocationFailed.selector);
        vault.fulfillRedeem(alice);
    }

    function _requestAndFulfill() internal returns (uint256 assets) {
        vm.warp(e.exitWindowStart);
        _requestRedeem(alice, shares);
        vm.prank(owner);
        assets = vault.fulfillRedeem(alice);
    }
}

contract OperatorTest is FixedRateVaultBase {
    function test_setOperator() public {
        vm.expectEmit(address(vault));
        emit IERC7540Operator.OperatorSet(alice, bob, true);
        vm.prank(alice);
        assertTrue(vault.setOperator(bob, true));
        assertTrue(vault.isOperator(alice, bob));

        vm.prank(alice);
        vault.setOperator(bob, false);
        assertFalse(vault.isOperator(alice, bob));
    }
}

contract TerminateTest is FixedRateVaultBase {
    FixedRateVault.Epoch internal e;

    function setUp() public override {
        super.setUp();
        e = _addEpoch(start);
        vm.warp(e.start);
        _deposit(alice, AMOUNT);
        _deposit(bob, AMOUNT);
    }

    function test_terminate_revertsIfNotOwner() public {
        vm.warp(e.end);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.terminate();
    }

    function test_terminate_revertsWhileEpochRunning() public {
        vm.warp(e.end - 1);
        vm.prank(owner);
        vm.expectRevert(FixedRateVault.CannotTerminate.selector);
        vault.terminate();
    }

    function test_terminate_revertsWithPendingFutureEpoch() public {
        _addEpoch(e.end + 1 days);
        vm.warp(e.end);
        vm.prank(owner);
        vm.expectRevert(FixedRateVault.CannotTerminate.selector);
        vault.terminate();
    }

    function test_terminate_withoutEpochs() public {
        FixedRateVault fresh = new FixedRateVault(token, strategy, "x", "x", owner);
        vm.prank(owner);
        fresh.terminate();
        assertTrue(fresh.isTerminated());
    }

    function test_terminate_pullsFundsAndEmits() public {
        vm.warp(e.end);
        uint256 total = vault.totalAssets();

        vm.expectEmit(address(vault));
        emit IERC8416.Terminated();
        vm.prank(owner);
        vault.terminate();

        assertTrue(vault.isTerminated());
        assertEq(token.balanceOf(address(vault)), total);
        assertEq(vault.maxDeposit(alice), 0);
        assertEq(vault.maxRequestRedeem(alice), vault.balanceOf(alice));
    }

    function test_terminate_revertsTwice() public {
        vm.warp(e.end);
        vm.startPrank(owner);
        vault.terminate();
        vm.expectRevert(FixedRateVault.VaultTerminated.selector);
        vault.terminate();
        vm.stopPrank();
    }

    function test_terminate_revertsIfStrategyReturnsLess() public {
        vm.warp(e.end);
        strategy.setShortfall(1);
        vm.prank(owner);
        vm.expectPartialRevert(FixedRateVault.DeallocationFailed.selector);
        vault.terminate();
    }

    function test_afterTerminate_pendingRequestsBecomeClaimable() public {
        uint256 shares = vault.balanceOf(alice);
        vm.warp(e.exitWindowStart);
        _requestRedeem(alice, shares);
        assertEq(vault.pendingRedeemRequest(0, alice), shares);

        vm.warp(e.end);
        vm.prank(owner);
        vault.terminate();

        uint256 expected = vault.convertToAssets(shares);
        assertEq(vault.pendingRedeemRequest(0, alice), 0);
        assertEq(vault.claimableRedeemRequest(0, alice), shares);
        assertEq(vault.maxRedeem(alice), shares);
        assertEq(vault.maxWithdraw(alice), expected);

        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        assertEq(vault.redeem(shares, alice, alice), expected);
        assertEq(token.balanceOf(alice), before + expected);
    }

    function test_afterTerminate_everyoneCanExit() public {
        vm.warp(e.end);
        vm.prank(owner);
        vault.terminate();
        uint256 vaultBalance = token.balanceOf(address(vault));

        uint256 aliceShares = vault.balanceOf(alice);
        _requestRedeem(alice, aliceShares);
        uint256 aliceAssets = vault.maxWithdraw(alice);
        vm.prank(alice);
        vault.withdraw(aliceAssets, alice, alice);

        uint256 bobShares = vault.balanceOf(bob);
        _requestRedeem(bob, bobShares);
        vm.prank(bob);
        uint256 bobAssets = vault.redeem(bobShares, bob, bob);

        assertEq(vault.totalSupply(), 0);
        assertApproxEqAbs(aliceAssets + bobAssets, vaultBalance, 2);
        assertLe(aliceAssets + bobAssets, vaultBalance);
    }
}
