// SPDX-License-Identifier: AGPL-3.0

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {
    IERC20
} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface IMasterChef {

    struct UserInfo {
        uint256 amount;     // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
    }

    struct PoolInfo {
        IERC20 lpToken;           // Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool. SYNAPSE to distribute per block.
        uint256 lastRewardBlock;  // Last block number that SYNAPSE distribution occurs.
        uint256 accSynapsePerShare; // Accumulated SYNAPSE per share, times 1e12. See below.
    }

    function poolInfo(uint256 pid) external view returns (IMasterChef.PoolInfo memory);
    function totalAllocPoint() external view returns (uint256);
    function deposit(uint256 _pid, uint256 _amount) external;
    function userInfo(uint256 _pid, address user) external view returns (uint256, uint256);
    function harvest(uint256 pid, address to) external;
    function withdraw(uint256 pid, uint256 amount, address to) external;
    function withdrawAndHarvest(uint256 pid, uint256 amount, address to) external;
    function emergencyWithdraw(uint256 pid, address to) external;
}