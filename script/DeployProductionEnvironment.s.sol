// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.33;

import {console} from "forge-std/Script.sol";

import {
    TransparentUpgradeableProxy
} from "openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IVotes} from "openzeppelin-contracts/contracts/governance/utils/IVotes.sol";
import {IAccessControl} from "openzeppelin-contracts/contracts/access/IAccessControl.sol";

import {Chip} from "src/Chip.sol";
import {StakedChip} from "src/StakedChip.sol";
import {TimelockController} from "src/TimelockController.sol";
import {ChipGovernor} from "src/ChipGovernor.sol";

import {Deployer} from "script/utils/Deployer.s.sol";

interface ICreateX {
    function computeCreate3Address(
        bytes32 salt
    ) external view returns (address computedAddress);
    function deployCreate3(
        bytes32 salt,
        bytes memory initCode
    ) external payable returns (address newContract);
}

contract DeployProductionEnvironment is Deployer {
    ICreateX internal constant CREATEX = ICreateX(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);

    address internal constant USDAI_ADDRESS = 0x0A1a1A107E45b7Ced86833863f482BC5f4ed82EF;

    address internal constant CHIP_ADDRESS = 0x0C1c1C109FE34733fca54b82d7B46B75CFb71F6e;
    bytes32 internal constant CHIP_SALT = 0x783b08aa21de056717173f72e04be0e91328a07b00f082be5c69d6c6033fe67d;
    address internal constant STAKED_CHIP_ADDRESS = 0x0D2d2D20962F2468566F4D1a4DdeB482915C4D4A;
    bytes32 internal constant STAKED_CHIP_SALT = 0x783b08aa21de056717173f72e04be0e91328a07b0061a79c75082f7101364696;
    address internal constant TIMELOCK_CONTROLLER_ADDRESS = 0x0EEC1EE03ADD82342a6ac68A9C5cf62CB2398221;
    bytes32 internal constant TIMELOCK_CONTROLLER_SALT =
        0x783b08aa21de056717173f72e04be0e91328a07b00cc748a57ae630102861ec8;
    address internal constant CHIP_GOVERNOR_ADDRESS = 0x0DDC1DD03C58E425f96567679b52F349dB847b26;
    bytes32 internal constant CHIP_GOVERNOR_SALT = 0x783b08aa21de056717173f72e04be0e91328a07b004565af50be48a701c08d5a;

    uint256 private constant TOKEN_SUPPLY = 10e9 ether;
    uint256 private constant TIMELOCK_MIN_DELAY = 3 days;
    string private constant GOVERNOR_NAME = "Chip Governor";
    uint256 private constant GOVERNOR_QUORUM_FRACTION = 5;
    uint48 private constant GOVERNOR_VOTING_DELAY = 1 days;
    uint32 private constant GOVERNOR_VOTING_PERIOD = 1 weeks;
    uint48 private constant GOVERNOR_VOTE_EXTENSION = 3 days;
    uint256 private constant GOVERNOR_PROPOSAL_THRESHOLD = 100e6 ether;

    function run(
        address deployer,
        address treasury,
        address admin
    ) public broadcast useDeployment {
        if (_deployment.chip != address(0)) revert AlreadyDeployed();
        if (_deployment.stakedChip != address(0)) revert AlreadyDeployed();
        if (_deployment.governor != address(0)) revert AlreadyDeployed();
        if (_deployment.timelock != address(0)) revert AlreadyDeployed();

        console.log("Deploying from account: %s\n", msg.sender);

        /**********************************************************************/
        /* Implementation Contracts */
        /**********************************************************************/

        console.log("Deploying Chip implementation...");
        Chip chipImpl = new Chip(USDAI_ADDRESS);

        console.log("Deploying StakedChip implementation...");
        StakedChip stakedChipImpl = new StakedChip(USDAI_ADDRESS, CHIP_ADDRESS);

        /**********************************************************************/
        /* Deployer Calldata */
        /**********************************************************************/

        console.log("Prepare Chip proxy calldata...");
        if (CREATEX.computeCreate3Address(keccak256(abi.encode(deployer, CHIP_SALT))) != CHIP_ADDRESS) {
            revert InvalidParameter();
        }
        bytes memory chipProxyCreate3Calldata = abi.encodeWithSelector(
            ICreateX.deployCreate3.selector,
            CHIP_SALT,
            abi.encodePacked(
                type(TransparentUpgradeableProxy).creationCode,
                abi.encode(
                    address(chipImpl),
                    deployer,
                    abi.encodeWithSelector(Chip.initialize.selector, TOKEN_SUPPLY, treasury, admin)
                )
            )
        );

        console.log("Prepare StakedChip proxy calldata...");
        if (CREATEX.computeCreate3Address(keccak256(abi.encode(deployer, STAKED_CHIP_SALT))) != STAKED_CHIP_ADDRESS) {
            revert InvalidParameter();
        }
        bytes memory stakedChipProxyCreate3Calldata = abi.encodeWithSelector(
            ICreateX.deployCreate3.selector,
            STAKED_CHIP_SALT,
            abi.encodePacked(
                type(TransparentUpgradeableProxy).creationCode,
                abi.encode(
                    address(stakedChipImpl), deployer, abi.encodeWithSelector(StakedChip.initialize.selector, admin)
                )
            )
        );

        console.log("Prepare TimelockController calldata...");
        if (
            CREATEX.computeCreate3Address(keccak256(abi.encode(deployer, TIMELOCK_CONTROLLER_SALT)))
                != TIMELOCK_CONTROLLER_ADDRESS
        ) {
            revert InvalidParameter();
        }
        address[] memory accounts = new address[](2);
        accounts[0] = CHIP_GOVERNOR_ADDRESS;
        accounts[1] = admin;
        bytes memory timelockControllerCreate3Calldata = abi.encodeWithSelector(
            ICreateX.deployCreate3.selector,
            TIMELOCK_CONTROLLER_SALT,
            abi.encodePacked(
                type(TimelockController).creationCode, abi.encode(TIMELOCK_MIN_DELAY, accounts, accounts, address(0x0))
            )
        );

        console.log("Prepare ChipGovernor calldata...");
        if (CREATEX.computeCreate3Address(keccak256(abi.encode(deployer, CHIP_GOVERNOR_SALT))) != CHIP_GOVERNOR_ADDRESS)
        {
            revert InvalidParameter();
        }
        bytes memory chipGovernorCreate3Calldata = abi.encodeWithSelector(
            ICreateX.deployCreate3.selector,
            CHIP_GOVERNOR_SALT,
            abi.encodePacked(
                type(ChipGovernor).creationCode,
                abi.encode(
                    GOVERNOR_NAME,
                    IVotes(CHIP_ADDRESS),
                    TIMELOCK_CONTROLLER_ADDRESS,
                    GOVERNOR_QUORUM_FRACTION,
                    GOVERNOR_VOTING_DELAY,
                    GOVERNOR_VOTING_PERIOD,
                    GOVERNOR_PROPOSAL_THRESHOLD,
                    GOVERNOR_VOTE_EXTENSION
                )
            )
        );

        console.log("");
        console.log("from deployer multisig");
        console.log("");

        console.log("target", address(CREATEX));
        console.log("Chip proxy calldata");
        console.logBytes(chipProxyCreate3Calldata);
        console.log("Staked Chip proxy calldata");
        console.logBytes(stakedChipProxyCreate3Calldata);
        console.log("TimelockController calldata");
        console.logBytes(timelockControllerCreate3Calldata);
        console.log("ChipGovernor calldata");
        console.logBytes(chipGovernorCreate3Calldata);
        console.log("");

        /**********************************************************************/
        /* Admin Calldata */
        /**********************************************************************/

        console.log("from admin multisig");
        console.log("");

        console.log("Grant Chip DEFAULT_ADMIN_ROLE to TimelockController...");
        console.log("target", CHIP_ADDRESS);
        console.log("calldata");
        console.logBytes(abi.encodeWithSelector(IAccessControl.grantRole.selector, 0x0, TIMELOCK_CONTROLLER_ADDRESS));

        console.log("Grant Chip REVOKE_DELEGATE_ADMIN_ROLE to admin...");
        console.log("target", CHIP_ADDRESS);
        console.log("calldata");
        console.logBytes(
            abi.encodeWithSelector(IAccessControl.grantRole.selector, keccak256("REVOKE_DELEGATE_ADMIN_ROLE"), admin)
        );

        console.log("Grant StakedChip DEFAULT_ADMIN_ROLE to TimelockController...");
        console.log("target", STAKED_CHIP_ADDRESS);
        console.log("calldata");
        console.logBytes(abi.encodeWithSelector(IAccessControl.grantRole.selector, 0x0, TIMELOCK_CONTROLLER_ADDRESS));

        console.log("Granting StakedChip PAUSE_ADMIN_ROLE to admin...");
        console.log("target", STAKED_CHIP_ADDRESS);
        console.log("calldata");
        console.logBytes(
            abi.encodeWithSelector(IAccessControl.grantRole.selector, keccak256("PAUSE_ADMIN_ROLE"), admin)
        );

        console.log("");
        console.log("Chip impl:             %s", address(chipImpl));
        console.log("Chip:                  %s", CHIP_ADDRESS);
        console.log("StakedChip impl:       %s", address(stakedChipImpl));
        console.log("StakedChip:            %s", STAKED_CHIP_ADDRESS);
        console.log("TimelockController:    %s", TIMELOCK_CONTROLLER_ADDRESS);
        console.log("ChipGovernor:          %s", CHIP_GOVERNOR_ADDRESS);
        console.log("");

        /* Log deployment */
        _deployment.chip = CHIP_ADDRESS;
        _deployment.stakedChip = STAKED_CHIP_ADDRESS;
        _deployment.timelock = TIMELOCK_CONTROLLER_ADDRESS;
        _deployment.governor = CHIP_GOVERNOR_ADDRESS;
    }
}
