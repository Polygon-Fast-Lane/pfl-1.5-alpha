pragma solidity ^0.8.16;
//SPDX-License-Identifier: Unlicensed

interface IFastLaneAuction {
    function authorizeSearcherEOA(address) external;
}

contract SearcherMinimalRawContract {

    address private owner;
    address payable private PFLAuction;

    error WrongPermissions();
    error OriginEOANotOwner();
    error SearcherCallFailure(bytes retData);
    error SearcherCallUnsuccessful();
    error SearcherBadFuncSelector(bytes4 _selector);

    address public anAddress;
    uint256 public anAmount;

    mapping(address => bool) internal approvedEOAs;

    constructor() {
        owner = msg.sender;
    }

    struct DoStuffCallArgs {
        address anAddress;
        uint256 anAmount;
    }

    // You choose your params as you want,
    // You will declare them in the `submitBid` transaction to PFL
    function FastLaneCall(bytes calldata _encodedCall) external payable onlyRelayer {

        // In a relayed context _msgSender() will point back to the EOA that signed the searcherTX
        // as the normal `msg.sender` points to the relayer.
        // see https://ethereum.stackexchange.com/questions/99250/understanding-openzeppelins-context-contract
        if (!approvedEOAs[_msgSender()]) revert OriginEOANotOwner();

        /* 
            ...
            Do whatever you want here, call your usual searcher contract, use calldata, msg.data, etc...
            ...
        */
        
        // MySearcherMEVContract.call(whatever); or
        // Someopportunity.call(whatever)
        // _target.call(_encodedCall);
        
        // or internally:
        // NOTE: This method assumes you pay the FastLane Auction bid inside your function:
        /*
            (bool success, bytes memory retData) = address(this).call(
                // remove last 20 bytes b/c of msg.sender address tacked on by FastLane Auction Contract
                _encodedCall[:_encodedCall.length-20]
            );
            if (!success) revert SearcherCallFailure(retData);
        */
        
        // another internal version, if you want to handle the PFL payment here and use a function selector:
        bytes4 _selector;
        assembly {
            _selector := calldataload(_encodedCall.offset)
        }

        if (_selector == this.doStuff.selector) {
            // then decode the rest the args, making sure to remove the address of msg.sender at the end
            DoStuffCallArgs memory funcArgs = abi.decode(
                _encodedCall[4:_encodedCall.length-20], 
                (DoStuffCallArgs)
            );
            
            // do the stuff
            bool isSuccessful = doStuff(funcArgs.anAddress, funcArgs.anAmount);

            // if the stuff didn't turn out the way you wanted, revert here or inside your MEV function itself
            if (!isSuccessful) revert SearcherCallUnsuccessful();

            // Repay PFL at the end
            safeTransferETH(PFLAuction, funcArgs.anAmount);

        } else {
            // revert if the selector can't find a match
            revert SearcherBadFuncSelector(_selector);
        }
    }

    function doStuff(address _anAddress, uint256 _anAmount) public returns (bool) {
        // your MEV function here.

        if (!isTrustedForwarder(msg.sender)) {
            // Since this is your regular MEV function, make sure not to run any 
            // msg.sender safety checks that would preclude the FastLane Auction 
            // from calling.
            // TODO: find a better / safer way to handle ^ or use a separate func wrapper
            // for non-FastLane calls and make this func internal-only.

            if (!approvedEOAs[msg.sender]) revert OriginEOANotOwner();
        }

        // Do MEV stuff here
        anAddress = _anAddress;
        anAmount = _anAmount;
        bool isSuccessful = true;
        return isSuccessful;
    }

    function _msgSender() internal view returns (address sender) {
        if (isTrustedForwarder(msg.sender)) {
            // The assembly code is more direct than the Solidity version using `abi.decode`.
            /// @solidity memory-safe-assembly
            assembly {
                sender := shr(96, calldataload(sub(calldatasize(), 20)))
            }
        } else {
            return msg.sender;
        }
    }

    // Can receive ETH
    fallback() external payable {}
    receive() external payable {}

    function isTrustedForwarder(address forwarder) public view returns (bool) {
        return forwarder == PFLAuction;
    }

    function safeTransferETH(address to, uint256 amount) internal {
        bool success;

        assembly {
            // Transfer the ETH and store if it succeeded or not.
            success := call(gas(), to, amount, 0, 0, 0, 0)
        }

        require(success, "ETH_TRANSFER_FAILED");
    }

    function setPFLAuctionAddress(address _pflAuction) public {
        if (msg.sender != owner) revert OriginEOANotOwner();
        PFLAuction = payable(_pflAuction);
    }

    function approveFastLaneEOA(address eoaAddress) public {
        if (msg.sender != owner) revert OriginEOANotOwner();
        IFastLaneAuction(PFLAuction).authorizeSearcherEOA(eoaAddress);
        approvedEOAs[eoaAddress] = true;
    }

    modifier onlyRelayer {
          if (!isTrustedForwarder(msg.sender)) revert WrongPermissions();
          _;
     }
}