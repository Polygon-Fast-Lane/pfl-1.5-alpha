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

    address public anAddress;
    uint256 public anAmount;

    constructor() {
        owner = msg.sender;
    }

    struct PFLCallArgs {
        address anAddress;
        uint256 anAmount;
        uint256 paymentAmount;
        address msgSender; // built into all FastLaneCalls for security purposes (see _msgSender func)
    }

    // You choose your params as you want,
    // You will declare them in the `submitBid` transaction to PFL
    function FastLaneCall(bytes calldata _encodedCall) external payable onlyRelayer {

        // In a relayed context _msgSender() will point back to the EOA that signed the searcherTX
        // as the normal `msg.sender` points to the relayer.
        // see https://ethereum.stackexchange.com/questions/99250/understanding-openzeppelins-context-contract
        if (_msgSender() != owner) revert OriginEOANotOwner();

        /* 
            ...
            Do whatever you want here, call your usual searcher contract, use msg.data
            or do the swaps / multicall from inside this one.
            `msg.sender` will be your SearcherMinimalContract
            ...
        */
        
        // MySearcherMEVContract.call(whatever); or
        // Someopportunity.call(whatever)
        // _target.call(_encodedCall);
        
        // or internally:
        PFLCallArgs memory funcArgs = abi.decode(_encodedCall, (PFLCallArgs));
        doStuff(funcArgs.anAddress, funcArgs.anAmount);
        
        // Repay PFL at the end
        safeTransferETH(PFLAuction, funcArgs.paymentAmount);
    }

    function doStuff(address _anAddress, uint256 _anAmount) public {
        // _encodedCall should be the input data of a tx that calls this function
        anAddress = _anAddress;
        anAmount = _anAmount;
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

    function approveFastlaneEOA() public {
        if (msg.sender != owner) revert OriginEOANotOwner();
        IFastLaneAuction(PFLAuction).authorizeSearcherEOA(msg.sender);
    }


    modifier onlyRelayer {
          if (!isTrustedForwarder(msg.sender)) revert WrongPermissions();
          _;
     }
}