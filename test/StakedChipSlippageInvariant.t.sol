// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {
    TransparentUpgradeableProxy
} from "openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {MockUSDai} from "./mocks/MockUSDai.sol";
import {Chip} from "../src/Chip.sol";
import {StakedChip} from "../src/StakedChip.sol";
import {IStakedChip} from "../src/interfaces/IStakedChip.sol";

/**
 * @title StakedChip slippage, invariant and anti-inflation tests
 * @notice Exercises the slippage overloads deposit(amount,receiver,minShares) /
 *         mint(shares,receiver,maxAmount) (previously untested branches) and locks in
 *         the key economic invariants: storage-based totalAssets makes donations
 *         inert (no inflation attack), and depositBalance tracks the vault's CHIP balance.
 */
contract StakedChipSlippageInvariantTest is Test {
    uint128 constant LOCKED_SHARES = 1e6;

    Chip internal chip;
    StakedChip internal vault;
    MockUSDai internal mockUsdai;

    address internal admin = makeAddr("admin");
    address internal user1 = makeAddr("user1");
    address internal user2 = makeAddr("user2");
    address internal attacker = makeAddr("attacker");

    function setUp() public {
        address proxyAdmin = makeAddr("proxyAdmin");
        vm.startPrank(proxyAdmin);
        MockUSDai usdaiImpl = new MockUSDai();
        mockUsdai = MockUSDai(
            address(new ERC1967Proxy(address(usdaiImpl), abi.encodeWithSelector(MockUSDai.initialize.selector)))
        );

        Chip chipImpl = new Chip(address(mockUsdai));
        chip = Chip(
            address(
                new TransparentUpgradeableProxy(
                    address(chipImpl),
                    proxyAdmin,
                    abi.encodeWithSelector(Chip.initialize.selector, 1_000_000 ether, admin, admin)
                )
            )
        );

        StakedChip vaultImpl = new StakedChip(address(mockUsdai), address(chip));
        vault = StakedChip(
            address(
                new TransparentUpgradeableProxy(
                    address(vaultImpl), proxyAdmin, abi.encodeWithSelector(StakedChip.initialize.selector, admin)
                )
            )
        );
        vm.stopPrank();

        vm.startPrank(admin);
        chip.transfer(user1, 200_000 ether);
        chip.transfer(user2, 200_000 ether);
        chip.transfer(attacker, 200_000 ether);
        vm.stopPrank();

        vm.prank(user1);
        chip.approve(address(vault), type(uint256).max);
        vm.prank(user2);
        chip.approve(address(vault), type(uint256).max);
        vm.prank(attacker);
        chip.approve(address(vault), type(uint256).max);
    }

    /*------------------------------------------------------------------------*/
    /* Slippage overloads                                                     */
    /*------------------------------------------------------------------------*/

    function test__DepositRevertsWhenMinSharesNotMet() public {
        // first deposit establishes the vault 1:1
        vm.prank(user1);
        vault.deposit(100 ether, user1, 0);

        uint256 amount = 100 ether;
        uint256 expected = vault.convertToShares(amount);
        vm.prank(user2);
        vm.expectRevert(IStakedChip.InvalidAmount.selector);
        vault.deposit(amount, user2, expected + 1); // demand more than possible
    }

    function test__DepositSucceedsWhenMinSharesMet() public {
        vm.prank(user1);
        vault.deposit(100 ether, user1, 0);

        uint256 amount = 100 ether;
        uint256 expected = vault.convertToShares(amount);
        vm.prank(user2);
        uint256 shares = vault.deposit(amount, user2, expected);
        assertEq(shares, expected);
        assertEq(vault.balanceOf(user2), shares);
    }

    function test__MintRevertsWhenMaxAmountExceeded() public {
        vm.prank(user1);
        vault.deposit(100 ether, user1, 0);

        uint256 shares = 50 ether;
        uint256 cost = vault.convertToAssets(shares);
        vm.prank(user2);
        vm.expectRevert(IStakedChip.InvalidAmount.selector);
        vault.mint(shares, user2, cost - 1); // cap below the real cost
    }

    function test__MintSucceedsWhenMaxAmountMet() public {
        vm.prank(user1);
        vault.deposit(100 ether, user1, 0);

        uint256 shares = 50 ether;
        uint256 cost = vault.convertToAssets(shares);
        vm.prank(user2);
        uint256 spent = vault.mint(shares, user2, cost);
        assertEq(spent, cost);
        assertEq(vault.balanceOf(user2), shares);
    }

    /*------------------------------------------------------------------------*/
    /* First-deposit edge cases                                               */
    /*------------------------------------------------------------------------*/

    function test__FirstDepositBelowLockedSharesReverts() public {
        // convertToShares underflows: assets - LOCKED_SHARES with assets < LOCKED_SHARES
        vm.prank(user1);
        vm.expectRevert();
        vault.deposit(LOCKED_SHARES - 1, user1, 0);
    }

    function test__FirstDepositEqualToLockedSharesRevertsZeroShares() public {
        // shares == 0 -> InvalidAmount
        vm.prank(user1);
        vm.expectRevert(IStakedChip.InvalidAmount.selector);
        vault.deposit(LOCKED_SHARES, user1, 0);
    }

    function test__FirstDepositMintsLockedSharesToDead() public {
        vm.prank(user1);
        uint256 shares = vault.deposit(1000 ether, user1, 0);
        assertEq(vault.balanceOf(address(0xdead)), LOCKED_SHARES);
        assertEq(shares, 1000 ether - LOCKED_SHARES);
        assertEq(vault.totalSupply(), 1000 ether);
        assertEq(vault.totalAssets(), 1000 ether);
    }

    /*------------------------------------------------------------------------*/
    /* Anti-inflation: storage-based totalAssets makes donations inert        */
    /*------------------------------------------------------------------------*/

    function test__DonationDoesNotChangeSharePrice() public {
        vm.prank(user1);
        vault.deposit(1000 ether, user1, 0);

        uint256 assetsPerShareBefore = vault.convertToAssets(1e18);
        uint256 sharesPerAssetBefore = vault.convertToShares(1e18);
        uint256 totalAssetsBefore = vault.totalAssets();

        // Attacker donates a large amount of CHIP directly to the vault
        vm.prank(attacker);
        chip.transfer(address(vault), 100_000 ether);

        // Share price is unchanged because totalAssets() reads storage, not balanceOf
        assertEq(vault.convertToAssets(1e18), assetsPerShareBefore);
        assertEq(vault.convertToShares(1e18), sharesPerAssetBefore);
        assertEq(vault.totalAssets(), totalAssetsBefore);

        // A subsequent depositor is not diluted by the donation
        vm.prank(user2);
        uint256 shares = vault.deposit(1000 ether, user2, 0);
        assertEq(shares, 1000 ether); // still 1:1
    }

    function test__ClassicInflationAttackFails() public {
        // Attacker front-runs: makes the smallest possible first deposit...
        vm.prank(attacker);
        vault.deposit(LOCKED_SHARES + 1, attacker, 0); // 1 share to attacker, 1e6 locked

        // ...then donates a huge amount trying to inflate the share price
        vm.prank(attacker);
        chip.transfer(address(vault), 100_000 ether);

        // Victim deposits; must NOT round to zero shares (donation ignored)
        vm.prank(user1);
        uint256 victimShares = vault.deposit(1000 ether, user1, 0);
        assertGt(victimShares, 0);
        // Victim can redeem back approximately what they put in
        vm.prank(user1);
        uint256 redeemed = vault.redeem(victimShares, user1, user1);
        assertApproxEqAbs(redeemed, 1000 ether, 2);
    }

    /*------------------------------------------------------------------------*/
    /* Invariant: depositBalance == totalAssets <= vault CHIP balance         */
    /*------------------------------------------------------------------------*/

    function test__DepositBalanceTracksAccounting() public {
        vm.prank(user1);
        vault.deposit(5000 ether, user1, 0);
        vm.prank(user2);
        vault.deposit(3000 ether, user2, 0);

        assertEq(vault.totalAssets(), 8000 ether);
        assertEq(vault.totalAssets(), vault.totalSupply());
        // Actual CHIP held >= accounted assets (equal when no donations)
        assertGe(chip.balanceOf(address(vault)), vault.totalAssets());
        assertEq(chip.balanceOf(address(vault)), 8000 ether);

        vm.prank(user1);
        vault.withdraw(2000 ether, user1, user1);
        assertEq(vault.totalAssets(), 6000 ether);
        assertEq(chip.balanceOf(address(vault)), 6000 ether);
        assertEq(vault.totalAssets(), vault.totalSupply());
    }

    /*------------------------------------------------------------------------*/
    /* Fuzz: 1:1 invariant holds across arbitrary deposit/withdraw sequences  */
    /*------------------------------------------------------------------------*/

    function testFuzz__OneToOneInvariant(uint256 d1, uint256 d2, uint256 w1) public {
        d1 = bound(d1, LOCKED_SHARES + 1, 150_000 ether);
        d2 = bound(d2, 1, 150_000 ether);

        vm.prank(user1);
        uint256 s1 = vault.deposit(d1, user1, 0);

        vm.prank(user2);
        uint256 s2 = vault.deposit(d2, user2, 0);

        // ratio is exactly 1: shares minted equal assets in (user1 funds the locked shares)
        assertEq(s1, d1 - LOCKED_SHARES);
        assertEq(s2, d2);
        assertEq(vault.totalAssets(), vault.totalSupply());
        assertEq(chip.balanceOf(address(vault)), vault.totalAssets());

        // user1 withdraws a bounded amount
        w1 = bound(w1, 1, vault.maxWithdraw(user1));
        uint256 balBefore = chip.balanceOf(user1);
        vm.prank(user1);
        vault.withdraw(w1, user1, user1);
        assertEq(chip.balanceOf(user1), balBefore + w1);

        // invariant preserved
        assertEq(vault.totalAssets(), vault.totalSupply());
        assertEq(chip.balanceOf(address(vault)), vault.totalAssets());
    }
}
