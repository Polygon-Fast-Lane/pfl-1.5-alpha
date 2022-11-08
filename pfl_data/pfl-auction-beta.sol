//SPDX-License-Identifier: Unlicensed
pragma solidity ^0.8.16;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

struct FastLaneData {
    // current auction parameters
    uint256 stakeSharePayable;
    uint24 stakeShareRatio;
    bool paused;
    bool pendingUpdate;
}

struct PendingData {
    // proposed auction parameters
    uint24 stakeShareRatio;
    uint64 blockDeadline;
}

struct ValidatorData {
    bool active;
    uint16 index;
    address payee;
    uint64 blockUpdated; 
    // blockUpdated tracks blockNumber of last update to prevent simultaneous invalid payee updates 
    // and payouts due to social engineering. Validators can be large organizations and subject
    // to personnel change, etc.

    // TODO: discuss fee modifier for misbehavior?
}

interface ISearcherContract {
    function fastLaneCall(bytes calldata, uint256, address) external payable returns (bool, bytes memory);
}

abstract contract FastLaneAuctionEvents {

    event RelayPausedStateSet(bool state);
    event RelayValidatorEnabled(address validator);
    event RelayValidatorDisabled(address validator);
    event RelayValidatorPayeeUpdated(address _validator, address _payee);
    event RelayInitialized(address vault);
    event RelayShareSet(uint24 amount);
    event RelayShareProposed(uint24 amount);
    event RelayFlashBid(address indexed sender, uint256 amount, bytes32 indexed oppTxHash, address indexed validator, address searcherContractAddress);


    event ProcessingPaidValidator(address validator, uint256 validatorPayment);
    event ProcessingWithdrewStakeShare(address recipient, uint256 amountWithdrawn);

    error RelayInequalityTooHigh();

    error RelayPermissionPaused();
    error RelayPermissionNotFastLaneValidator();

    error RelayWrongInit();
    error RelayWrongSpecifiedValidator();
    error RelaySearcherWrongParams();

    error RelaySearcherCallFailure(bytes retData);
    error RelayNotRepaid(uint256 missingAmount);

    error AuctionEOANotEnabled();
    error AuctionCallerMustBeSender();
    error AuctionValidatorNotParticipating(address validator);
    error AuctionSearcherNotWinner(uint256 searcherBid, uint256 winningBid);
    error AuctionBidReceivedLate();

    error ProcessingNoBalancePayable();
    error ProcessingAmountExceedsBalance(uint256 amountRequested, uint256 balance);
}

