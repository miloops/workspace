// SPDX-License-Identifier: MIT

pragma solidity >=0.7.0 <0.8.0;

import "./IStaking.sol";
import "./ITreasury.sol";
import "./IBeneficiaryVaults.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/cryptography/MerkleProof.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

/**
* @title Popcorn Rewards Manager
* @notice Manages distribution of POP rewards to Popcorn Treasury, DAO Staking, and Beneficiaries
*/
contract RewardsManager is Ownable, ReentrancyGuard {
  using SafeMath for uint256;
  using SafeERC20 for IERC20;

  uint256 public constant SWAP_TIMEOUT = 600;

  IERC20 public immutable POP;
  IStaking public staking;
  ITreasury public treasury;
  IBeneficiaryVaults public beneficiaryVaults;
  IUniswapV2Factory public immutable uniswapV2Factory;
  IUniswapV2Router02 public immutable uniswapV2Router;

  uint256[3] public rewardSplits;
  mapping(uint8 => uint256[2]) private rewardLimits;

  enum RewardTargets {Staking, Treasury, BeneficiaryVaults}

  event StakingDeposited(address to, uint256 amount);
  event TreasuryDeposited(address to, uint256 amount);
  event BeneficiaryVaultsDeposited(address to, uint256 amount);
  event RewardsDistributed(uint256 amount);
  event RewardSplitsUpdated(uint256[3] splits);
  event TokenSwapped(address token, uint256 amountIn, uint256 amountOut);
  event StakingChanged(IStaking from, IStaking to);
  event TreasuryChanged(ITreasury from, ITreasury to);
  event BeneficiaryVaultsChanged(
    IBeneficiaryVaults from,
    IBeneficiaryVaults to
  );

  constructor(
    IERC20 pop_,
    IStaking staking_,
    ITreasury treasury_,
    IBeneficiaryVaults beneficiaryVaults_,
    IUniswapV2Router02 uniswapV2Router_
  ) {
    POP = pop_;
    staking = staking_;
    treasury = treasury_;
    beneficiaryVaults = beneficiaryVaults_;
    uniswapV2Router = uniswapV2Router_;
    uniswapV2Factory = IUniswapV2Factory(uniswapV2Router_.factory());
    rewardLimits[uint8(RewardTargets.Staking)] = [20e18, 80e18];
    rewardLimits[uint8(RewardTargets.Treasury)] = [10e18, 80e18];
    rewardLimits[uint8(RewardTargets.BeneficiaryVaults)] = [20e18, 90e18];
    rewardSplits = [33e18, 33e18, 34e18];
  }

  /**
  * @notice Overrides existing Staking contract
  * @param staking_ Address of new Staking contract
  * @dev Must implement IStaking and cannot be same as existing
  */
  function setStaking(IStaking staking_) public onlyOwner {
    require(staking != staking_, "Same Staking");
    IStaking _previousStaking = staking;
    staking = staking_;
    emit StakingChanged(_previousStaking, staking);
  }

  /**
  * @notice Overrides existing Treasury contract
  * @param treasury_ Address of new Treasury contract
  * @dev Must implement ITreasury and cannot be same as existing
  */
  function setTreasury(ITreasury treasury_) public onlyOwner {
    require(treasury != treasury_, "Same Treasury");
    ITreasury _previousTreasury = treasury;
    treasury = treasury_;
    emit TreasuryChanged(_previousTreasury, treasury);
  }

  /**
  * @notice Overrides existing BeneficiaryVaults contract
  * @param beneficiaryVaults_ Address of new BeneficiaryVaults contract
  * @dev Must implement IeneficiaryVaults and cannot be same as existing
  */
  function setBeneficiaryVaults(IBeneficiaryVaults beneficiaryVaults_)
    public
    onlyOwner
  {
    require(beneficiaryVaults != beneficiaryVaults_, "Same BeneficiaryVaults");
    IBeneficiaryVaults _previousBeneficiaryVaults = beneficiaryVaults;
    beneficiaryVaults = beneficiaryVaults_;
    emit BeneficiaryVaultsChanged(
      _previousBeneficiaryVaults,
      beneficiaryVaults_
    );
  }

  /**
  * @notice Set new reward distribution allocations
  * @param splits_ Array of RewardTargets enumerated uint256 values within rewardLimits range
  * @dev Values must be within rewardsLimit range, specified in percent to 18 decimal place precision
  */
  function setRewardSplits(uint256[3] calldata splits_) public onlyOwner {
    uint256 _total = 0;
    for (uint8 i = 0; i < 3; i++) {
      require(
        splits_[i] >= rewardLimits[i][0] && splits_[i] <= rewardLimits[i][1],
        "Invalid split"
      );
      _total = _total.add(splits_[i]);
    }
    require(_total == 100e18, "Invalid split total");
    rewardSplits = splits_;
    emit RewardSplitsUpdated(splits_);
  }

  /**
  * @param path_ Uniswap path specification for source token to POP
  * @param minAmountOut_ Minimum desired amount (>0) of POP tokens to be received from swap
  * @dev Path specification requires at least source token as first in path and POP address as last
  * @dev Token swap internals implemented as described at https://uniswap.org/docs/v2/smart-contracts/router02/#swapexacttokensfortokens
  * @return swapped in/out amounts uint256 tuple
  */
  function swapTokenForRewards(address[] calldata path_, uint256 minAmountOut_)
    public
    nonReentrant
    returns (uint256[] memory)
  {
    require(path_.length >= 2, "Invalid swap path");
    require(minAmountOut_ > 0, "Invalid amount");
    require(
      path_[path_.length - 1] == address(POP),
      "POP must be last in path"
    );

    IERC20 _token = IERC20(path_[0]);
    uint256 _balance = _token.balanceOf(address(this));
    require(_balance > 0, "No swappable balance");

    _token.safeIncreaseAllowance(address(uniswapV2Router), _balance);
    uint256[] memory _amounts =
      uniswapV2Router.swapExactTokensForTokens(
        _balance,
        minAmountOut_,
        path_,
        address(this),
        block.timestamp.add(SWAP_TIMEOUT)
      );

    emit TokenSwapped(path_[0], _amounts[0], _amounts[1]);

    return _amounts;
  }

  /**
  * @notice Distribute POP rewards to dependent RewardTarget contracts
  * @dev Contract must have POP balance in order to distribute according to rewardSplits ratio
  */
  function distributeRewards() public nonReentrant {
    uint256 _availableReward = POP.balanceOf(address(this));
    require(_availableReward > 0, "No POP balance");

    //@todo check edge case precision overflow
    uint256 _stakingAmount =
      _availableReward.mul(rewardSplits[uint8(RewardTargets.Staking)]).div(
        100e18
      );
    uint256 _treasuryAmount =
      _availableReward.mul(rewardSplits[uint8(RewardTargets.Treasury)]).div(
        100e18
      );
    uint256 _beneficiaryVaultsAmount =
      _availableReward
        .mul(rewardSplits[uint8(RewardTargets.BeneficiaryVaults)])
        .div(100e18);

    _distributeToStaking(_stakingAmount);
    _distributeToTreasury(_treasuryAmount);
    _distributeToVaults(_beneficiaryVaultsAmount);

    emit RewardsDistributed(_availableReward);
  }

  function _distributeToStaking(uint256 amount_) internal {
    if (amount_ == 0) return;
    POP.transfer(address(staking), amount_);
    emit StakingDeposited(address(staking), amount_);
  }

  function _distributeToTreasury(uint256 amount_) internal {
    if (amount_ == 0) return;
    POP.transfer(address(treasury), amount_);
    emit TreasuryDeposited(address(treasury), amount_);
  }

  function _distributeToVaults(uint256 amount_) internal {
    if (amount_ == 0) return;
    POP.transfer(address(beneficiaryVaults), amount_);
    emit BeneficiaryVaultsDeposited(address(beneficiaryVaults), amount_);
  }
}
