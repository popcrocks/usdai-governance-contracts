// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {ChipBridgeTest} from "./ChipBridge.t.sol";

import {SendParam, MessagingFee} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/OFTCore.sol";

/**
 * @title Chip bridge pause interaction tests
 * @notice Documents the OToken pause (v1.1) interaction with in-flight bridge messages:
 *         while the destination OToken is paused, inbound mint (lzReceive -> _credit)
 *         reverts, so a hub->spoke transfer locks CHIP on the hub but does not credit the
 *         spoke until unpause. Funds are NOT lost: the message is retried after unpause.
 *         Reuses the full LayerZero test harness from ChipBridgeTest.
 */
contract ChipBridgePauseTest is ChipBridgeTest {
    bytes32 internal constant PAUSE_ADMIN_ROLE = keccak256("PAUSE_ADMIN_ROLE");

    function _pauseOToken() internal {
        vm.startPrank(admin);
        oToken.grantRole(PAUSE_ADMIN_ROLE, admin);
        oToken.pause();
        vm.stopPrank();
    }

    function test__PausedDestinationStrandsThenRecoversTransfer() public {
        uint256 amount = 100 ether;

        // Pause the destination OToken
        _pauseOToken();
        assertTrue(oToken.paused());

        // Hub -> Spoke send: CHIP is locked on the hub regardless of destination state
        SendParam memory sendParam = _buildSendParam(spokeEid, userSpoke, amount);
        MessagingFee memory fee = oLockAdapter.quoteSend(sendParam, false);
        vm.prank(userHub);
        chip.approve(address(oLockAdapter), amount);
        vm.prank(userHub);
        oLockAdapter.send{value: fee.nativeFee}(sendParam, fee, payable(userHub));

        // Hub side committed: CHIP locked, user debited
        assertEq(chip.balanceOf(address(oLockAdapter)), amount);
        assertEq(chip.balanceOf(userHub), INITIAL_USER_BALANCE - amount);

        // Delivery (mint) reverts on the paused spoke -> transfer is stranded in-flight
        vm.expectRevert();
        this.verifyPackets(spokeEid, addressToBytes32(address(oAdapter)));
        assertEq(oToken.balanceOf(userSpoke), 0);

        // Operator unpauses and the message is retried successfully -> funds recovered
        vm.prank(admin);
        oToken.unpause();
        this.verifyPackets(spokeEid, addressToBytes32(address(oAdapter)));
        assertEq(oToken.balanceOf(userSpoke), amount);

        // Supply invariant preserved: CHIP locked on hub == OToken minted on spoke
        assertEq(chip.balanceOf(address(oLockAdapter)), oToken.totalSupply());
    }

    function test__PauseDoesNotAffectHubLockAccounting() public {
        // A paused spoke does not corrupt hub-side accounting even if never delivered.
        uint256 amount = 50 ether;
        _pauseOToken();

        SendParam memory sendParam = _buildSendParam(spokeEid, userSpoke, amount);
        MessagingFee memory fee = oLockAdapter.quoteSend(sendParam, false);
        vm.prank(userHub);
        chip.approve(address(oLockAdapter), amount);
        vm.prank(userHub);
        oLockAdapter.send{value: fee.nativeFee}(sendParam, fee, payable(userHub));

        assertEq(chip.balanceOf(address(oLockAdapter)), amount);
        assertEq(oToken.totalSupply(), 0); // not yet minted
    }
}
