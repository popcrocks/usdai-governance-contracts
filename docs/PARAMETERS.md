# Governance Parameters

```
CHIP Decimals           18
CHIP Token Supply       10 billion (10e9)
CHIP Name               Chip
CHIP Symbol             CHIP

Staked CHIP Decimals    18
Staked CHIP Name        Staked Chip
Staked CHIP Symbol      sCHIP

Timelock Min Delay      3 days (enforced delay before executing an operation)

Governor Name                   Chip Governor
Governor Quorum Fraction        5%          (fraction of token supply needed for successful proposal)
Governor Proposal Threshold     100 million (1% of supply; absolute amount of token needed to make a proposal)
Governor Voting Delay           1 day       (delay between proposal and vote start, allows time to acquire token or delegate)
Governor Voting Period          1 week      (voting duration)
Governor Vote Extension         3 days      (vote extension for late quorum)
```

Proposal votes can be For, Abstain, or Against. Quorum Fraction counts For and Abstain votes, but not Against votes.

As of Chip v1.2, CHIP transfers are unrestricted and subject only to the USDai blacklist; there is no transfer-lock role.

# Initial Ownership

```
Chip Proxy
    Owner -> USDai Deployer Multisig

StakedChip Proxy
    Owner -> USDai Deployer Multisig

TimelockController
    PROPOSER_ROLE   -> ChipGovernor, USDai Admin Multisig
    EXECUTOR_ROLE   -> ChipGovernor, USDai Admin Multisig
    CANCELLER_ROLE  -> ChipGovernor, USDai Admin Multisig

Chip
    Initial Supply              -> USDai Treasury Multisig
    DEFAULT_ADMIN_ROLE          -> USDai Admin Multisig, Timelock Controller
    REVOKE_DELEGATE_ADMIN_ROLE  -> USDai Admin Multisig

StakedChip
    DEFAULT_ADMIN_ROLE  -> USDai Admin Multisig, Timelock Controller
    PAUSE_ADMIN_ROLE    -> USDai Admin Multisig

ChipGovernor
```

# Future Ownership under Governance

```
Chip Proxy
    Owner -> Timelock Controller

StakedChip Proxy
    Owner -> Timelock Controller

USDai Proxy
    Owner -> Timelock Controller

StakedUSdai Proxy
    Owner -> Timelock Controller

LoanRouter Proxy
    Owner -> Timelock Controller

DepositTimelock Proxy
    Owner -> Timelock Controller

Chip
    DEFAULT_ADMIN_ROLE          -> Timelock Controller
    REVOKE_DELEGATE_ADMIN_ROLE  -> USDai Admin Multisig

StakedChip
    DEFAULT_ADMIN_ROLE  -> Timelock Controller
    PAUSE_ADMIN_ROLE    -> USDai Admin Multisig

USDai
    DEFAULT_ADMIN_ROLE      -> Timelock Controller
    BLACKLIST_ADMIN_ROLE    -> USDai Admin Multisig
    BRIDGE_ADMIN_ROLE       -> OAdapter

Staked USDai
    DEFAULT_ADMIN_ROLE  -> Timelock Controller
    PAUSE_ADMIN_ROLE    -> USDai Admin Multisig
    STRATEGY_ADMIN_ROLE -> USDai Strategy Admin Multisig
    BRIDGE_ADMIN_ROLE   -> OAdapter
```
