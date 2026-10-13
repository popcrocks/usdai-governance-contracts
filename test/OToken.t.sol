// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "openzeppelin-contracts/contracts/access/IAccessControl.sol";
import {PausableUpgradeable} from "openzeppelin-contracts-upgradeable/contracts/utils/PausableUpgradeable.sol";
import {Initializable} from "openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";

import {OToken} from "../src/omnichain/OToken.sol";

/**
 * @title OToken unit tests
 * @notice Covers the spoke-chain mintable/burnable token: onlyOAdapter authorization,
 *         the v1.1 pause/unpause additions, and the immutable adapter wiring.
 *         OToken had 0% branch coverage prior to this suite.
 */
contract OTokenTest is Test {
    OToken internal otoken;

    address internal oAdapter = makeAddr("oAdapter");
    address internal admin = makeAddr("admin");
    address internal pauser = makeAddr("pauser");
    address internal user = makeAddr("user");
    address internal other = makeAddr("other");

    bytes32 internal constant PAUSE_ADMIN_ROLE = keccak256("PAUSE_ADMIN_ROLE");

    function setUp() public {
        address proxyAdmin = makeAddr("proxyAdmin");
        vm.startPrank(proxyAdmin);
        OToken impl = new OToken(oAdapter);
        otoken = OToken(
            address(
                new ERC1967Proxy(
                    address(impl), abi.encodeWithSelector(OToken.initialize.selector, "Chip", "CHIP", admin)
                )
            )
        );
        vm.stopPrank();

        vm.prank(admin);
        otoken.grantRole(PAUSE_ADMIN_ROLE, pauser);
    }

    /*------------------------------------------------------------------------*/
    /* Init                                                                   */
    /*------------------------------------------------------------------------*/

    function test__Initialization() public view {
        assertEq(otoken.name(), "Chip");
        assertEq(otoken.symbol(), "CHIP");
        assertEq(otoken.decimals(), 18);
        assertTrue(otoken.hasRole(0x00, admin));
        assertEq(otoken.IMPLEMENTATION_VERSION(), "1.1");
    }

    function test__CannotInitializeTwice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        otoken.initialize("X", "X", admin);
    }

    /*------------------------------------------------------------------------*/
    /* Mint / burn authorization                                              */
    /*------------------------------------------------------------------------*/

    function test__AdapterCanMint() public {
        vm.prank(oAdapter);
        otoken.mint(user, 1000 ether);
        assertEq(otoken.balanceOf(user), 1000 ether);
        assertEq(otoken.totalSupply(), 1000 ether);
    }

    function test__AdapterCanBurn() public {
        vm.prank(oAdapter);
        otoken.mint(user, 1000 ether);
        vm.prank(oAdapter);
        otoken.burn(user, 400 ether);
        assertEq(otoken.balanceOf(user), 600 ether);
        assertEq(otoken.totalSupply(), 600 ether);
    }

    function test__NonAdapterCannotMint() public {
        vm.prank(other);
        vm.expectRevert(bytes("Not authorized"));
        otoken.mint(user, 1 ether);
    }

    function test__NonAdapterCannotBurn() public {
        vm.prank(oAdapter);
        otoken.mint(user, 10 ether);
        vm.prank(other);
        vm.expectRevert(bytes("Not authorized"));
        otoken.burn(user, 1 ether);
    }

    function test__AdminCannotMint() public {
        // Even the default admin is not the adapter
        vm.prank(admin);
        vm.expectRevert(bytes("Not authorized"));
        otoken.mint(user, 1 ether);
    }

    /*------------------------------------------------------------------------*/
    /* Pause (v1.1)                                                           */
    /*------------------------------------------------------------------------*/

    function test__PauserCanPauseAndUnpause() public {
        vm.prank(pauser);
        otoken.pause();
        assertTrue(otoken.paused());
        vm.prank(pauser);
        otoken.unpause();
        assertFalse(otoken.paused());
    }

    function test__NonPauserCannotPause() public {
        vm.prank(other);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, other, PAUSE_ADMIN_ROLE)
        );
        otoken.pause();
    }

    function test__MintRevertsWhenPaused() public {
        vm.prank(pauser);
        otoken.pause();
        vm.prank(oAdapter);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        otoken.mint(user, 1 ether);
    }

    function test__BurnRevertsWhenPaused() public {
        vm.prank(oAdapter);
        otoken.mint(user, 10 ether);
        vm.prank(pauser);
        otoken.pause();
        vm.prank(oAdapter);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        otoken.burn(user, 1 ether);
    }

    function test__MintWorksAfterUnpause() public {
        vm.prank(pauser);
        otoken.pause();
        vm.prank(pauser);
        otoken.unpause();
        vm.prank(oAdapter);
        otoken.mint(user, 5 ether);
        assertEq(otoken.balanceOf(user), 5 ether);
    }

    /*------------------------------------------------------------------------*/
    /* Standard ERC20 transfers are unaffected by pause                       */
    /*------------------------------------------------------------------------*/

    function test__TransfersAllowedWhilePaused() public {
        vm.prank(oAdapter);
        otoken.mint(user, 100 ether);
        vm.prank(pauser);
        otoken.pause();

        // Pause only gates mint/burn, not plain holder transfers
        vm.prank(user);
        otoken.transfer(other, 40 ether);
        assertEq(otoken.balanceOf(other), 40 ether);
    }
}
