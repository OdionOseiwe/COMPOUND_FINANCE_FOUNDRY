// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;
import "openzeppelin-contracts/token/ERC20/ERC20.sol";
import "openzeppelin-contracts/security/ReentrancyGuard.sol";

contract RToken is ERC20("RToken", "RT"), ReentrancyGuard {
    address  controller;


    function set(address _controller) external {
        controller = _controller;
    }
    
    function mint(address to, uint amount) public nonReentrant{
        require(msg.sender == address(controller), "cant call this function");
        _mint(to, amount);
    }

    function lend(uint256 amount) external nonReentrant{
        IController(controller).desposit(address(this), amount);
    }


}

interface IController{
     function desposit(address token, uint256 amount) external;
}
