//SPDX-License-Identifier: Unlicensed
pragma solidity ^0.8.16;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

struct Round {
    uint24 roundNumber;
    uint24 stakeAllocation;
    uint64 startBlock;
    uint64 endBlock;
    uint24 nextValidatorIndex;
    bool completedPayments;
}

interface ISearcherContract {
    function fastLaneCall(bytes calldata, uint256, address) external payable returns (bool, bytes memory);
}

abstract contract FastLaneRelayEvents {

    event RelayPausedStateSet(bool state);
    event RelayValidatorEnabled(address validator);
    event RelayValidatorDisabled(address validator);
    event RelayInitialized(address vault);
    event RelayShareSet(uint24 amount);
    event RelayFlashBid(address indexed sender, uint256 amount, bytes32 indexed oppTxHash, address indexed validator, address searcherContractAddress);
    event RelayNewRound(uint24 newRoundNumber);

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

    error ProcessingRoundNotOver();
    error ProcessingRoundFullyPaidOut();
    error ProcessingInProgress();
    error ProcessingNoBalancePayable();
    error ProcessingAmountExceedsBalance(uint256 amountRequested, uint256 balance);
}

contract FastLaneAuctionRelay is FastLaneRelayEvents, Ownable, ReentrancyGuard {

    uint24 internal currentRoundNumber;
    uint24 internal lastRoundProcessed;
    uint24 public fastLaneStakeShare;
    uint256 internal stakeSharePayable;
    bool public paused = false;
    bool internal isProcessingPayments = false;

    mapping(address => bool) internal validatorsMap;
    mapping(uint24 => mapping(address => uint256)) internal validatorBalanceMap; // map[round][validator] = balance
    mapping(address => uint256) internal validatorBalancePayableMap;
    mapping(uint24 => Round) internal roundDataMap;
    mapping(bytes32 => uint256) internal fulfilledAuctionMap;

    address[] internal participatingValidators;
    address[] internal removedValidators; 

    constructor() {
        if (address(this) == address(0)) revert("RelayWrongInit");

        setFastLaneStakeShare(uint24(5_000));

        currentRoundNumber = uint24(1);
        roundDataMap[currentRoundNumber] = Round(currentRoundNumber, fastLaneStakeShare, uint64(block.number), 0, 0, false);

        emit RelayInitialized(address(this));
    }

    function submitFastLaneBid(
            uint256 _bidAmount, // Value commited to be repaid at the end of execution
            bytes32 _oppTxHash, // Target TX
            address _searcherToAddress,
            bytes calldata _searcherCallData 
        ) external payable nonReentrant whenNotPaused onlyParticipatingValidators senderIsOrigin returns (bytes memory) {
            
            // make sure another searcher hasn't already won the opp,
            // if so, revert early to save gas
            checkBid(_oppTxHash, _bidAmount);

            // safely send any msg.value to the searcher's contract
            forwardTxValue(_searcherToAddress);

            // store the current balance, excluding msg.value
            uint256 balanceBefore = address(this).balance;

            // call the searcher's contract (see searcher_contract.sol for example of call receiver)
            (bool success, bytes memory returnedData) = ISearcherContract(_searcherToAddress).fastLaneCall(
                _searcherCallData, 
                _bidAmount, 
                msg.sender
            );

            // if searcher's call failed, revert 
            // (can probably remove this line, but I want to leave room for strange error handling on the searcher's end)
            if (!success) revert("RelaySearcherCallFailure");

            // verify that the searcher paid the amount they bid
            handleBalances(_bidAmount, balanceBefore);
            emit RelayFlashBid(msg.sender, _bidAmount, _oppTxHash, block.coinbase, _searcherToAddress);

            // return the results of the searcher's call
            return returnedData;
    }

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

    function handleBalances(uint256 _bidAmount, uint256 balanceBefore) internal {
        uint256 expected = balanceBefore + _bidAmount;
        uint256 balanceAfter = address(this).balance;
        if (balanceAfter < expected) {
            revert(string(abi.encodePacked("RelayNotRepaid ", Strings.toString(expected), " ", Strings.toString(balanceAfter))));
        }

        validatorBalanceMap[currentRoundNumber][block.coinbase] += _bidAmount;
    }

    /// @notice Internal, calculates cuts
    /// @dev validatorCut 
    /// @param _amount Amount to calculates cuts from
    /// @param _share bps
    /// @return validatorCut validator cut
    /// @return stakeCut protocol cut
    function _calculateStakeShare(uint256 _amount, uint24 _share) internal pure returns (uint256 validatorCut, uint256 stakeCut) {
        validatorCut = (_amount * (1000000 - _share)) / 1000000;
        stakeCut = _amount - validatorCut;
    }

    /***********************************|
    |             Owner-only            |
    |__________________________________*/

    /// @notice Defines the paused state of the Auction
    /// @dev Only owner
    /// @param _state New state
    function setPausedState(bool _state) external onlyOwner {
        paused = _state;
        emit RelayPausedStateSet(_state);
    }

    function newRound() external onlyOwner whenNotPaused {
        uint64 currentBlockNumber = uint64(block.number);
        
        roundDataMap[currentRoundNumber].endBlock = currentBlockNumber;
        currentRoundNumber++;

        roundDataMap[currentRoundNumber] = Round(currentRoundNumber, fastLaneStakeShare, currentBlockNumber, 0, 0, false);
    }

    function processValidatorsBalances() external whenNotPaused senderIsOrigin returns (bool) {
        // can be called by anyone
        // process rounds sequentially
        uint24 roundNumber = lastRoundProcessed + 1;

        if (roundNumber >= currentRoundNumber) revert("ProcessingRoundNotOver");

        if (roundDataMap[roundNumber].completedPayments) revert("ProcessingRoundFullyPaidOut");

        isProcessingPayments = true;

        uint24 stakeAllocation = roundDataMap[roundNumber].stakeAllocation;
        uint256 removedValidatorsLength = removedValidators.length;
        uint256 participatingValidatorsLength = participatingValidators.length;
        address validator;
        uint256 grossRevenue;
        uint256 netValidatorRevenue;
        uint256 netStakeRevenue;
        uint256 netStakeRevenueCollected;
        bool completedLoop = true;

        uint256 n = uint256(roundDataMap[roundNumber].nextValidatorIndex);
        
        if (n < removedValidatorsLength) {
            // check removed validators too - they may have been removed partway through a round
            for (n; n < removedValidatorsLength; n++) {
                if (gasleft() < 80_000) {
                    completedLoop = false;
                    break;
                }
                validator = removedValidators[n];
                grossRevenue = validatorBalanceMap[currentRoundNumber][validator];
                if (grossRevenue > 0) {
                    (netValidatorRevenue, netStakeRevenue) = _calculateStakeShare(grossRevenue, stakeAllocation);
                    validatorBalancePayableMap[validator] += netValidatorRevenue;
                    netStakeRevenueCollected += netStakeRevenue;
                }
            }
        }

        if (n < removedValidatorsLength + participatingValidatorsLength && n >= removedValidatorsLength) {
            for (n; n < removedValidatorsLength + participatingValidatorsLength; n++) {
                if (gasleft() < 80_000) {
                    completedLoop = false;
                    break;
                }
                validator = participatingValidators[n - removedValidatorsLength];
                grossRevenue = validatorBalanceMap[currentRoundNumber][validator];
                if (grossRevenue > 0) {
                    (netValidatorRevenue, netStakeRevenue) = _calculateStakeShare(grossRevenue, stakeAllocation);
                    validatorBalancePayableMap[validator] += netValidatorRevenue;
                    netStakeRevenueCollected += netStakeRevenue;
                }
            }
        }

        if (completedLoop) n += 1; // makes sure we didn't run out of gas on final validator in list
        
        roundDataMap[roundNumber].nextValidatorIndex = uint24(n);
        stakeSharePayable += netStakeRevenueCollected;

        if (n > removedValidatorsLength + participatingValidatorsLength) {
            // TODO: check if n keeps the final ++ increment that pushes it out of range of for loop
            roundDataMap[roundNumber].completedPayments = true;
            lastRoundProcessed = roundNumber;
            isProcessingPayments = false;
            return true;
        } else {
            return false;
        }
    }

    function withdrawStakeShare(address recipient, uint256 amount) external onlyOwner {
        // TODO: Add limitations around recipient & amount (integrate DAO controls / voting results)
        if (amount > stakeSharePayable) {
            revert(string(abi.encodePacked("ProcessingAmountExceedsBalance ", Strings.toString(amount), " ", Strings.toString(stakeSharePayable))));
        }
        stakeSharePayable -= amount;
        payable(recipient).transfer(amount);
        emit ProcessingWithdrewStakeShare(recipient, amount);
    }

    /// @notice Sets the stake revenue allocation (out of 1_000_000 (ie v2 fee decimals))
    /// @dev Initially set to 50_000 (5%) 
    /// Can't change the stake revenue allocation mid round - all changes go into effect in next round
    /// @param _fastLaneStakeShare Protocol stake allocation on bids
    function setFastLaneStakeShare(uint24 _fastLaneStakeShare)
        public
        onlyOwner
    {
        if (_fastLaneStakeShare > 1_000_000) revert("RelayInequalityTooHigh");
        fastLaneStakeShare = _fastLaneStakeShare;
        emit RelayShareSet(_fastLaneStakeShare);
    }
    
    function enableRelayValidatorAddress(address _validator) external onlyOwner {
        if (!validatorsMap[_validator]) {
            // check to see if this validator is being re-added
            if (removedValidators.length > 0) {
                bool existing = false;
                uint256 validatorIndex;
                address lastElement = removedValidators[removedValidators.length - 1];
                
                for (uint256 z=0; z < removedValidators.length; z++) {
                    if (removedValidators[z] == _validator) {
                        validatorIndex = z;
                        existing = true;
                        break;
                    }
                }
                if (existing) {
                    removedValidators[validatorIndex] = lastElement;
                    delete removedValidators[removedValidators.length - 1];
                }
            }
            participatingValidators.push(_validator);
            validatorsMap[_validator] = true;
            emit RelayValidatorEnabled(_validator);
        }
    }

    function disableRelayValidatorAddress(address _validator) external onlyOwner {
        if (validatorsMap[_validator]) {
            bool existing = false;
            uint256 validatorIndex;
            address lastElement = participatingValidators[participatingValidators.length - 1];
            for (uint256 z=0; z < participatingValidators.length; z++) {
                if (participatingValidators[z] == _validator) {
                    validatorIndex = z;
                    existing = true;
                    break;
                }
            }
            if (existing) {
                participatingValidators[validatorIndex] = lastElement;
                delete participatingValidators[participatingValidators.length - 1];
            }
            removedValidators.push(_validator);
            validatorsMap[_validator] = false;
            emit RelayValidatorDisabled(_validator);
        }
    }

    /***********************************|
    |          Validator Functions      |
    |__________________________________*/

    function payValidator(address validator) public whenNotPaused senderIsOrigin returns (uint256) {
        if (validatorBalancePayableMap[validator] == 0) revert("ProcessingNoBalancePayable");
        if (isProcessingPayments) revert("ProcessingInProgress");
        if (msg.sender != validator || msg.sender != owner()) revert("UnauthorizedPayor");
        uint256 payableBalance = validatorBalancePayableMap[validator];
        validatorBalancePayableMap[validator] = 0;
        payable(validator).transfer(payableBalance);
        emit ProcessingPaidValidator(validator, payableBalance);
        return payableBalance;
    }

    function getValidatorBalance(address validator) public view returns (uint256, uint256) {
        // returns balancePayable, balancePending
        if (isProcessingPayments) revert("ProcessingInProgress");
        uint256 balancePending; 
        uint256 netValidatorRevenue;
        for (uint24 _roundNumber = lastRoundProcessed + 1; _roundNumber <= currentRoundNumber; _roundNumber++) {
            (netValidatorRevenue,) = _calculateStakeShare(validatorBalanceMap[_roundNumber][validator], roundDataMap[_roundNumber].stakeAllocation);
            balancePending += netValidatorRevenue;
        }
        return (validatorBalancePayableMap[validator], balancePending);
    }

    /***********************************|
    |        State View Functions       |
    |__________________________________*/

    function getCurrentRound() public view returns (uint24 _currentRoundNumber) {
        _currentRoundNumber = currentRoundNumber;
    }

    function getLastRoundProcessed() public view returns (uint24 _lastRoundProcessed) {
        _lastRoundProcessed = lastRoundProcessed;
    }

    function getFastLaneStakeShare() public view returns (uint24 _fastLaneStakeShare) {
        _fastLaneStakeShare = fastLaneStakeShare;
    }

    function getPausedStatus() public view returns (bool _paused) {
        _paused = paused;
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

    /***********************************|
    |             Modifiers             |
    |__________________________________*/

    modifier whenNotPaused() {
        if (paused) revert("RelayPermissionPaused");
        _;
    }

    modifier senderIsOrigin() {
        if (msg.sender != tx.origin) revert("AuctionCallerMustBeSender");
        _;
    }

    modifier onlyParticipatingValidators() {
        if (!validatorsMap[block.coinbase]) revert("RelayPermissionNotFastLaneValidator");
        _;
    }
}

