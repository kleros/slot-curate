/**
 * @authors: @greenlucid
 * @reviewers: []
 * @auditors: []
 * @bounties: []
 * @deployments: []
 * SPDX-License-Identifier: Licenses are not real
 */
 
 pragma solidity ^0.8.9;

/*
    things to think about
    
    even though ItemRemoved and ItemAdded are the same functionality wise
    it is cheaper to have them as separate events to avoid putting more variables
    because each aditional variable is paid.
    
    put an option to manually call the function to calculate juror fees and store it locally
    instead of calling an expensive function over contracts every time
    this would get harder if we store arbitrator / arbextradata separately
    
    put the most used functions (add, remove item) as first functions because that
    makes it cheaper

    with rollups it is very important to compress function args
    consider making:
    slot uint64
    listId uint64
    settings being an uint32 may provide surface attack. a spammer could spam
    and create tons of settings so that no new settings could be ever created.
    4B of settings at 150k per creation can hold 17 years of having all blocks fully creating settings.
    with so much time and so many settings, maybe there's a few useful ones?

    // adding the list requires made it SUPER expensive.
    // now it's 38k to add item. not acceptable.
    // what ill do instead is, just verify it on the subgraph instead.
    // if user posts list that doesn't exist, or posts settings that are not the current settings of that list
    // then subgraph will act as if item didn't exist. or, maybe track it but as an invalid item.
    // this means, now you have to submit the settings in the args...?
    // maybe instead submit list, do the extra read but don't do require.
    yup. that removed 4k cost, just like that.
    now 50.6k to create initially, and 33545 in used slot.
    if settings not in args, 52.4k initially and 35186 in used slot.
    changing the order: 52286, 
    AND means you can do it by only verifying list exists in subgraph.
    and i wasn't even verifying minimum stake... yeah seems like it's up to 35.4k again.

    ideas for the future:
    not even store all data to verify the process on chain. you could let invalid process on chain
    just exist and finish, and ignore them.
    you could even not store the lists logic at all, make them just be another item submission, somehow.
    again, the terms will be stored off chain, so whoever doesn't play by the rules is just ignored
    and you let their process exist and do whatever.

    an idea (that shouldn't be implemented) is using basic compression
    instead of storing contributors in the contributor field of the contribution
    store contributor in the contributors mapping. and then you can just put an id
    lets say you use uint64 as identifier. that's 96 bits saved.
    using this you could get away with storing stuff in half the space.
    effectively halving the creation of new slots.
    could could work for process slots. just save the addresses there.
    however 32 extra bits would have to be saved somewhere to make it work.
    use a view function to check if you need to create a new address.
    (you'd prob use a batch transaction to submit the address first)
*/

