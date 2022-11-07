pragma solidity ^0.8.16;
//SPDX-License-Identifier: Unlicensed

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

contract FastLaneSearcherWrapper is ReentrancyGuard {

    address private owner;
    address payable private PFLAuction;

    error WrongPermissions();
    error OriginEOANotOwner();
    error SearcherCallUnsuccessful(bytes retData);
    error SearcherInsufficientFunds(uint256 amountToSend, uint256 currentBalance);

    address public anAddress; // just a var to change for the placeholder MEV function
    uint256 public anAmount; // another var to change for the placeholder MEV function

    mapping(address => bool) internal approvedEOAs;

    constructor() {
        owner = msg.sender;
    }

    // the FastLane Auction contract will call this function
    function fastLaneCall(
        bytes calldata _searcherCallData, // contains func selector and calldata for your MEV transaction
        uint256 _bidAmount,
        address _sender
    ) external payable onlyRelayer nonReentrant returns (bool, bytes memory) {
        
        // make sure it's your own EOA that's calling your contract 
        checkFastLaneEOA(_sender);

        // execute the searcher's intended function
        (bool success, bytes memory returnedData) = address(this).call(_searcherCallData);
        
        // if the call didn't turn out the way you wanted, revert either here or inside your MEV function itself
        require(success, "SearcherCallUnsuccessful");

        // balance check then Repay PFL at the end
        require(
            (address(this).balance < _bidAmount), 
            string(abi.encodePacked("SearcherInsufficientFunds  ", Strings.toString(_bidAmount), Strings.toString(address(this).balance)))
        );
        safeTransferETH(PFLAuction, _bidAmount);
        
        // return the return data (optional)
        return (success, returnedData);
    }

    // Other functions / modifiers that are necessary for FastLane integration:
    // NOTE: you can use your own versions of these, or find alternative ways
    // to implement similar safety checks. Please be careful when altering!
    function safeTransferETH(address to, uint256 amount) internal {
        bool success;

        assembly {
            // Transfer the ETH and store if it succeeded or not.
            success := call(gas(), to, amount, 0, 0, 0, 0)
        }

        require(success, "ETH_TRANSFER_FAILED");
    }

    function setPFLAuctionAddress(address _pflAuction) public {
        if (msg.sender != owner) revert("OriginEOANotOwner");
        PFLAuction = payable(_pflAuction);
    }

    function approveFastLaneEOA(address eoaAddress) public {
        if (msg.sender != owner) revert("OriginEOANotOwner");
        approvedEOAs[eoaAddress] = true;
    }

    function checkFastLaneEOA(address eoaAddress) view internal {
        if (!approvedEOAs[eoaAddress]) revert("SenderEOANotApproved");
    }

    function isTrustedForwarder(address forwarder) public view returns (bool) {
        return forwarder == PFLAuction;
    }

    fallback() external payable {}
    receive() external payable {}

    modifier onlyRelayer {
          if (!isTrustedForwarder(msg.sender)) revert("InvalidPermissions");
          _;
     }
}

contract SearcherContractExample is FastLaneSearcherWrapper {
    // your own MEV function here 
    // NOTE: its security checks must be compatible w/ calls from the FastLane Auction Contract
    function doStuff(address _anAddress, uint256 _anAmount) public payable returns (bool) {
        // NOTE: this function can't be external as the FastLaneCall func will call it internally
        if (!isTrustedForwarder(msg.sender) && msg.sender != address(this)) { // example of safety check modification - only check msg.sender when not forwarded
            // NOTE: msg.sender becomes address(this) if using call from inside contract per above example
            require(approvedEOAs[msg.sender], "SenderEOANotApproved");
        }
        

        // Do MEV stuff here
        anAddress = _anAddress;
        anAmount = _anAmount;
        bool isSuccessful = true;
        return isSuccessful;
    }
}