// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.0;

/* 
The following contract is an autocompounding strategy, used with an implementation of the EIP4626 tokenized vault standard. 
It is a proof-of-concept, and it is set up to be used in the following way:
 Deposit LP tokens (asset) into contract, then contract deposits into chosen staking contract. The specified staking contract 
 produces an ERC20 reward that is collected by the vault and divided in half to be swapped for the two tokens that back the LP token.
 From there, the two tokens are used to produce more LP tokens and the process starts over again. 
 The contract is currently set up to be used with the
 AuroraSwap farm for USDC-USDT
 NOTE: This contract has not been tested in production and there may be errors. Use at your own risk.
*/

import "./VaultStandard.sol";
import "./SafeMath.sol";
import "./IPair.sol";
import "./IRouter.sol";
import "./IMasterChefJoe.sol";

contract AutoCompound4626 is ERC4626 {
    using SafeMath for uint;

    //keeps track of the total amount of LP tokens deposited in stakingContract
    uint public totalDeposits;

    //PID is pool ID for pair in auroraChef.
    uint public PID = 2;
    IUniswapV2Router01 public router;
    //asset for contract is the LP token for the chosen LP farm: USDC-USDT
    IUniswapV2Pair public lpTkn;
    IERC20 public token0;
    IERC20 public token1;
    IERC20 public reward;
    IMasterChefJoe public stakingContract;

    //asset is LP token USDC-USDT on AuroraSwap
    address public constant _lpTkn = 0xEc538fAfaFcBB625C394c35b11252cef732368cd;
    //token0 is USDC on Aurora
    address public constant _token0 = 0xB12BFcA5A55806AaF64E99521918A4bf0fC40802;
    //token1 is USDT on Aurora
    address public constant _token1 = 0x4988a896b1227218e4A686fdE5EabdcAbd91571f;
    //reward is BRL
    address public constant _reward = 0x12c87331f086c3C926248f964f8702C0842Fd77F;
    //router is AuroraRouter
    address public constant _router = 0xA1B1742e9c32C7cAa9726d8204bD5715e3419861;
    //staking in AuroraChef
    address public constant _stakingContract = 0x35CC71888DBb9FfB777337324a4A60fdBAA19DDE;

    //Owner of Strategy Vault
    address public owner;

    event Deposit(address account, uint amount);
    event Withdraw(address account, uint amount);
    event Recovered(address token, uint amount);
    event Reinvest(uint newTotalDeposits);

    constructor() ERC4626(ERC20(_lpTkn), "USDCUSDT", "LP") public {
        owner = msg.sender;
        lpTkn = IUniswapV2Pair(_lpTkn);
        token0 = IERC20(_token0);
        token1 = IERC20(_token1);
        reward = IERC20(_reward);
        stakingContract = IMasterChefJoe(_stakingContract);
        router = IUniswapV2Router01(_router);
        // setting up approvals so router and staking contract can move tokens from within vault contract
        token0.approve(_router, type(uint).max);
        token1.approve(_router, type(uint).max);
        reward.approve(_router, type(uint).max);
        lpTkn.approve(_stakingContract, type(uint).max);
        
    }

    modifier onlyOwner() {
        require(msg.sender == owner);
        _;
    }

    function totalAssets() public override view returns (uint256) {
        uint stakingAssetBalance = stakingContract.userInfo(PID, address(this)).amount;
        uint contractAssetBalance = asset.balanceOf(address(this));
    return stakingAssetBalance.add(contractAssetBalance);
    }

    function pendingRewardAmt() public view returns (uint) {
        //references the staking Contract and finds the pending rewards for the caller. Returns amount.
        //function name in stakingContract will depend on contract code.
        (uint pendingReward,,,)= stakingContract.pendingTokens(PID, address(this));
        uint contractBalance = reward.balanceOf(address(this));
        return pendingReward.add(contractBalance);
    }

    
    function _convertRewardToLp(uint rewardAmt) internal returns (uint) {
        uint swapAmt = rewardAmt.div(2);
        //make path (named path0) from Joe to WETH.e
        address[] memory path0 = new address[](2);  
        path0[0] = _reward;
        path0[1] = _token0;
        uint[] memory expectedTkn0Amts = router.getAmountsOut(swapAmt, path0);
        uint expectedTkn0Amt = expectedTkn0Amts[expectedTkn0Amts.length-1];
        uint amountTkn0OutMin = expectedTkn0Amt.mul(95).div(100);
        //swap function: swap 1/2 of Joe for WETH.e
        //approval given to router for reward in constructor
        router.swapExactTokensForTokens(swapAmt, amountTkn0OutMin, path0, address(this), block.timestamp);

        //make path (named path1) from Joe to USDC
        address[] memory path1 = new address[](2);  
        path1[0] = _reward;
        path1[1] = _token1;
        uint[] memory expectedTkn1Amts = router.getAmountsOut(swapAmt, path1);
        uint expectedTkn1Amt = expectedTkn1Amts[expectedTkn1Amts.length-1];
        uint amountTkn1OutMin = expectedTkn1Amt.mul(95).div(100);
        //swap function: swap 1/2 of Joe for USDC
        //approval given to router for reward in constructor
        router.swapExactTokensForTokens(swapAmt, amountTkn1OutMin, path1, address(this), block.timestamp);


        //approval given to router for token0 and token1 in constructor
        (,,uint liquidity) = router.addLiquidity(
        _token0, _token1,
        amountTkn0OutMin, amountTkn1OutMin,
        0, 0,
        address(this),
        block.timestamp
        );

        return liquidity;

    }

    function _stakeLp(uint amount) internal {
        require(amount > 0, "amount too low");
        //vault contract gives approval to stakingContract for deposit in constructor
        stakingContract.deposit(PID, amount);
    }

    function reinvest() external onlyOwner {
        uint unclaimedRewards = pendingRewardAmt();
        //can eventually put a require in that makes sure unclaimed rewards are certain amount before reinvested
        uint lpTokenAmt = _convertRewardToLp(unclaimedRewards);
        _stakeLp(lpTokenAmt);
        totalDeposits = totalDeposits.add(lpTokenAmt);
        emit Reinvest(totalDeposits);
    }

    function emergencyWithdraw() external onlyOwner {
        stakingContract.emergencyWithdraw();
        totalDeposits = 0;
    }

    function recoverERC20(address tokenAddress, uint tokenAmount) external  {
        require(tokenAmount > 0, "amount too low");
        IERC20(tokenAddress).transfer(msg.sender, tokenAmount);
        emit Recovered(tokenAddress, tokenAmount);
    }

    
}