contract SlotCurate {

    uint constant AMOUNT_BITSHIFT = 32; // this could make submitter lose up to 4 gwei
    
    enum ProcessType {
        Add,
        Removal
    }
    
    enum Party {
        Requester,
        Challenger
    }
    
    enum DisputeState {
        Free, // you can take slot
        Ruling, // arbitrator is ruling...
        Funding // users can contribute to seed next round. could also mean "over" if timestamp.
    }

    // settings cannot be mutated once created
    struct Settings {
        // you don't need to store created
        uint requesterStake;
        uint challengerStake;
        uint40 requestPeriod;
        uint40 fundingPeriod;
        address arbitrator;
        uint16 freeSpace;
        //  store extraData?!?!
    }
    
    struct List {
        uint32 settingsId;
        address governor; // governors can change governor of the list, and change settingsId
        uint64 freeSpace;
    }
    
    // if you compress bools and enum into 1 byte (uint8)
    // 2 vacant bytes    
    struct Slot {
        bool used;
        ProcessType processType;
        bool beingDisputed;
        uint32 settingsId; // to discourage settings spam attack. maybe put the 2 bytes here.
        uint40 requestTime; // overflow in 37k years
        address requester;
    }
    
    // all bounded data related to the Dispute. unbounded data such as contributions is handled out
    // todo
    struct Dispute {
        // you could save 8 bits by just having "used" be nContributions == 0.
        // and setting nContributions to zero when contribs are cashed out, so dispute slot is available.
        // but there's no gas to save doing so (yet)
        uint256 arbitratorDisputeId; // required
        uint64 slotId; // flexible
        address challenger; // store it here instead of contributions[dispute][0]
        DisputeState state; 
        uint8 currentRound;
        uint24 freeSpace;
        uint64 nContributions; // if 0, it means slot is unused.
        uint40 timestamp; // to derive  
        uint152 freeSpace2;
    }
    
    struct Contribution {
        uint8 round; // could be bigger, there's enough space by shifting amount.
        Party party;
        uint80 amount; // to be raised 32 bits.
        address contributor; // could be compressed to 64 bits, but there's no point.
    }

    struct StoredRuling {
        uint ruling;
        bool ruled; // this bit costs 20k gas
    }
    
    // EVENTS //
    
    event ListCreated(uint64 _listIndex, uint32 _settingsId, address _governor, string _ipfsUri);
    event ListUpdated(uint64 _listIndex, uint32 _settingsId, address _governor);
    event SettingsCreated(uint _requestPeriod, uint _requesterStake, uint _challengerStake);
    event ItemAddRequest(uint64 _listIndex, uint64 _slotIndex, string _ipfsUri);
    event ItemAdded(uint64 _slotIndex);
    event ItemRemovalRequest(uint64 _workSlot, uint32 _settingsId, uint64 _idSlot, uint40 _idRequestTime);
    event ItemRemoved(uint64 _slotIndex);
    
    
    // CONTRACT STORAGE //
    uint64 listCount;
    uint32 settingsCount; // to prevent from assigning invalid settings to lists.

    mapping(uint64 => Slot) slots;
    mapping(uint64 => Dispute) disputes;
    mapping(uint64 => List) lists;
    // encoded with uint32 to make an attack unfeasible, but could go 2 extra bytes.
    mapping(uint32 => Settings) settingsMap;
    mapping(uint256 => mapping(uint64 => Contribution)) contributions; // contributions[disputeSlot][n]
    mapping(address => mapping(uint256 => StoredRuling)) storedRulings; // storedRulings[arbitrator][disputeId]
    
    constructor() {
    }
    
    // PUBLIC FUNCTIONS
    
    // lists
    function createList(address _governor, uint32 _settingsId, string memory _ipfsUri) public {
        require(_settingsId < settingsCount, "Settings must exist");
        List storage list = lists[listCount++];
        list.governor = _governor;
        list.settingsId = _settingsId;
        emit ListCreated(listCount - 1, _settingsId, _governor, _ipfsUri);
    }

    function updateList(uint64 _listIndex, uint32 _settingsId, address _newGovernor) public {
        List storage list = lists[_listIndex];
        require(msg.sender == list.governor, "You need to be the governor");
        list.governor = _newGovernor;
        list.settingsId = _settingsId;
        emit ListUpdated(_listIndex, _settingsId, _newGovernor);
    }

    // settings
    // bit of a draft since I havent done the dispute side of things yet
    function createSettings(uint _requesterStake, uint _challengerStake, uint40 _requestPeriod, uint40 _fundingPeriod) public {
        // put safeguard check? for checking if settingsCount is -1.
        require(settingsCount != 4294967295, "Max settings reached"); // there'd be 4.3B so please just reuse one
        Settings storage settings = settingsMap[settingsCount++];
        settings.requesterStake = _requesterStake;
        settings.challengerStake = _challengerStake;
        settings.requestPeriod = _requestPeriod;
        settings.fundingPeriod = _fundingPeriod;
        emit SettingsCreated(_requestPeriod, _requesterStake, _challengerStake);
    }
    
    // no refunds for overpaying. consider it burned. refunds are bloat.

    // you could add an "emergency" boolean option.
    // if on, and the chosen slotIndex is taken, it will look for the first unused slot and create there instead.
    // otherwise, the transaction fails. it's important to have it optional this since there could potentially be a lot of
    // taken slots.
    // but its important to have to option as safeguard in case frontrunners try to inhibit the protocol.
    // another way is making a separate wrapper public function for this, that calls the two main ones
    // (make one for add and another for remove. and another one for challenging (to get free dispute slot))

    // in the contract, listIndex and settingsId are trusted.
    // but in the subgraph, if listIndex doesnt exist or settings are not really the ones on list
    // then item will be ignored or marked as invalid.
    function addItem(uint64 _listIndex, uint32 _settingsId, uint64 _slotIndex, string memory _ipfsUri) public payable {
        Slot storage slot = slots[_slotIndex];
        require(slot.used == false, "Slot must not be in use");
        Settings storage settings = settingsMap[_settingsId];
        require(msg.value >= settings.requesterStake, "This is not enough to cover initil stake");
        slot.settingsId = _settingsId;
        slot.used = true;
        slot.processType = ProcessType.Add;
        slot.beingDisputed = false;
        slot.requestTime = uint40(block.timestamp);
        slot.requester = msg.sender;
        emit ItemAddRequest(_listIndex, _slotIndex, _ipfsUri);
    }
    
    // list is checked in subgraph. settings is trusted here.
    // if settings was not the one settings in subgraph at the time,
    // then subgraph will ignore the removal (so it has no effect when exec.)
    // could even be challenged as an ilegal request to extract the stake, if significant.
    function removeItem(uint64 _workSlot, uint32 _settingsId, uint64 _idSlot, uint40 _idRequestTime) public payable {
        Slot storage slot = slots[_workSlot];
        require(slot.used == false, "Slot must not be in use");
        Settings storage settings = settingsMap[_settingsId];
        require(msg.value >= settings.requesterStake, "This is not enough to cover requester stake");
        slot.settingsId = _settingsId;
        slot.used = true;
        slot.processType = ProcessType.Removal;
        slot.beingDisputed = false;
        slot.requestTime = uint40(block.timestamp);
        slot.requester = msg.sender;
        emit ItemRemovalRequest(_workSlot, _settingsId, _idSlot, _idRequestTime);
    }
    
    function executeRequest(uint64 _slotIndex) public {
        Slot storage slot = slots[_slotIndex];
        require(slotIsExecutable(slot), "Slot cannot be executed");
        // it will be executed now
        slot.used = false;
        Settings storage settings = settingsMap[slot.settingsId];
        payable(slot.requester).transfer(settings.requesterStake);
        if (slot.processType == ProcessType.Add) {
            emit ItemAdded(_slotIndex);
        }
        else {
            emit ItemRemoved(_slotIndex);
        }
    }

    function challengeRequest(uint64 _slotIndex, uint64 _disputeSlot) public payable {
        Slot storage slot = slots[_slotIndex];
        require(slotCanBeChallenged(slot), "Slot cannot be challenged");
        Settings storage settings = settingsMap[slot.settingsId];
        require(msg.value >= settings.challengerStake, "This is not enough to cover challenger stake");
        Dispute storage dispute = disputes[_disputeSlot];
        require(dispute.state == DisputeState.Free, "That dispute slot is being used");

        // it will be challenged now

        // arbitrator magic happens here (pay fees, maybe read how much juror fees are...)
        // and get disputeId so that you can store it, you know.
        // we try to create the dispute first, then update values here.

        //  weird edge cases:
        // with juror fees increasing, and item is quickly requested
        // before list settings are updated.
        // the item might not have enough in stake to pay juror fees, and this
        // would always fail. not sure how to proceed, then.
        // i wouldn't trust an arbitrator that can pull that off.

        slot.beingDisputed = true;
        dispute.state = DisputeState.Ruling;
        dispute.nContributions = 0;
        dispute.slotId = _slotIndex;
        // round is 0, amount is in dispute.slotId -> slot.settings -> settings.challengerStake, party is challenger
        // so it's a waste to create a contrib. just integrate it with dispute slot.
        dispute.challenger = msg.sender;
    }

    function contribute(uint64 _disputeSlot, Party _party) public payable {
        Dispute storage dispute = disputes[_disputeSlot];
        require(dispute.state == DisputeState.Funding, "Dispute is not in funding state");
        // compress amount, possibly losing up to 4 gwei. they will be burnt.
        uint80 amount = uint80(msg.value >> AMOUNT_BITSHIFT);
        contributions[_disputeSlot][dispute.nContributions++] = Contribution({
            round: dispute.currentRound + 1,
            party: _party,
            contributor: msg.sender,
            amount: amount
        });
    }

    function startNextRound(uint64 _disputeSlot, uint64 _firstContributionForRound) public {
        Dispute storage dispute = disputes[_disputeSlot];
        uint8 nextRound = dispute.currentRound + 1; // to save gas with less storage reads
        require(dispute.state == DisputeState.Funding, "Dispute has to be on Funding");
        Contribution memory firstContribution = contributions[_disputeSlot][_firstContributionForRound];
        require(nextRound == firstContribution.round, "This contribution is for another round");
        // get required fees from somewhere. how? is it expensive? do I just calculate here?
        // look into this later. for now just make the total amount up.
        uint80 totalAmountNeeded = 3000;
        uint80 sumOfAmounts = firstContribution.amount;
        uint64 i = _firstContributionForRound;
        bool successFlag = false;
        for (;; i++) {
            Contribution storage contribution = contributions[_disputeSlot][i];
            // break if round changes.
            // actually theres a better way to do this. fix this abomination.
            // you dont need to check round, you could just do the for until
            // you run out of nContributions
            // because you cannot bullshit the rounds anyway
            // no one can make a contribution with the wrong round.
            // todo
            if (nextRound != contribution.round) {
                break;
            }
            sumOfAmounts = sumOfAmounts + contribution.amount;
            // break if needed sum is reached
            if (sumOfAmounts >= totalAmountNeeded) {
                successFlag = true;
                break;
            }
        }
        require(successFlag, "Insufficient amount");
        uint actualAmount = totalAmountNeeded << uint80(AMOUNT_BITSHIFT);
        // something is done with the actual amount
        // its divided by something or whatever and you get the fees
        // or maybe you already know, and read from settings or a view func.
        // bs event to make VS Code shut up. TODO.
        emit ItemAdded(uint64(actualAmount));
    }

    function executeRuling(uint64 _disputeSlot) public {
        //1. get arbitrator for that setting, and disputeId from disputeSlot.
        Dispute storage dispute = disputes[_disputeSlot];
        Slot storage slot = slots[dispute.slotId];
        Settings storage settings = settingsMap[slot.settingsId];
        //   2. make sure that disputeSlot has an ongoing dispute
        require(dispute.state == DisputeState.Funding, "Dispute can only be executed in Funding state");
        //    3. access storedRulings[arbitrator][disputeId]. make sure it's ruled.
        StoredRuling memory storedRuling = storedRulings[settings.arbitrator][dispute.arbitratorDisputeId];
        require(storedRuling.ruled, "This wasn't ruled by the designated arbitrator");
        //    4. apply ruling. what to do when refuse to arbitrate? dunno. maybe... just
        //    default to requester, in that case.
        // 0 refuse, 1 requester, 2 challenger.
        if(storedRuling.ruling == 1 || storedRuling.ruling == 0) {
            // requester won.
            if(slot.processType == ProcessType.Add) {
                emit ItemAdded(dispute.slotId);
            } else {
                emit ItemRemoved(dispute.slotId);
            }
        } else {
            // challenger won.
            if(slot.processType == ProcessType.Add) {
                emit ItemRemoved(dispute.slotId);
            } else {
                emit ItemAdded(dispute.slotId);
            }
        }
        // 5. withdraw rewards
        withdrawRewards(_disputeSlot);
        // 6. dispute and slot are now Free.
        slot.used = false;
        dispute.state = DisputeState.Free; // to avoid someone withdrawing rewards twice.
    }

    // rule:
    function rule(uint _disputeId, uint _ruling) external {
        storedRulings[msg.sender][_disputeId] = StoredRuling({
            ruling: _ruling,
            ruled: true
        });
    }

    function withdrawRewards(uint64 _disputeSlot) private {
        // todo
    }
    
    
    // VIEW FUNCTIONS
    
    // relying on this by itself could result on users colliding on same slot
    // user which is late will have the transaction cancelled, but gas wasted and unhappy ux
    // could be used to make an "emergency slot", in case your slot submission was in an used slot.
    // will get the first Virgin, or Created slot.
    function firstFreeSlot(uint64 _startPoint) view public returns (uint64) {
        uint64 i = _startPoint;
        while (slots[i].used) {
            i = i + 1;
        }
        return i;
    }
    
    // debugging purposes, for now. shouldn't be too expensive and could be useful in future, tho
    // doesn't actually "count" the slots, just checks until there's a virgin slot
    // it's the same as "maxSlots" in the notes
    function firstVirginSlotFrom(uint64 _startPoint) view public returns (uint64) {
        uint64 i = _startPoint;
        while (slots[i].requester != address(0)){
            i = i + 1;
        }
        return i;
    }
    
    // this is prob bloat. based on the idea of generating a random free slot, to avoid collisions.
    // could be used to advice the users to wait until there's free slot for gas savings.
    function countFreeSlots() view public returns (uint64) {
        uint64 slotCount = firstVirginSlotFrom(0);
        uint64 i = 0;
        uint64 freeSlots = 0;
        for (; i < slotCount; i++) {
            Slot storage slot = slots[i];
            if (!slot.used) {
                freeSlots++;
            }
        }
        return freeSlots;
    }
    
    function viewSlot(uint32 _slotIndex) view public returns (Slot memory) {
        return slots[_slotIndex];
    }
    
    function slotIsExecutable(Slot memory _slot) view public returns (bool) {
        Settings storage settings = settingsMap[_slot.settingsId];
        bool overRequestPeriod = block.timestamp > _slot.requestTime + settings.requestPeriod;
        return _slot.used && overRequestPeriod && !_slot.beingDisputed;
    }
    
    function slotCanBeChallenged(Slot memory _slot) view public returns (bool) {
        Settings storage settings = settingsMap[_slot.settingsId];
        bool overRequestPeriod = block.timestamp > _slot.requestTime + settings.requestPeriod;
        return _slot.used && !overRequestPeriod && !_slot.beingDisputed;
    }

    // redo this. this is not how it actually works. arbitrator rule is what decides
    // if you can cashout.
    function canCashoutContributions(uint64 _disputeSlot) view public returns (bool) {
        Dispute storage dispute = disputes[_disputeSlot];
        Slot storage slot = slots[dispute.slotId];
        Settings storage settings = settingsMap[slot.settingsId];
        bool overFundingPeriod = block.timestamp > dispute.timestamp + settings.fundingPeriod;
        // cashout state can be derived from timestamp + funding. if it wasn't funded in time then its over.
        return overFundingPeriod && dispute.state == DisputeState.Funding;
    }

    // make a pure function that returns "slotData" given parameters such as
    // used, processType and disputed, in a single encoded uint8.
    function paramsToSlotdata(bool _used, ProcessType _processType, bool _disputed) public pure returns (uint8) {
        uint8 usedAddend;
        if (_used) usedAddend = 128;
        uint8 processTypeAddend;
        if (_processType == ProcessType.Removal) processTypeAddend = 64;
        uint8 disputedAddend;
        if (_disputed) disputedAddend = 32;
        uint8 slotdata = usedAddend + processTypeAddend + disputedAddend;
        return slotdata;
    }

    // also make a pure function that returns a tuple with these three from a given slotData
    function slotdataToParams(uint8 _slotdata) public pure returns (bool, ProcessType, bool) {
        uint8 usedAddend = _slotdata & 128;
        bool used = usedAddend != 0;
        uint8 processTypeAddend = _slotdata & 64;
        ProcessType processType = ProcessType(processTypeAddend >> 6);
        uint8 disputedAddend = _slotdata & 32;
        bool disputed = disputedAddend != 0;
        return (used, processType, disputed);
    }
}