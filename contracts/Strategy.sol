// SPDX-License-Identifier: AGPL-3.0

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import {
    BaseStrategy,
    StrategyParams
} from "@yearnvaults/contracts/BaseStrategy.sol";
import {
    SafeERC20,
    SafeMath,
    IERC20,
    Address
} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import {
    ISwap
} from "../interfaces/synapse/ISwap.sol";
import {
    IMasterChef
} from "../interfaces/synapse/IMasterChef.sol";
import {
    IUniswapV2Router02
} from "../interfaces/solidly/IUniswapV2Router02.sol";

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    struct route {
        address from;
        address to;
        bool stable;
    }


    // tokens
    IERC20 internal constant USDT = IERC20(0x049d68029688eAbF473097a2fC38ef61633A3C7A);
    IERC20 internal constant nUSD = IERC20(0xED2a7edd7413021d440b09D654f3b87712abAB66);
    IERC20 internal constant SYN = IERC20(0xE55e19Fb4F2D85af758950957714292DAC1e25B2);

    // lp tokens
    IERC20 internal constant syn3PoolLP = IERC20(0x2DC777ff99058a12844A33D9B1AE6c8AB4701F66);

    // staking contracts
    IMasterChef internal constant synStakingMC = IMasterChef(0xaeD5b25BE1c3163c907a471082640450F928DDFE);

    // pools
    IUniswapV2Router02 internal constant solidlyRouter = IUniswapV2Router02(0xa38cd27185a464914D3046f0AB9d43356B34829D); // Solidly router
    ISwap internal constant syn3PoolSwap = ISwap(0x85662fd123280827e11C59973Ac9fcBE838dC3B4); // Synapse Fantom 3 Pool

    uint256 internal constant pid = 3; // Minichef Pool ID
    uint8 internal constant syn3PoolUSDCTokenIndex = 1; // Index of USDT in Synapse Fantom 3 Pool


    constructor(address _vault) public BaseStrategy(_vault) {
        // You can set these parameters on deployment to whatever you want
        // maxReportDelay = 6300;
        // profitFactor = 100;
        // debtThreshold = 0;
    }

    // ******** OVERRIDE THESE METHODS FROM BASE CONTRACT ************

    function name() external view override returns (string memory) {
        // Add your own name here, suggestion e.g. "StrategyCreamYFI"
        return "StrategySynapseUSDC";
    }

    function estimatedTotalAssets() public view override returns (uint256) {

        // Incase we aren't able to withdraw our deposit all in `want`, we might have other types of stable coin tokens
        return nusdBalance().add(usdtBalance()).add(wantBalance()).add(synToWantBalance());
    }

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        // Calim all our SYN tokens and withdraw all of our `nUSD-LP` tokens
        synStakingMC.harvest(pid, address(this));

        // Trade all of our SYN tokens for `want` tokens
        _sellSynToWant(claimedSynBalance());

        //grab the estimate total debt from the vault
        uint256 _vaultDebt = vault.strategies(address(this)).totalDebt;
        uint256 _totalAssets = estimatedTotalAssets();

        if (_totalAssets >= _vaultDebt) {
            // Implicitly, _profit & _loss are 0 before we change them.
            _profit = _totalAssets.sub(_vaultDebt);
        } else {
            _loss = _vaultDebt.sub(_totalAssets);
        }


        (uint256 _amountFreed, uint256 _liquidationLoss) =
            liquidatePosition(_debtOutstanding.add(_profit));

        _loss = _loss.add(_liquidationLoss);

        _debtPayment = Math.min(_debtOutstanding, _amountFreed);

        if (_loss > _profit) {
            _loss = _loss.sub(_profit);
            _profit = 0;
        } else {
            _profit = _profit.sub(_loss);
            _loss = 0;
        }

    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        uint256 _looseWant = wantBalance();

        if (_looseWant > _debtOutstanding) {
            uint256 _amountToDeposit = _looseWant.sub(_debtOutstanding);

            _addliquidity(_amountToDeposit);
        }
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        // TODO: Do stuff here to free up to `_amountNeeded` from all positions back into `want`
        // NOTE: Maintain invariant `want.balanceOf(this) >= _liquidatedAmount`
        // NOTE: Maintain invariant `_liquidatedAmount + _loss <= _amountNeeded`

        uint256 _liquidWant = wantBalance();


        _amountNeeded = Math.min(_amountNeeded, estimatedTotalAssets()); // Otherwise we can end up declaring a liquidation loss when _amountNeeded is more than we own


        if (_liquidWant < _amountNeeded) {
            _unstakeLPTokens(stakedLPBalance());

            //withdraw from pool
            _withdrawLiquidity(unstakedLPBalance());

            //check current want balance
            uint256 _postWithdrawWant = wantBalance();

            //redeposit to pool
            if (_postWithdrawWant > _amountNeeded) {
                _addliquidity(_postWithdrawWant.sub(_amountNeeded));

                //Stake the LP tokens
                synStakingMC.deposit(
                    pid,
                    unstakedLPBalance(),
                    address(this)
                );
            }

            _liquidWant = balanceOfWant();
        }

        if (_amountNeeded > _liquidWant) {
            _liquidatedAmount = _liquidWant;
            _loss = _amountNeeded.sub(_liquidWant);
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    function liquidateAllPositions() internal override returns (uint256) {
        synStakingMC.emergencyWithdraw(pid, address(this));

        uint256 _lpTokenBalance = unstakedLPBalance();
        if (_lpTokenBalance > 0) {
            // Try to withdraw everything in `want`
            _withdrawLiquidity(_lpTokenBalance);

            _lpTokenBalance = unstakedLPBalance();

            // If we still have LP tokens after trying to withdraw everything in `want`,
            // withdraw in anything else that we can get
            if (_lpTokenBalance > 0) {
                uint256[] memory minAmounts = new uint256[](3);
                //todo: should we try to not withdraw any amount in usdc?
                minAmounts[0] = 0; // nUSD
                minAmounts[1] = 0; // USDC
                minAmounts[2] = 0; // fUSDT
                syn3PoolSwap.removeLiquidity(_lpTokenBalance, minAmounts, block.timestamp);

            }

        }

        return wantBalance();
    }

    // NOTE: Can override `tendTrigger` and `harvestTrigger` if necessary

    function prepareMigration(address _newStrategy) internal override {
        nUSD.transfer(_newStrategy, nusdBalance());
        USDT.transfer(_newStrategy, usdtBalance());

        // Calim all our SYN tokens and transfer
        synStakingMC.harvest(pid, address(this));
        SYN.transfer(_newStrategy, claimedSynBalance());

        _unstakeLPTokens(stakedLPBalance());
        syn3PoolLP.transfer(_newStrategy, unstakedLPBalance());
        // NOTE: `migrate` will automatically forward all `want` in this strategy to the new one
    }

    // Override this to add all tokens/tokenized positions this contract manages
    // on a *persistent* basis (e.g. not just for swapping back to want ephemerally)
    // NOTE: Do *not* include `want`, already included in `sweep` below
    //
    // Example:
    //
    //    function protectedTokens() internal override view returns (address[] memory) {
    //      address[] memory protected = new address[](3);
    //      protected[0] = tokenA;
    //      protected[1] = tokenB;
    //      protected[2] = tokenC;
    //      return protected;
    //    }
    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {}

    /**
     * @notice
     *  Provide an accurate conversion from `_amtInWei` (denominated in wei)
     *  to `want` (using the native decimal characteristics of `want`).
     * @dev
     *  Care must be taken when working with decimals to assure that the conversion
     *  is compatible. As an example:
     *
     *      given 1e17 wei (0.1 ETH) as input, and want is USDC (6 decimals),
     *      with USDC/ETH = 1800, this should give back 1800000000 (180 USDC)
     *
     * @param _amtInWei The amount (in wei/1e-18 ETH) to convert to `want`
     * @return The amount in `want` of `_amtInEth` converted to `want`
     **/
    function ethToWant(uint256 _amtInWei)
        public
        view
        virtual
        override
        returns (uint256)
    {
    }

    /**
     * @notice
     *  Takes the amount in `SYN` and sells it for `want` on solidly
     * @dev
     *  Total amount to sell in wei
     * @return
     **/
    function _sellSynToWant(uint256 _amount) internal {
        route[] memory routes = new route[](1);
        routes[0].from = address(SYN);
        routes[0].to = address(want);
        routes[0].stable = false;

        solidlyRouter.swapExactTokensForTokens(
            _amount,
            0,
            routes,
            address(this),
            block.timestamp
        );
    }

    // ----------------- SUPPORT FUNCTIONS ----------


    function _addliquidity(uint256 _amount) internal {
        uint256[] memory liquidityToAdd = new uint256[](3);
        liquidityToAdd[0] = 0; // nUSD
        liquidityToAdd[1] = _amount; // USDC
        liquidityToAdd[2] = 0; // fUSDT

        syn3PoolSwap.addLiquidity(
            liquidityToAdd,
            0, //todo: should be specify a minimum amount here?
            block.timestamp
        );
    }

    function _unstakeLPTokens(uint256 _amount) internal {
        lpStaker.withdraw(
            pid,
            _amount
        );
    }

    function _withdrawLiquidity(uint256 _lpAmount) internal {
        syn3PoolSwap.removeLiquidityOneToken(
            _lpAmount,
            syn3PoolUSDCTokenIndex,
            0, // min amount
            block.timestamp
        );
    }

    /**
     * @notice
     *  Takes the total balance of SYN, both claimed and unclaimed and converts and
     *  gets a quote for an equivlant amount of `want` using the Solidly's SYN<>USDC Pool
     * @dev
     *  Total amount includes claimed and unclaimed SYN tokens
     * @return The amount in `want` of `SYN` converted to `want`
     **/
    function synToWantBalance()
        public
        view
        returns (uint256) 
    {
        route[] memory routes = new route[](1);
        routes[0].from = address(SYN);
        routes[0].to = address(want);
        routes[0].stable = false;

        return solidlyRouter.getAmountsOut(totalSYNBalance(), path)[1];
    }

    /**
     * @notice
     *  Gets the total amount of staked LP token for the stable swap 3 pool
     * @return The amount of `nUSD-LP` that have been staked
     **/
    function stakedLPBalance()
        public
        view
        returns (uint256)
    {
        (uint256 stakedInMasterchef, ) =
            synStakingMC.userInfo(pid, address(this));
        return stakedInMasterchef;
    }

    /**
     * @notice
     *  The total amount of SYN that hasn't been claimed yet
     * @return The amount in `SYN` that hasn't been claimed yet
     **/
    function unclaimedSynBalance()
        public
        view
        returns (uint256)
    {
        (uint256 stakedInMasterchef, uint256 unclaimedRewards) =
            synStakingMC.userInfo(pid, address(this));
        return unclaimedRewards;
    }

    /**
     * @notice
     *  The total amount of SYN that has been claimed
     * @return The amount in `SYN` that has been claimed
     **/
    function claimedSynBalance()
        public
        view
        returns (uint256)
    {
        return SYN.balanceOf(address(this));
    }

    /**
     * @notice
     *  Total balance of SYN, both claimed and unclaimed
     * @dev
     *  Total amount includes claimed and unclaimed SYN tokens
     * @return The amount in `SYN` of staked and unstaked `SYN` tokens
     **/
    function totalSynBalance()
        public
        view
        returns (uint256) 
    {
        return claimedSynBalance().add(unclaimedSynBalance());
    }

    /**
     * @notice
     *  Total balance of LP tokens that haven't been staked yet
     * @return The amount in `nUSD-LP` that haven't been staked yet
     **/
    function unstakedLPBalance()
        public
        view
        returns (uint256) 
    {
        return syn3PoolLP.balanceOf(address(this));
    }

    function wantBalance() 
        public
        view
        returns (uint256)
    {
        return want.balanceOf(address(this));
    }


    function usdtBalance() 
        public
        view
        returns (uint256)
    {
        return USDT.balanceOf(address(this));
    }

    function nusdBalance() 
        public
        view
        returns (uint256)
    {
        return nUSD.balanceOf(address(this));
    }

}
