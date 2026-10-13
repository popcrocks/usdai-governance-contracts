// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.33;

import {console} from "forge-std/Script.sol";

import {Chip} from "src/Chip.sol";
import {StakedChip} from "src/StakedChip.sol";
import {TimelockController} from "src/TimelockController.sol";
import {ChipGovernor} from "src/ChipGovernor.sol";

import {
    TransparentUpgradeableProxy
} from "openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IVotes} from "openzeppelin-contracts/contracts/governance/utils/IVotes.sol";

import {Deployer} from "script/utils/Deployer.s.sol";

/**
 * @notice Development / single-chain deployment script.
 * @dev For production use DeployProductionEnvironment.s.sol, which uses deterministic
 *      CreateX addresses and assigns privileged roles to the admin/treasury multisigs
 *      rather than to the deployer EOA. This script grants CANCELLER_ROLE to the
 *      deploying account for convenience and is not intended for mainnet.
 */
contract Deploy is Deployer {
    uint256 private constant TOKEN_SUPPLY = 10e9 ether;
    uint256 private constant TIMELOCK_MIN_DELAY = 3 days;
    string private constant GOVERNOR_NAME = "ChipGovernor";
    uint256 private constant GOVERNOR_QUORUM_FRACTION = 5;
    uint48 private constant GOVERNOR_VOTING_DELAY = 1 days;
    uint32 private constant GOVERNOR_VOTING_PERIOD = 1 weeks;
    uint256 private constant GOVERNOR_PROPOSAL_THRESHOLD = 100e6 ether;
    uint48 private constant GOVERNOR_VOTE_EXTENSION = 3 days;

    function run(
        address usdaiAddress,
        address treasury
    ) public broadcast useDeployment {
        if (_deployment.chip != address(0)) revert AlreadyDeployed();
        if (_deployment.stakedChip != address(0)) revert AlreadyDeployed();
        if (_deployment.governor != address(0)) revert AlreadyDeployed();
        if (_deployment.timelock != address(0)) revert AlreadyDeployed();

        console.log("Deploying from account: %s\n", msg.sender);

        console.log("Deploying Chip implementation...");
        Chip chipImpl = new Chip(usdaiAddress);

        console.log("Deploying TimelockController...");
        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](0);
        TimelockController timelock = new TimelockController(TIMELOCK_MIN_DELAY, proposers, executors, msg.sender);

        console.log("Deploying Chip proxy...");
        TransparentUpgradeableProxy chip = new TransparentUpgradeableProxy(
            address(chipImpl),
            address(msg.sender),
            abi.encodeWithSelector(Chip.initialize.selector, TOKEN_SUPPLY, treasury, msg.sender)
        );

        console.log("Deploying ChipGovernor...");
        ChipGovernor governor = new ChipGovernor(
            GOVERNOR_NAME,
            IVotes(address(chip)),
            timelock,
            GOVERNOR_QUORUM_FRACTION,
            GOVERNOR_VOTING_DELAY,
            GOVERNOR_VOTING_PERIOD,
            GOVERNOR_PROPOSAL_THRESHOLD,
            GOVERNOR_VOTE_EXTENSION
        );

        console.log("Deploying StakedChip implementation...");
        StakedChip stakedChipImpl = new StakedChip(usdaiAddress, address(chip));

        console.log("Deploying StakedChip proxy...");
        TransparentUpgradeableProxy stakedChip = new TransparentUpgradeableProxy(
            address(stakedChipImpl),
            address(msg.sender),
            abi.encodeWithSelector(StakedChip.initialize.selector, msg.sender)
        );

        console.log("Granting TimelockController PROPOSER_ROLE to governor...");
        timelock.grantRole(keccak256("PROPOSER_ROLE"), address(governor));

        console.log("Granting TimelockController CANCELLER_ROLE to governor...");
        timelock.grantRole(keccak256("CANCELLER_ROLE"), address(governor));

        console.log("Granting TimelockController EXECUTOR_ROLE to governor...");
        timelock.grantRole(keccak256("EXECUTOR_ROLE"), address(governor));

        console.log("Granting TimelockController CANCELLER_ROLE to admin...");
        timelock.grantRole(keccak256("CANCELLER_ROLE"), msg.sender);

        console.log("Renouncing TimelockController DEFAULT_ADMIN_ROLE from admin...");
        timelock.renounceRole(0x00, msg.sender);

        console.log("Granting Chip DEFAULT_ADMIN_ROLE to TimelockController...");
        Chip(address(chip)).grantRole(0x00, address(timelock));

        console.log("Granting Chip REVOKE_DELEGATE_ADMIN_ROLE to admin...");
        Chip(address(chip)).grantRole(keccak256("REVOKE_DELEGATE_ADMIN_ROLE"), msg.sender);

        console.log("Granting StakedChip DEFAULT_ADMIN_ROLE to TimelockController...");
        StakedChip(address(stakedChip)).grantRole(0x00, address(timelock));

        console.log("Granting StakedChip PAUSE_ADMIN_ROLE to admin...");
        StakedChip(address(stakedChip)).grantRole(keccak256("PAUSE_ADMIN_ROLE"), msg.sender);

        console.log("");
        console.log("Chip impl:             %s", address(chipImpl));
        console.log("Chip:                  %s", address(chip));
        console.log("StakedChip impl:       %s", address(stakedChipImpl));
        console.log("StakedChip:            %s", address(stakedChip));
        console.log("TimelockController:    %s", address(timelock));
        console.log("ChipGovernor:          %s", address(governor));
        console.log("");

        /* Log deployment */
        _deployment.chip = address(chip);
        _deployment.stakedChip = address(stakedChip);
        _deployment.timelock = address(timelock);
        _deployment.governor = address(governor);
    }
}