contract FastLaneAuction is FastLaneAuctionEvents, Ownable, ReentrancyGuard {

    bytes4 internal constant callSelector = bytes4(keccak256("fastLaneCall(bytes calldata, uint256, address)"));
    uint64 internal constant blockTimeLock = 262_144; // approximately 6 days
    FastLaneData internal current = FastLaneData(0,0,false,false);
    PendingData internal pending = PendingData(0,0);

    mapping(address => ValidatorData) internal validatorDataMap;
    mapping(address => uint256) internal validatorBalanceMap; // map[validator] = balance
    mapping(bytes32 => uint256) internal fulfilledAuctionMap; // map key is keccak hash of opp tx's gasprice and tx hash

    address[] internal activeValidators;

    constructor() {
        if (address(this) == address(0)) revert("RelayWrongInit");

        setFastLaneStakeShare(uint24(5_000));

        emit RelayInitialized(address(this));
    }

    /***********************************|
    |  Public Searcher Bid Functions    |
    |__________________________________*/

    function submitFastLaneBid(
            uint256 _bidAmount, // Value commited to be repaid at the end of execution
            bytes32 _oppTxHash, // Target TX
            address _searcherToAddress,
            bytes calldata _searcherCallData 
        ) external payable nonReentrant whenNotPaused onlyParticipatingValidators senderIsOrigin returns (bytes memory) {
            
            // make sure another searcher hasn't already won the opp,
            // if so, revert early to save gas
            checkBid(_oppTxHash, _bidAmount);

            // store the current balance, excluding msg.value
            uint256 balanceBefore = address(this).balance - msg.value;

            // call the searcher's contract (see searcher_contract.sol for example of call receiver)
            (bool success, bytes memory returnedData) = _searcherToAddress.call{value: msg.value}(
                abi.encodeWithSelector(
                    callSelector,
                    _searcherCallData, 
                    _bidAmount, 
                    msg.sender
                )
            );

                /* code above is the same as code below but with the addition of passing the msg.value on to searcher
                    (bool success, bytes memory returnedData) = ISearcherContract(_searcherToAddress).fastLaneCall(
                        _searcherCallData, 
                        _bidAmount, 
                        msg.sender
                    );
                */

            // if searcher's call failed, revert 
            // (NOTE: can probably remove this line, but I want to leave room for layered error handling on the searcher's end)
            if (!success) revert("RelaySearcherCallFailure");

            // verify that the searcher paid the amount they bid & emit the event
            handleBalances(_bidAmount, balanceBefore);
            emit RelayFlashBid(msg.sender, _bidAmount, _oppTxHash, block.coinbase, _searcherToAddress);

            // return the results of the searcher's call
            return returnedData;
    }

    /***********************************|
    |    Internal Bid Helper Functions  |
    |__________________________________*/

    function checkBid(bytes32 _oppTxHash, uint256 _bidAmount) internal {
        if (_bidAmount == 0) revert("RelaySearcherWrongParams");
        
        // Use hash of the opportunity tx hash and the transaction's gasprice as key for bid tracking
        // This is dependent on the PFL Relay verifying that the searcher's gasprice matches
        // the opportunity's gasprice, and that the searcher used the correct opportunity tx hash

        bytes32 auction_key = keccak256(abi.encode(_oppTxHash, tx.gasprice));
        // NOTE: using abi.encodePacked may make this spoofable by clever antagonists 
        // who shift decimals in certain (rare) scenarios

        uint256 existing_bid = fulfilledAuctionMap[auction_key];

        if (existing_bid != 0) {
            if (_bidAmount >= existing_bid) {
                // TODO: This error message could also arise if the tx was sent via mempool
                revert("AuctionBidReceivedLate");
            } else {
                revert(string(abi.encodePacked("AuctionSearcherNotWinner ", Strings.toString(_bidAmount), " ", Strings.toString(existing_bid))));
            }
        }

        // Mark this auction as being complete to provide quicker reverts for subsequent searchers
        fulfilledAuctionMap[auction_key] = _bidAmount;
    }

    function forwardTxValue(address _searcherToAddress) internal {
        if (msg.value > 0) {
            safeTransferETH(_searcherToAddress, msg.value);
        }
    }

    function handleBalances(
            uint256 _bidAmount, 
            uint256 balanceBefore
    ) internal {
        // internal accounting helper
        uint256 expected = balanceBefore + _bidAmount;
        if (address(this).balance < expected) {
            revert(string(abi.encodePacked("RelayNotRepaid ", Strings.toString(_bidAmount), " ", Strings.toString(address(this).balance - balanceBefore))));
        }

        (uint256 amtPayableToValidator, uint256 amtPayableToStakers) = _calculateStakeShare(_bidAmount, _stakeShareRatio());

        validatorBalanceMap[block.coinbase] += amtPayableToValidator;
        current.stakeSharePayable += amtPayableToStakers;
    }

    /****************************************|
    | Owner-only Auction / State Functions   |
    |_______________________________________*/

    /// @notice Defines the paused state of the Auction
    /// @dev Only owner
    /// @param _state New state
    function setPausedState(bool _state) external onlyOwner {
        paused = _state;
        emit RelayPausedStateSet(_state);
    }

    function withdrawStakeShare(address recipient, uint256 amount) external onlyOwner {
        // TODO: Add limitations around recipient & amount (integrate DAO controls / voting results)
        if (amount > stakeSharePayable) {
            revert(string(abi.encodePacked("ProcessingAmountExceedsPayable ", Strings.toString(amount), " ", Strings.toString(current.stakeSharePayable))));
        }
        if (amount > address(this).balance) {
            revert(string(abi.encodePacked("ProcessingAmountExceedsBalance ", Strings.toString(amount), " ", Strings.toString(address(this).balance))));
        }
        stakeSharePayable -= amount;
        safeTransferETH(
            recipient, 
            amount
        );
        emit ProcessingWithdrewStakeShare(recipient, amount);
    }

    /// @notice Sets the stake revenue allocation (out of 1_000_000 (ie v2 fee decimals))
    /// @dev Initially set to 50_000 (5%) 
    /// Can't change the stake revenue allocation mid round - all changes go into effect in next round
    /// @param _fastLaneStakeShare Protocol stake allocation on bids
    function setFastLaneStakeShare(uint24 _fastLaneStakeShare) external onlyOwner {
        if (_fastLaneStakeShare > 1_000_000) revert("RelayInequalityTooHigh");
        pending.stakeShareRatio = _fastLaneStakeShare;
        pending.blockDeadline = uint64(block.number) + blockTimeLock;
        current.pendingUpdate = true;
        emit RelayShareProposed(_fastLaneStakeShare);
    }
    
    function enableValidator(address _validator, address _payee) external onlyOwner {
        if (!validatorDataMap[_validator].active) {
            validatorDataMap[_validator] = ValidatorData(true, uint16(activeValidators.length), _payee, uint64(block.number));
            activeValidators.push(_validator);
            emit RelayValidatorEnabled(_validator);
        }
    }

    function disableValidator(address _validator) external onlyOwner whenNotPaused {
        if (validatorDataMap[_validator].active) {
            uint256 validatorIndex = uint256(validatorDataMap[_validator].index);

            if (activeValidators.length > 1 && validatorIndex != activeValidators.length - 1) {
                // Replace removed validator's spot in array with 'last' validator, 
                // then pop last element of array
                // (array usage is not order-sensitive as long as index is tracked for moved validator)
                address lastValidator = activeValidators[activeValidators.length - 1];
                activeValidators[validatorIndex] = lastValidator;
                validatorDataMap[lastValidator].index = uint16(validatorIndex);
            }

            delete activeValidators[activeValidators.length - 1];

            if (validatorBalanceMap[_validator] > 0) {
                // pay removed validator any owed balance
                payValidator(_validator);
            }

            validatorDataMap[_validator].active = false;

            emit RelayValidatorDisabled(_validator);
        }
    }

    function updateValidatorPayee(address _validator, address _payee) external {
        if (!isValidatorProxy(_validator)) revert("UnauthorizedRequest");
        if (!validatorDataMap[_validator].active) revert("ValidatorInactive");
        validatorDataMap[_validator].payee = _payee;
        validatorDataMap[_validator].blockUpdated = uint64(block.number);

        emit RelayValidatorPayeeUpdated(_validator, _payee);   
    }

    /***********************************|
    |          Validator Functions      |
    |__________________________________*/

    function payValidator(address _validator) public whenNotPaused nonReentrant returns (uint256) {
        // pays the validator their outstanding balance excluding any unsettled funds from current round
        // callable by either validator or PFL
        if (!isValidatorProxy(_validator)) revert("UnauthorizedRequest");
        
        uint256 payableBalance = validatorBalanceMap[_validator];
        if (payableBalance > 0) {
            validatorBalanceMap[_validator] = 0;
            safeTransferETH(
                getValidatorPayee(_validator), 
                payableBalance
            );
            emit ProcessingPaidValidator(_validator, payableBalance);
        }
        return payableBalance;
    }

    /***********************************|
    |        State View Functions       |
    |__________________________________*/

    function getPausedStatus() public view returns (bool _paused) {
        _paused = current.paused;
    }

    function getValidatorBalance(address _validator) public view returns (uint256 _validatorBalance) {
        _validatorBalance = validatorBalanceMap[_validator];
    }

    function getValidatorPayee(address _validator) public view returns (address _payee) {
        _payee = validatorDataMap[_validator].payee;
    }

    function getCurrentStakeRatio() public view returns (uint24 _fastLaneStakeShare) {
        _fastLaneStakeShare = current.stakeShareRatio;
    }

    function getCurrentStakeBalance() public view returns (uint256 _fastLaneStakeBalance) {
        _fastLaneStakeBalance = current.stakeSharePayable;
    }

    function getPendingStakeRatio() public view returns (uint24 _fastLaneStakeShare) {
        if (current.pendingUpdate) {
            _fastLaneStakeShare = pending.stakeShareRatio;
        } else {
            _fastLaneStakeShare = current.stakeShareRatio;
        }
    }

    function getPendingDeadline() public view returns (uint64 _blockDeadline) {
        if (current.pendingUpdate) {
            _blockDeadline = pending.blockDeadline;
        } else {
            _blockDeadline = uint64(block.number);
        }
    }

    function getActiveValidators() public view returns (address[] memory _activeValidators) {
        _activeValidators = activeValidators;
    }

    function getValidatorStatus(address _validator) public view returns (bool _isActive) {
        _isActive = validatorDataMap[_validator].active;
    }

    /***********************************|
    |           Helper Functions        |
    |__________________________________*/

    function safeTransferETH(address to, uint256 amount) internal {
        bool success;

        assembly {
            // Transfer the ETH and store if it succeeded or not.
            success := call(gas(), to, amount, 0, 0, 0, 0)
        }

        require(success, "ETH_TRANSFER_FAILED");
    }

    function _calculateStakeShare(uint256 _amount, uint24 _share) internal pure returns (uint256 validatorCut, uint256 stakeCut) {
        validatorCut = (_amount * (1000000 - _share)) / 1000000;
        stakeCut = _amount - validatorCut;
    }

    function _stakeShareRatio() internal returns (uint24) {
        if (current.pendingUpdate) {
            if (current.stakeShareRatio != pending.stakeShareRatio) {
                if (uint64(block.number) > pending.blockDeadline) {
                    current.stakeShareRatio = pending.stakeShareRatio;
                    current.pendingUpdate = false;
                    emit RelayShareSet(_fastLaneStakeShare);
                }
            }
        }
        return current.stakeShareRatio;
    }

    function checkPayeeLock(address _validator) internal returns (bool _valid) {
        _valid = uint64(block.number) > validatorDataMap[_validator].blockUpdated + blockTimeLock;
    }

    function isValidPayee(address _validator, address _payee) internal returns (bool _valid) {
        _valid = checkPayeeLock(_validator) && _payee == validatorDataMap[_validator].payee;
    }

    function isValidatorProxy(address _validator) internal returns (bool _valid) {
        return msg.sender == _validator || msg.sender == owner() || isValidPayee(_validator, msg.sender);
    }

    function getValidatorPayee(address _validator) internal returns (address _recipient) {
        if (checkPayeeLock(_validator)) {
            _recipient = validatorDataMap[_validator].payee;
        } else {
            _recipient = _validator;
        }
    }

    fallback() external payable {}
    receive() external payable {}

    /***********************************|
    |             Modifiers             |
    |__________________________________*/

    modifier whenNotPaused() {
        if (current.paused) revert("RelayPermissionPaused");
        _;
    }

    modifier senderIsOrigin() {
        // NOTE: I know this is frowned upon 
        // goal of func is to block smart contracts from submitting bids
        if (msg.sender != tx.origin) revert("AuctionCallerMustBeSender");
        _;
    }

    modifier onlyParticipatingValidators() {
        if (!validatorDataMap[block.coinbase].active) revert("RelayPermissionNotFastLaneValidator");
        _;
    }
}

