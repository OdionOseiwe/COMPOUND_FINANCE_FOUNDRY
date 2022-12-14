// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;
import "openzeppelin-contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/security/ReentrancyGuard.sol";
import "openzeppelin-contracts/access/Ownable.sol";
import "../interface/AggregatorV3Interface.sol";

/// @title A title that should describe the contract/interface
/// @author The name of the author
/// @notice Explain to an end user what this does
/// @dev Explain to a developer any extra details

contract Controller is ReentrancyGuard, Ownable{
    mapping(address => address) public m_PriceFeed;

    mapping(address => address) public s_tokenToPriceFeed;

    mapping(address => bool) markets;

    address[] public s_allowedTokens;

    // Account -> Token -> Amount
    mapping(address => mapping(address => uint256)) public m_accountToTokenDeposits;
    // Account -> Token -> Amount
    mapping(address => mapping(address => uint256)) public m_accountToTokenBorrows;



    // 5% Liquidation Reward
    uint256 public constant LIQUIDATION_REWARD = 500;

    // At 70% Loan to Value Ratio, the loan can be liquidated
    uint256 public constant LIQUIDATION_THRESHOLD = 7000;

    uint256 public constant COLLATERALFACTORMIN = 1e18;

    // 1% fee for borrowing
    uint256 public constant FEES = 100;

    // 5% AYP
    uint256 public constant  AYP = 500;

    ///////////////////////////////////////////////////////EVENTS//////////////////////////////////////////////////
    event Deposit(address depositor, uint amount, address token);
    event Borrow(address debtor, address tokenAddress, uint256 amount);
    event Repay(address payer, uint256 amount);
    event Withdraw(address indexed account, address indexed token, uint256 indexed amount);
    event Repay(address indexed account, address indexed token, uint256 indexed amount);
    event Liquidate(
        address indexed account,
        address indexed repayToken,
        address indexed rewardToken,
        uint256 halfDebtInEth,
        address liquidator
    );
    error TransferFailed();

    /////////////////////////////////////////////////////////MODIFIER/////////////////////////////////////////////
    
    modifier zeroAddress(address token){
        require(token != address(0), "zero address");
        _;
    }

    modifier zeroAmount(uint256 amount){
        require(amount != 0, "zero amount");
        _;
    }

    function desposit(address token, uint256 amount) external zeroAddress(token) zeroAmount(amount) nonReentrant{
        if(markets[token]){
            m_accountToTokenDeposits[msg.sender][token] += amount;
            emit Deposit(msg.sender,amount,token);
            bool sent = IERC20(token).transferFrom(msg.sender, address(this), amount);
            require(sent, "failed to sent into contract");
        }
    }

    function borrow(address token, uint256 amount)
        external
        nonReentrant
       zeroAddress(token) zeroAmount(amount)
    {
        if(markets[token]){
            require(IERC20(token).balanceOf(address(this)) >= amount, "Not enough tokens to borrow");
            m_accountToTokenBorrows[msg.sender][token] += amount;
            emit Borrow(msg.sender, token, amount);
            bool success = IERC20(token).transfer(msg.sender, amount);
            if (!success) revert TransferFailed();
            require(healthFactor(msg.sender) >= COLLATERALFACTORMIN, "Platform will go insolvent!");
        }
    }

   function withdraw(address token, uint256 amount) external nonReentrant zeroAddress(token) zeroAmount(amount) {
        require(m_accountToTokenDeposits[msg.sender][token] >= amount, "Not enough funds");
        emit Withdraw(msg.sender, token, amount);
        _pullFunds(msg.sender, token, amount);
        require(healthFactor(msg.sender) >= COLLATERALFACTORMIN, "Platform will go insolvent!");
    }

    function _pullFunds(
        address account,
        address token,
        uint256 amount
    ) private {
        require(m_accountToTokenDeposits[account][token] >= amount, "Not enough funds to withdraw");
        m_accountToTokenDeposits[account][token] -= amount;
        bool success = IERC20(token).transfer(msg.sender, amount);
        if (!success) revert TransferFailed();
    }

    function liquidate(
        address account,
        address repayToken,
        address rewardToken
    ) external nonReentrant {
        require(healthFactor(account) < COLLATERALFACTORMIN, "Account can't be liquidated!");
        uint256 halfDebt = m_accountToTokenBorrows[account][repayToken] / 2;
        uint256 halfDebtInUSD = getUSDValue(repayToken, halfDebt);
        require(halfDebtInUSD > 0, "Choose a different repayToken!");
        uint256 rewardAmountInUSD = (halfDebtInUSD * LIQUIDATION_REWARD) / 100;
        uint256 totalRewardAmountInRewardToken = getTokenValueFromUSD(
            rewardToken,
            rewardAmountInUSD + halfDebtInUSD
        );
        emit Liquidate(account, repayToken, rewardToken, halfDebtInUSD, msg.sender);
        _repay(account, repayToken, halfDebt);
        _pullFunds(account, rewardToken, totalRewardAmountInRewardToken);
    }

    function repay(address token, uint256 amount)
        external
        nonReentrant
        zeroAddress(token) zeroAmount(amount)
    {
        emit Repay(msg.sender, token, amount);
        _repay(msg.sender, token, amount);
    }

    function _repay(
        address account,
        address token,
        uint256 amount
    ) private {
        // require(m_accountToTokenBorrows[account][token] - amount >= 0, "Repayed too much!");
        // On 0.8+ of solidity, it auto reverts math that would drop below 0 for a uint256
        m_accountToTokenBorrows[account][token] -= amount;
        bool success = IERC20(token).transferFrom(msg.sender, address(this), amount);
        if (!success) revert TransferFailed();
    }

    function getAccountInformation(address user)
        public
        view
        returns (uint256 borrowedValueInUSD, uint256 collateralValueInUSD)
    {
        borrowedValueInUSD = getAccountBorrowedValue(user);
        collateralValueInUSD = getAccountCollateralValue(user);
    }

    function getAccountCollateralValue(address user) public view returns (uint256) {
        uint256 totalCollateralValueInUSD = 0;
        for (uint256 index = 0; index < s_allowedTokens.length; index++) {
            address token = s_allowedTokens[index];
            uint256 amount = m_accountToTokenDeposits[user][token];
            uint256 valueInUSD = getUSDValue(token, amount);
            totalCollateralValueInUSD += valueInUSD;
        }
        return totalCollateralValueInUSD;
    }

    function getAccountBorrowedValue(address user) public view returns (uint256) {
        uint256 totalBorrowsValueInUSD = 0;
        for (uint256 index = 0; index < s_allowedTokens.length; index++) {
            address token = s_allowedTokens[index];
            uint256 amount = m_accountToTokenBorrows[user][token];
            uint256 valueInUSD = getUSDValue(token, amount);
            totalBorrowsValueInUSD += valueInUSD;
        }
        return totalBorrowsValueInUSD;
    }

    function getUSDValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_tokenToPriceFeed[token]);
        (, int256 price, , , ) = priceFeed.latestRoundData();
        return (uint256(price) * amount) / 1e18;
    }

    function getTokenValueFromUSD(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_tokenToPriceFeed[token]);
        (, int256 price, , , ) = priceFeed.latestRoundData();
        return (amount * 1e18) / uint256(price);
    }

    function healthFactor(address account) public view returns (uint256) {
        (uint256 borrowedValueInUSD, uint256 collateralValueInUSD) = getAccountInformation(account);
        uint256 collateralAdjustedForThreshold = (collateralValueInUSD * LIQUIDATION_THRESHOLD) /
            100;
        if (borrowedValueInUSD == 0) return 100e8;
        return (collateralAdjustedForThreshold * 1e8) / borrowedValueInUSD;
    }

}

interface IRToken{
    function mint(address to, uint amount) external;
}
