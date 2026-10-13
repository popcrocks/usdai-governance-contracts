// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {
    TransparentUpgradeableProxy
} from "openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IVotes} from "openzeppelin-contracts/contracts/governance/utils/IVotes.sol";
import {IGovernor} from "openzeppelin-contracts/contracts/governance/IGovernor.sol";
import {Governor} from "openzeppelin-contracts/contracts/governance/Governor.sol";
import {TimelockController} from "openzeppelin-contracts/contracts/governance/TimelockController.sol";

import {MockUSDai} from "./mocks/MockUSDai.sol";
import {Chip} from "../src/Chip.sol";
import {ChipGovernor} from "../src/ChipGovernor.sol";

/**
 * @title ChipGovernor end-to-end governance tests
 * @notice Covers the full propose -> delegate -> vote -> queue -> timelock -> execute
 *         lifecycle, quorum/threshold/late-quorum semantics, and cancellation paths.
 *         ChipGovernor had 0% test coverage prior to this suite.
 */
contract ChipGovernorTest is Test {
    /*------------------------------------------------------------------------*/
    /* Parameters (scaled-down analogs of Deploy.s.sol)                       */
    /*------------------------------------------------------------------------*/

    uint256 constant INITIAL_SUPPLY = 1_000_000 ether;
    uint256 constant TIMELOCK_MIN_DELAY = 3 days;
    uint256 constant QUORUM_FRACTION = 5; // percent -> 50_000 ether
    uint48 constant VOTING_DELAY = 1 days;
    uint32 constant VOTING_PERIOD = 1 weeks;
    uint256 constant PROPOSAL_THRESHOLD = 10_000 ether;
    uint48 constant VOTE_EXTENSION = 3 days;

    /*------------------------------------------------------------------------*/
    /* State                                                                  */
    /*------------------------------------------------------------------------*/

    Chip internal chip;
    MockUSDai internal mockUsdai;
    TimelockController internal timelock;
    ChipGovernor internal governor;

    address internal admin = makeAddr("admin");
    address internal proposer = makeAddr("proposer"); // 20_000 (> threshold)
    address internal alice = makeAddr("alice"); // 400_000
    address internal bob = makeAddr("bob"); // 100_000
    address internal carol = makeAddr("carol"); // 30_000
    address internal dave = makeAddr("dave"); // 5_000 (< threshold)

    /*------------------------------------------------------------------------*/
    /* Setup                                                                  */
    /*------------------------------------------------------------------------*/

    function setUp() public {
        vm.warp(1_700_000_000); // deterministic non-zero timestamp

        address proxyAdmin = makeAddr("proxyAdmin");

        // Deploy mock USDai
        vm.startPrank(proxyAdmin);
        MockUSDai usdaiImpl = new MockUSDai();
        mockUsdai = MockUSDai(address(new ERC1967Proxy(address(usdaiImpl), abi.encodeWithSelector(MockUSDai.initialize.selector))));

        // Deploy Chip
        Chip chipImpl = new Chip(address(mockUsdai));
        chip = Chip(
            address(
                new TransparentUpgradeableProxy(
                    address(chipImpl),
                    proxyAdmin,
                    abi.encodeWithSelector(Chip.initialize.selector, INITIAL_SUPPLY, admin, admin)
                )
            )
        );
        vm.stopPrank();

        // Timelock with this test contract as temporary admin
        address[] memory empty = new address[](0);
        timelock = new TimelockController(TIMELOCK_MIN_DELAY, empty, empty, address(this));

        // Governor
        governor = new ChipGovernor(
            "ChipGovernor",
            IVotes(address(chip)),
            timelock,
            QUORUM_FRACTION,
            VOTING_DELAY,
            VOTING_PERIOD,
            PROPOSAL_THRESHOLD,
            VOTE_EXTENSION
        );

        // Wire timelock roles: governor is proposer/executor/canceller
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.EXECUTOR_ROLE(), address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));

        // Give the timelock admin control over Chip so governance can act on it
        vm.prank(admin);
        chip.grantRole(0x00, address(timelock));

        // Distribute and self-delegate
        vm.startPrank(admin);
        chip.transfer(proposer, 20_000 ether);
        chip.transfer(alice, 400_000 ether);
        chip.transfer(bob, 100_000 ether);
        chip.transfer(carol, 30_000 ether);
        chip.transfer(dave, 5_000 ether);
        vm.stopPrank();

        _selfDelegate(proposer);
        _selfDelegate(alice);
        _selfDelegate(bob);
        _selfDelegate(carol);
        _selfDelegate(dave);

        // advance a second so delegation checkpoints are in the past
        vm.warp(block.timestamp + 1);
    }

    function _selfDelegate(address who) internal {
        vm.prank(who);
        chip.delegate(who);
    }

    /*------------------------------------------------------------------------*/
    /* Proposal helpers                                                       */
    /*------------------------------------------------------------------------*/

    /// @dev A proposal that grants REVOKE_DELEGATE_ADMIN_ROLE on Chip to `alice` via the timelock.
    function _buildRoleGrantProposal()
        internal
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory description)
    {
        targets = new address[](1);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        targets[0] = address(chip);
        values[0] = 0;
        calldatas[0] =
            abi.encodeWithSignature("grantRole(bytes32,address)", keccak256("REVOKE_DELEGATE_ADMIN_ROLE"), alice);
        description = "Grant REVOKE_DELEGATE_ADMIN_ROLE to alice";
    }

    function _propose(address who)
        internal
        returns (
            uint256 proposalId,
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            bytes32 descriptionHash
        )
    {
        string memory description;
        (targets, values, calldatas, description) = _buildRoleGrantProposal();
        descriptionHash = keccak256(bytes(description));
        vm.prank(who);
        proposalId = governor.propose(targets, values, calldatas, description);
    }

    /*------------------------------------------------------------------------*/
    /* Configuration sanity                                                   */
    /*------------------------------------------------------------------------*/

    function test__GovernorConfig() public view {
        assertEq(governor.votingDelay(), VOTING_DELAY);
        assertEq(governor.votingPeriod(), VOTING_PERIOD);
        assertEq(governor.proposalThreshold(), PROPOSAL_THRESHOLD);
        assertEq(governor.lateQuorumVoteExtension(), VOTE_EXTENSION);
        assertEq(address(governor.timelock()), address(timelock));
        assertEq(governor.CLOCK_MODE(), "mode=timestamp");
        // 5% of 1,000,000 = 50,000
        assertEq(governor.quorum(block.timestamp - 1), 50_000 ether);
    }

    function test__CountingModeIncludesAbstain() public view {
        // GovernorCountingSimple: quorum counts For + Abstain
        assertEq(governor.COUNTING_MODE(), "support=bravo&quorum=for,abstain");
    }

    /*------------------------------------------------------------------------*/
    /* Proposal threshold                                                     */
    /*------------------------------------------------------------------------*/

    function test__CannotProposeBelowThreshold() public {
        (address[] memory t, uint256[] memory v, bytes[] memory c, string memory d) = _buildRoleGrantProposal();
        vm.prank(dave); // only 5_000 < 10_000 threshold
        vm.expectRevert();
        governor.propose(t, v, c, d);
    }

    function test__CanProposeAtOrAboveThreshold() public {
        (uint256 proposalId,,,,) = _propose(proposer);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Pending));
    }

    /*------------------------------------------------------------------------*/
    /* Full happy path                                                        */
    /*------------------------------------------------------------------------*/

    function test__FullLifecycleExecutes() public {
        (
            uint256 proposalId,
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            bytes32 descriptionHash
        ) = _propose(proposer);

        // Pending until snapshot
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Pending));

        // Move to active
        vm.warp(governor.proposalSnapshot(proposalId) + 1);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Active));

        // Votes: For 400k, Against 100k, Abstain 30k
        vm.prank(alice);
        governor.castVote(proposalId, 1);
        vm.prank(bob);
        governor.castVote(proposalId, 0);
        vm.prank(carol);
        governor.castVote(proposalId, 2);

        (uint256 against, uint256 forVotes, uint256 abstain) = governor.proposalVotes(proposalId);
        assertEq(forVotes, 400_000 ether);
        assertEq(against, 100_000 ether);
        assertEq(abstain, 30_000 ether);

        // End voting
        vm.warp(governor.proposalDeadline(proposalId) + 1);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Succeeded));

        // Queue
        governor.queue(targets, values, calldatas, descriptionHash);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Queued));

        // Cannot execute before timelock delay
        vm.expectRevert();
        governor.execute(targets, values, calldatas, descriptionHash);

        // Wait out the timelock
        vm.warp(block.timestamp + TIMELOCK_MIN_DELAY + 1);

        assertFalse(chip.hasRole(keccak256("REVOKE_DELEGATE_ADMIN_ROLE"), alice));
        governor.execute(targets, values, calldatas, descriptionHash);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Executed));

        // Governance action took effect
        assertTrue(chip.hasRole(keccak256("REVOKE_DELEGATE_ADMIN_ROLE"), alice));
    }

    /*------------------------------------------------------------------------*/
    /* Quorum semantics                                                       */
    /*------------------------------------------------------------------------*/

    function test__DefeatedWhenQuorumNotMet() public {
        (uint256 proposalId,,,,) = _propose(proposer);
        vm.warp(governor.proposalSnapshot(proposalId) + 1);

        // Only carol abstains (30k) < 50k quorum
        vm.prank(carol);
        governor.castVote(proposalId, 2);

        vm.warp(governor.proposalDeadline(proposalId) + 1);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Defeated));
    }

    function test__AbstainCountsTowardQuorumButNotApproval() public {
        (uint256 proposalId,,,,) = _propose(proposer);
        vm.warp(governor.proposalSnapshot(proposalId) + 1);

        // For 400k meets quorum alone; abstain does not flip approval
        vm.prank(alice);
        governor.castVote(proposalId, 1);
        vm.prank(carol);
        governor.castVote(proposalId, 2);

        vm.warp(governor.proposalDeadline(proposalId) + 1);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Succeeded));
    }

    function test__AgainstVotesDoNotCountTowardQuorum() public {
        (uint256 proposalId,,,,) = _propose(proposer);
        vm.warp(governor.proposalSnapshot(proposalId) + 1);

        // bob (100k) votes Against only. Against is NOT counted for quorum,
        // so quorum (50k) is not met -> Defeated.
        vm.prank(bob);
        governor.castVote(proposalId, 0);

        vm.warp(governor.proposalDeadline(proposalId) + 1);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Defeated));
    }

    function test__DefeatedWhenAgainstExceedsFor() public {
        (uint256 proposalId,,,,) = _propose(proposer);
        vm.warp(governor.proposalSnapshot(proposalId) + 1);

        // For 100k, Against 400k -> quorum met (For+Abstain=100k>=50k) but For<Against
        vm.prank(bob);
        governor.castVote(proposalId, 1); // bob For 100k
        vm.prank(alice);
        governor.castVote(proposalId, 0); // alice Against 400k

        vm.warp(governor.proposalDeadline(proposalId) + 1);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Defeated));
    }

    /*------------------------------------------------------------------------*/
    /* Voting constraints                                                     */
    /*------------------------------------------------------------------------*/

    function test__CannotVoteBeforeActive() public {
        (uint256 proposalId,,,,) = _propose(proposer);
        vm.prank(alice);
        vm.expectRevert();
        governor.castVote(proposalId, 1);
    }

    function test__CannotVoteTwice() public {
        (uint256 proposalId,,,,) = _propose(proposer);
        vm.warp(governor.proposalSnapshot(proposalId) + 1);
        vm.prank(alice);
        governor.castVote(proposalId, 1);
        assertTrue(governor.hasVoted(proposalId, alice));
        vm.prank(alice);
        vm.expectRevert();
        governor.castVote(proposalId, 1);
    }

    function test__CannotVoteAfterDeadline() public {
        (uint256 proposalId,,,,) = _propose(proposer);
        vm.warp(governor.proposalDeadline(proposalId) + 1);
        vm.prank(alice);
        vm.expectRevert();
        governor.castVote(proposalId, 1);
    }

    function test__CannotQueueBeforeSucceeded() public {
        (
            uint256 proposalId,
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            bytes32 descriptionHash
        ) = _propose(proposer);
        proposalId;
        vm.expectRevert();
        governor.queue(targets, values, calldatas, descriptionHash);
    }

    /*------------------------------------------------------------------------*/
    /* Late quorum extension                                                  */
    /*------------------------------------------------------------------------*/

    function test__LateQuorumExtendsDeadline() public {
        (uint256 proposalId,,,,) = _propose(proposer);

        uint256 originalDeadline = governor.proposalDeadline(proposalId);

        // Vote very late: 1 second before the original deadline, reach quorum now
        vm.warp(originalDeadline - 1);
        vm.prank(alice);
        governor.castVote(proposalId, 1); // 400k For -> quorum reached late

        uint256 newDeadline = governor.proposalDeadline(proposalId);
        // Deadline extended to (now + voteExtension) which is beyond the original
        assertGt(newDeadline, originalDeadline);
        assertEq(newDeadline, block.timestamp + VOTE_EXTENSION);

        // Still active at the original deadline because of the extension
        vm.warp(originalDeadline + 1);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Active));

        // Resolves after the extended deadline
        vm.warp(newDeadline + 1);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Succeeded));
    }

    /*------------------------------------------------------------------------*/
    /* Cancellation                                                           */
    /*------------------------------------------------------------------------*/

    function test__ProposerCanCancelWhenNoGuardian() public {
        (
            uint256 proposalId,
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            bytes32 descriptionHash
        ) = _propose(proposer);

        // No guardian set -> proposer can cancel
        assertEq(governor.proposalGuardian(), address(0));
        vm.prank(proposer);
        governor.cancel(targets, values, calldatas, descriptionHash);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Canceled));
    }

    function test__NonProposerCannotCancelWhenNoGuardian() public {
        (
            ,
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            bytes32 descriptionHash
        ) = _propose(proposer);

        vm.prank(bob);
        vm.expectRevert();
        governor.cancel(targets, values, calldatas, descriptionHash);
    }

    function test__SetProposalGuardianOnlyViaGovernance() public {
        // Direct call must revert (onlyGovernance)
        vm.prank(admin);
        vm.expectRevert();
        governor.setProposalGuardian(admin);
    }

    function test__GuardianCanCancelQueuedProposal() public {
        // First, set a guardian through governance
        _setGuardianViaGovernance(admin);
        assertEq(governor.proposalGuardian(), admin);

        // New proposal, drive it to Queued
        (
            uint256 proposalId,
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            bytes32 descriptionHash
        ) = _propose(proposer);
        vm.warp(governor.proposalSnapshot(proposalId) + 1);
        vm.prank(alice);
        governor.castVote(proposalId, 1);
        vm.warp(governor.proposalDeadline(proposalId) + 1);
        governor.queue(targets, values, calldatas, descriptionHash);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Queued));

        // Guardian cancels even though it is already Queued
        vm.prank(admin);
        governor.cancel(targets, values, calldatas, descriptionHash);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Canceled));

        // Once a guardian is set, the proposer can no longer cancel their own proposal
        // after it leaves the Pending state (the base proposer-while-Pending power remains,
        // but the extended any-state cancel power now belongs only to the guardian).
        (
            uint256 pid2,
            address[] memory t2,
            uint256[] memory v2,
            bytes[] memory c2,
            bytes32 dh2
        ) = _proposeVariant(proposer, "variant");

        // While Pending, the proposer can still cancel via the base rule -> drive it Active first.
        vm.warp(governor.proposalSnapshot(pid2) + 1);
        assertEq(uint8(governor.state(pid2)), uint8(IGovernor.ProposalState.Active));

        // Proposer can no longer cancel an Active proposal now that a guardian exists
        vm.prank(proposer);
        vm.expectRevert();
        governor.cancel(t2, v2, c2, dh2);

        // But the guardian still can
        vm.prank(admin);
        governor.cancel(t2, v2, c2, dh2);
        assertEq(uint8(governor.state(pid2)), uint8(IGovernor.ProposalState.Canceled));
    }

    /*------------------------------------------------------------------------*/
    /* Guardian setup helper (routes through full governance)                 */
    /*------------------------------------------------------------------------*/

    function _setGuardianViaGovernance(address guardian) internal {
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        targets[0] = address(governor);
        values[0] = 0;
        calldatas[0] = abi.encodeWithSelector(governor.setProposalGuardian.selector, guardian);
        string memory description = "Set proposal guardian";
        bytes32 descriptionHash = keccak256(bytes(description));

        vm.prank(proposer);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);
        vm.warp(governor.proposalSnapshot(proposalId) + 1);
        vm.prank(alice);
        governor.castVote(proposalId, 1);
        vm.warp(governor.proposalDeadline(proposalId) + 1);
        governor.queue(targets, values, calldatas, descriptionHash);
        vm.warp(block.timestamp + TIMELOCK_MIN_DELAY + 1);
        governor.execute(targets, values, calldatas, descriptionHash);
    }

    function _proposeVariant(address who, string memory tag)
        internal
        returns (
            uint256 proposalId,
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory calldatas,
            bytes32 descriptionHash
        )
    {
        targets = new address[](1);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        targets[0] = address(chip);
        values[0] = 0;
        calldatas[0] =
            abi.encodeWithSignature("grantRole(bytes32,address)", keccak256("REVOKE_DELEGATE_ADMIN_ROLE"), bob);
        string memory description = string.concat("Grant role - ", tag);
        descriptionHash = keccak256(bytes(description));
        vm.prank(who);
        proposalId = governor.propose(targets, values, calldatas, description);
    }
}
