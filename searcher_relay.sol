pragma solidity ^0.8.16;
//SPDX-License-Identifier: Unlicensed

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Metadata as IERC20} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

interface IWMATIC is IERC20 {
    function deposit() external payable;
    function withdraw(uint _amount) external;
}

contract FastLaneSearcherRelay is ReentrancyGuard, Ownable {

    address payable private constant wmatic = payable(0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270);
    address payable private SearcherContract;
    address payable private FastLaneAuction;
    address payable private backupPayee;
    bool private forwardMsgValue; 

    error WrongPermissions();
    error OriginEOANotOwner();
    error SearcherCallUnsuccessful(bytes retData);
    error SearcherInsufficientFunds(uint256 amountToSend, uint256 currentBalance);

    mapping(address => bool) internal approvedEOAs;
    mapping(address => uint256) internal wmaticAllowances;

    constructor() {
        forwardMsgValue = false;
        backupPayee = payable(owner());
        _updateAllowance(owner());
    }

    // the FastLane Auction contract will call this function
    function fastLaneCall(
            uint256 _bidAmount,
            address _sender,
            bytes calldata _searcherCallData // contains func selector and calldata for your MEV transaction
    ) external payable onlyRelayer nonReentrant returns (bool, bytes memory) {
        
        // make sure it's your own EOA that's calling your contract
        require(checkFastLaneEOA(_sender), "SenderEOANotApproved");

        // if you were planning to pay with the msg.value, you can remove {value: msg.value} from the 
        // call below (assuming your searcher contract doesn't need it)
        // the below layout is a catch-all that is optimized for flexibility over gas efficiency
        (bool prepaid, uint256 _msgValue) = prepaidCheck(_bidAmount);
        
        // execute the searcher's intended function
        (bool success, bytes memory returnedData) = SearcherContract.call{value: _msgValue}(_searcherCallData);
        
        // if the call didn't turn out the way you wanted, add a revert either here, inside your MEV function 
        // or at the PFL Relay balance check. For example:
        // require(success, "SearcherCallUnsuccessful");

        // balance check then Repay PFL at the end
        if (success) {
            prepaid ? safeTransferETH(FastLaneAuction, _bidAmount) : handlePayback(_bidAmount, _sender);
        }

        // return the return data (optional)
        return (success, returnedData);
    }

    function handlePayback(uint256 _bidAmount, address _sender) internal {
        // NOTE: this is a generalized approach to serve as an example. 
        // We recommend making this process specific to your own smart contract
        // to avoid the significant amount of unnecessary gas usage here.

        if (address(this).balance >= _bidAmount) {
            safeTransferETH(FastLaneAuction, _bidAmount);

        } else if (
                checkWrappedBalance(address(this), _bidAmount)
        ) {
            IWMATIC(wmatic).withdraw(_bidAmount);
            safeTransferETH(FastLaneAuction, _bidAmount);
        
        } else if (
                checkWrappedAllowance(_sender, _bidAmount) &&
                checkWrappedBalance(_sender, _bidAmount)
        ) {
            processWmaticPayment(_sender, _bidAmount);

        } else if (
                checkWrappedAllowance(SearcherContract, _bidAmount) &&
                checkWrappedBalance(SearcherContract, _bidAmount)
        ) {
            processWmaticPayment(SearcherContract, _bidAmount);

        } else if (
                checkWrappedAllowance(backupPayee, _bidAmount) &&
                checkWrappedBalance(backupPayee, _bidAmount)
        ) {
            processWmaticPayment(backupPayee, _bidAmount);

        } else {
            revert SearcherInsufficientFunds(_bidAmount, address(this).balance);
        }
    }

    // Below are functions / modifiers that are necessary for FastLane integration:
    // NOTE: you can use your own versions of these, or find alternative ways
    // to implement similar safety checks. Please be careful!
    function setPFLAuctionAddress(address _fastLaneAuction) external onlyOwner {
        FastLaneAuction = payable(_fastLaneAuction);
    }

    function setSearcherAddress(address _searcherAddress) external onlyOwner {
        SearcherContract = payable(_searcherAddress);
        _updateAllowance(_searcherAddress);
    }

    function approveFastLaneEOA(address eoaAddress) external onlyOwner {
        approvedEOAs[eoaAddress] = true;
        _updateAllowance(eoaAddress);
    }

    function removeFastLaneEOA(address eoaAddress) external onlyOwner {
        approvedEOAs[eoaAddress] = false;
    }

    function checkFastLaneEOA(address eoaAddress) internal view returns (bool) {
        return approvedEOAs[eoaAddress];
    }

    function isTrustedForwarder(address forwarder) internal view returns (bool) {
        return forwarder == FastLaneAuction;
    }

    function safeTransferETH(address to, uint256 amount) internal {
        bool success;

        assembly {
            // Transfer the ETH and store if it succeeded or not.
            success := call(gas(), to, amount, 0, 0, 0, 0)
        }

        require(success, "ETH_TRANSFER_FAILED");
    }

    fallback() external payable {}
    receive() external payable {}

    modifier onlyRelayer {
          if (!isTrustedForwarder(msg.sender)) revert("InvalidPermissions");
          _;
     }

    // Below are functions / modifiers that add broad usage to this relay example.
    // Ideally the searcher will significantly customize or replace them before deployment.
    function setBackupPayee(address payable payeeAddress) external onlyOwner {
        backupPayee = payeeAddress;
        _updateAllowance(payeeAddress);
    }

    function setForwardMsgValue(bool _state) external onlyOwner {
        forwardMsgValue = _state;
    }

    function updateAllowance(address _address) external {
        _updateAllowance(_address);
    }

    function _updateAllowance(address _address) internal {
        wmaticAllowances[_address] = IWMATIC(wmatic).allowance(_address, address(this));
    }

    function processWmaticPayment(address _source, uint256 _amount) private {
        IWMATIC(wmatic).transferFrom(_source, address(this), _amount);
        IWMATIC(wmatic).withdraw(_amount);
        safeTransferETH(FastLaneAuction, _amount);
    }

    function prepaidCheck(uint256 _bidAmount) internal view returns (bool, uint256) {
        if (msg.value != 0) {
            if (forwardMsgValue) {
                return (false, msg.value);
            }
            return (msg.value > _bidAmount, 0);
        }
        return (false, 0);
    }

    function checkWrappedAllowance(address _address, uint256 _amount) internal view returns(bool) {
        return wmaticAllowances[_address] >= _amount;
    }

    function checkWrappedBalance(address _address, uint256 _amount) internal view returns(bool) {
        return IWMATIC(wmatic).balanceOf(_address) >= _amount;
    }

    function wrapMatic(uint256 amount) external payable onlyOwner {
        require(address(this).balance >= amount, "insufficient matic");
        IWMATIC(wmatic).deposit{value: amount}();
    }

    function unwrapWmatic(uint256 amount) external payable onlyOwner {
        require((IWMATIC(wmatic).balanceOf(address(this)) >= amount), "insufficient matic");
        IWMATIC(wmatic).withdraw(amount);
    }

    function withdrawMatic() external payable onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }

    function withdrawToken(address _token) external payable onlyOwner {
        uint256 tokenBalance = IERC20(_token).balanceOf(address(this));
        IERC20(_token).transfer(owner(), tokenBalance);
    }

    modifier approvedExRelay{
          if (!checkFastLaneEOA(msg.sender) && owner() != msg.sender) revert("InvalidPermissions");
          _;
     }
}