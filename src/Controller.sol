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

    mapping(address => bool) markets;

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
            bool sent = IERC20(token).transferFrom(msg.sender, address(token), amount);
            require(sent, "failed to sent into contract");
        }
    }

    function borrow(uint256 amount, address tokenBorrow, address tokenCollateral) external  zeroAddress(tokenCollateral) zeroAddress(tokenBorrow) zeroAmount(amount) nonReentrant{
        if(markets[tokenBorrow]){
            require(IERC20(tokenBorrow).balanceOf(address(this)) >= amount, "Not enough tokens to borrow");
            m_accountToTokenBorrows[msg.sender][tokenBorrow] += amount;
            emit Borrow(msg.sender, tokenBorrow, amount);
            bool sent = IERC20(tokenBorrow).transfer(msg.sender, amount);
            require(sent, "failed to send");
            uint256 allow = allowed(msg.sender,tokenBorrow,tokenCollateral);
            require(allow > COLLATERALFACTORMIN, "contract will not be balanced");
        }
    }

    function allowed(address borrower, address tokenBorrow, address tokenCollateral) view private returns(uint256){
        uint256 collateral = m_accountToTokenDeposits[borrower][tokenBorrow];
        uint maximumBorrow  =  (collateral * LIQUIDATION_THRESHOLD) / 10000;
        uint UsersBorrows = m_accountToTokenBorrows[borrower][tokenCollateral];
        return (maximumBorrow * 1e18) / UsersBorrows;
    }

}

interface IRToken{
    function mint(address to, uint amount) external;
}
