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

    error WrongPermissions();
    error OriginEOANotOwner();
    error SearcherCallUnsuccessful(bytes retData);
    error SearcherInsufficientFunds(uint256 amountToSend, uint256 currentBalance);

    mapping(address => bool) internal approvedEOAs;

    constructor() {
    }

    // the FastLane Auction contract will call this function
    function fastLaneCall(
            uint256 _bidAmount,
            address _sender,
            bytes calldata _searcherCallData // contains func selector and calldata for your MEV transaction
    ) external payable onlyRelayer nonReentrant returns (bool, bytes memory) {
        
        // make sure it's your own EOA that's calling your contract
        require(checkFastLaneEOA(_sender), "SenderEOANotApproved");

        // execute the searcher's intended function
        // NOTE: if you were planning to pay with the msg.value, you can remove {value: msg.value}
        // from the call below (assuming your searcher contract doesn't need it)
        (bool success, bytes memory returnedData) = SearcherContract.call{value: msg.value}(_searcherCallData);
        
        // if the call didn't turn out the way you wanted, revert either here or inside your MEV function itself
        require(success, "SearcherCallUnsuccessful");

        // balance check then Repay PFL at the end
        handlePayback(_bidAmount);
        
        // return the return data (optional)
        return (success, returnedData);
    }

    // Other functions / modifiers that are necessary for FastLane integration:
    // NOTE: you can use your own versions of these, or find alternative ways
    // to implement similar safety checks. Please be careful!

    function handlePayback(uint256 _bidAmount) internal {
        // NOTE: this is a generalized approach to serve as an example. In practice,
        // we recommend making this process specific to your own smart contract
        // to avoid the significant amount of unnecessary gas usage here.

        if (address(this).balance >= _bidAmount) {
            safeTransferETH(FastLaneAuction, _bidAmount);

        } else if (IWMATIC(wmatic).balanceOf(address(this)) >= _bidAmount) {
            IWMATIC(wmatic).withdraw(_bidAmount);
            safeTransferETH(FastLaneAuction, _bidAmount);
        
        } else if (
                IWMATIC(wmatic).balanceOf(SearcherContract) >= _bidAmount
                && IWMATIC(wmatic).allowance(SearcherContract, address(this)) >= _bidAmount
        ) {
            IWMATIC(wmatic).transferFrom(SearcherContract, address(this), _bidAmount);
            IWMATIC(wmatic).withdraw(_bidAmount);
            safeTransferETH(FastLaneAuction, _bidAmount);

        } else {
            revert SearcherInsufficientFunds(_bidAmount, address(this).balance);
        }
    }

    function safeTransferETH(address to, uint256 amount) internal {
        bool success;

        assembly {
            // Transfer the ETH and store if it succeeded or not.
            success := call(gas(), to, amount, 0, 0, 0, 0)
        }

        require(success, "ETH_TRANSFER_FAILED");
    }

    function setPFLAuctionAddress(address _fastLaneAuction) external onlyOwner {
        FastLaneAuction = payable(_fastLaneAuction);
    }

    function setSearcherAddress(address _searcherAddress) external onlyOwner {
        SearcherContract = payable(_searcherAddress);
    }

    function approveFastLaneEOA(address eoaAddress) external onlyOwner {
        approvedEOAs[eoaAddress] = true;
    }

    function removeFastLaneEOA(address eoaAddress) external onlyOwner {
        approvedEOAs[eoaAddress] = false;
    }

    function checkFastLaneEOA(address eoaAddress) view internal returns (bool _valid) {
        _valid = approvedEOAs[eoaAddress];
    }

    function isTrustedForwarder(address forwarder) public view returns (bool) {
        return forwarder == FastLaneAuction;
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

    fallback() external payable {}
    receive() external payable {}

    modifier onlyRelayer {
          if (!isTrustedForwarder(msg.sender)) revert("InvalidPermissions");
          _;
     }
}