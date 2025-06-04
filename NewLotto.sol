//SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./IERC20.sol";
import "./Ownable.sol";

interface IWETH {
    function deposit() external payable;
    function transfer(address to, uint256 value) external returns (bool);
}

interface IRNG {
    function requestRandom() external returns (uint256 requestId); 
}

/** Distributes And Tracks Reward Tokens for LightSpeed Holders based on weight */
contract Distributor is Ownable {
    
    // --- Constants & Immutables ---
    uint256 public constant TICKET_VALUE = 25_000 ether;

    // MAX_PARTICIPANTS_POW2: Max number of participant slots in the tree.
    // MUST be a power of 2 (e.g., 2^12=4096, 2^13=8192, 2^14=16384).
    // This choice balances capacity vs. gas cost for tree updates.
    uint256 public immutable MAX_PARTICIPANTS_POW2;

    address public immutable TOKEN_CONTRACT;

    // WETH contract
    IWETH public constant WETH = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    // RNG Contract
    IRNG public rng;

    // --- Segment Tree Data ---
    // Stores sum of tickets for each conceptual node. Root is at index 1.
    // Leaves for MAX_PARTICIPANTS_POW2 participants start at index MAX_PARTICIPANTS_POW2.
    mapping(uint256 => uint256) public tree;

    // --- Participant Management ---
    mapping(address => uint256) public ticketsOf;      // User address => their current ticket count
    mapping(address => uint256) public userToLeafSlot; // User address => their assigned leaf slot (1 to MAX_PARTICIPANTS_POW2)
                                                      // 0 if not an active participant with a slot.
    mapping(uint256 => address) public leafSlotToUser; // Leaf slot (1 to MAX_PARTICIPANTS_POW2) => user address

    mapping ( address => bool ) public canStartDraw; // will be an automation contract which starts draws based on time

    uint256[] public freeLeafSlots; // Stack of previously used leaf slots that are now free
    uint256 public nextUnassignedLeafSlot = 1; // Counter for assigning new leaf slots, up to MAX_PARTICIPANTS_POW2

    // --- Exempt Addresses ---
    mapping(address => bool) public isExempt;

    // --- Lottery State ---
    uint256 internal s_lastRequestId;

    struct Results {
        address winner;
        uint256 potWon;
        uint256 randomWord;
    }
    Results[] public results;
    
    bool public pause_all_updates = false; // To pause ticket updates during draw fulfillment

    uint256 public rollOver = 90; // 10% of lotto is rolled over to next pot

    uint256 public totalPrizes;

    // --- Events ---
    event TicketsUpdated(address indexed user, uint256 newTicketCount, int256 ticketDelta);
    event ParticipantSlotAssigned(address indexed user, uint256 leafSlot);
    event ParticipantSlotFreed(address indexed user, uint256 leafSlot);
    event ExemptAddressSet(address indexed addr, bool isExempt);
    event DrawRequested(uint256 indexed requestId);
    event WinnerSelected(uint256 indexed requestId, address indexed winner, uint256 winningTicketNumberIndex);
    event DrawFailed(uint256 indexed requestId, string reason);
    event EthPotDistributed(address indexed winner, uint256 amount);
    event DividendPaymentFailed(address indexed shareholder, uint256 amount);
    
    modifier onlyToken() {
        require(msg.sender == TOKEN_CONTRACT, 'Not Token'); 
        _;
    }

    constructor(
        address _tokenContractAddress,
        uint256 _maxParticipantsPow2,
        address _rng
    ) {
        require(_maxParticipantsPow2 > 0 && (_maxParticipantsPow2 & (_maxParticipantsPow2 - 1)) == 0, "Max participants must be > 0 and a power of 2");
        MAX_PARTICIPANTS_POW2 = _maxParticipantsPow2;
        TOKEN_CONTRACT = _tokenContractAddress;

        // Initialize some exempt addresses if known at deployment (e.g., token contract itself if it holds tokens)
        isExempt[address(this)] = true;
        isExempt[_tokenContractAddress] = true;
        rng = IRNG(_rng);
    }
    
    ///////////////////////////////////////////////
    //////////      Only Token Owner    ///////////
    ///////////////////////////////////////////////

    // --- Owner-Only Functions ---
    function setExemptAddress(address _addr, bool _isExemptVal) external onlyOwner {
        bool oldExemptStatus = isExempt[_addr];
        isExempt[_addr] = _isExemptVal;
        emit ExemptAddressSet(_addr, _isExemptVal);

        // If status changed, trigger a ticket recount for this user.
        // This ensures their tickets are added/removed from the lottery.
        if (oldExemptStatus != _isExemptVal) {
            uint256 currentBalance = IERC20(TOKEN_CONTRACT).balanceOf(_addr);
            _updateUserTickets(_addr, currentBalance);
        }
    }

    function setPauseAllUpdates(bool _paused) external onlyOwner {
        pause_all_updates = _paused;
    }

    function setRNG(address _rng) external onlyOwner {
        rng = IRNG(_rng);
    }

    function withdrawETH(address to, uint256 amount) external onlyOwner {
        (bool s,) = payable(to).call{value: amount}("");
        require(s);
    }

    function setCanStartDraw(address user, bool canStart) external onlyOwner {
        canStartDraw[user] = canStart;
    }

    function setRollOver(uint256 newRollOver) external onlyOwner {
        require(newRollOver <= 100 && newRollOver > 0, 'Invalid Roll Over');
        rollOver = newRollOver;
    }

    ///////////////////////////////////////////////
    //////////    Only Token Contract   ///////////
    ///////////////////////////////////////////////
    
    /** Sets Share For User, only callable by token contract */
    function setShare(address user, uint256 amount) external onlyToken {
        _updateUserTickets(user, amount);
    }

    /** Requests random number for draw */
    function startDraw() external {
        require(
            canStartDraw[msg.sender],
            'Not Authorized'
        );
        require(
            address(this).balance > 0,
            'No ETH To Win'
        );
        require(
            tree[1] > 0,
            "No tickets in lottery"
        );

        s_lastRequestId = rng.requestRandom();
        pause_all_updates = true;
    }

    function distribute(uint256 _requestId, uint256[] calldata randomWords) external {
        require(msg.sender == address(rng), 'Only RNG');
        require(s_lastRequestId == _requestId, "Invalid request ID");
        uint256 totalCurrentTickets = tree[1]; // Get total tickets from segment tree root

        if (totalCurrentTickets == 0) {
            emit DrawFailed(_requestId, "No tickets in the lottery at draw time");
            pause_all_updates = false; // Re-enable updates
            return;
        }

        uint256 winningTicketNumberIndex = randomWords[0] % totalCurrentTickets; // 0-indexed ticket
        uint256 winnerLeafSlotId = _queryWinnerLeafSlotId(winningTicketNumberIndex);
        address winnerAddress = leafSlotToUser[winnerLeafSlotId];

        if (winnerAddress == address(0)) {
            // This implies an empty slot won, or an error in slot management/query
            emit DrawFailed(_requestId, "Selected winner slot is empty or invalid");
            pause_all_updates = false; // Re-enable updates
            return;
        }
        if (ticketsOf[winnerAddress] == 0) {
            // Winner's tickets became 0 just before this, or other inconsistency
            emit DrawFailed(_requestId, "Selected winner has zero tickets currently");
            pause_all_updates = false;
            return;
        }

        results.push(Results({
            winner: winnerAddress,
            potWon: ( address(this).balance * rollOver ) / 100,
            randomWord: randomWords[0]
        }));

        emit WinnerSelected(_requestId, winnerAddress, winningTicketNumberIndex);

        // --- Distribute ETH Pot ---
        _distribute(winnerAddress);
        pause_all_updates = false; // Re-enable ticket updates for the next round
    }


    ///////////////////////////////////////////////
    //////////    Internal Functions    ///////////
    ///////////////////////////////////////////////


    // --- Internal Ticket and Segment Tree Logic ---
    function _updateUserTickets(address _user, uint256 _currentBalance) internal {
        require(!pause_all_updates, "Lottery updates paused");

        uint256 oldTicketCount = ticketsOf[_user];
        uint256 newTicketCount;

        if (isExempt[_user]) {
            newTicketCount = 0;
        } else {
            newTicketCount = _currentBalance / TICKET_VALUE;
        }

        if (newTicketCount == oldTicketCount) {
            return; // No change needed
        }

        ticketsOf[_user] = newTicketCount;
        int256 ticketDelta = int256(newTicketCount) - int256(oldTicketCount);

        uint256 userSlot = userToLeafSlot[_user];

        if (userSlot == 0) { // User is not currently in a leaf slot
            if (newTicketCount > 0) { // User gains tickets and needs a slot
                if (freeLeafSlots.length > 0) {
                    userSlot = freeLeafSlots[freeLeafSlots.length - 1];
                    freeLeafSlots.pop();
                } else {
                    require(nextUnassignedLeafSlot <= MAX_PARTICIPANTS_POW2, "Max participant slots reached");
                    userSlot = nextUnassignedLeafSlot;
                    nextUnassignedLeafSlot++;
                }
                userToLeafSlot[_user] = userSlot;
                leafSlotToUser[userSlot] = _user;
                emit ParticipantSlotAssigned(_user, userSlot);
            }
            // If newTicketCount is 0 and userSlot was 0, no tree update needed.
        } else { // User is already in a leaf slot
            if (newTicketCount == 0) { // User drops all tickets, free up their slot
                freeLeafSlots.push(userSlot);
                userToLeafSlot[_user] = 0; // Mark user as not having a slot
                leafSlotToUser[userSlot] = address(0); // Clear the slot
                emit ParticipantSlotFreed(_user, userSlot);
            }
            // If newTicketCount > 0 and user already in slot, slot remains the same.
        }

        // If user has/had a slot and there's a change in tickets, update the tree
        if (userSlot != 0 && ticketDelta != 0) {
            _updateSegmentTree(userSlot, ticketDelta);
        }
        emit TicketsUpdated(_user, newTicketCount, ticketDelta);
    }

    function _updateSegmentTree(uint256 _leafSlotId, int256 _ticketDelta) internal {
        // _leafSlotId is 1-indexed, from 1 to MAX_PARTICIPANTS_POW2
        require(_leafSlotId > 0 && _leafSlotId <= MAX_PARTICIPANTS_POW2, "Invalid leaf slot ID");

        // Calculate the actual index in the conceptual tree array (where leaves start after internal nodes)
        // For a 1-indexed tree, leaves start at tree_array_index = MAX_PARTICIPANTS_POW2 + leafSlotId - 1
        uint256 treeNodeIndex = MAX_PARTICIPANTS_POW2 + _leafSlotId - 1;

        // Apply delta to the leaf node
        if (_ticketDelta > 0) {
            tree[treeNodeIndex] = tree[treeNodeIndex] + uint256(_ticketDelta);
        } else {
            uint256 absDelta = uint256(-_ticketDelta);
            require(tree[treeNodeIndex] >= absDelta, "Tree underflow at leaf");
            tree[treeNodeIndex] = tree[treeNodeIndex] - absDelta;
        }

        // Propagate delta up to the root (node 1)
        while (treeNodeIndex > 1) {
            treeNodeIndex = treeNodeIndex / 2; // Move to parent
            if (_ticketDelta > 0) {
                tree[treeNodeIndex] = tree[treeNodeIndex] + uint256(_ticketDelta);
            } else {
                uint256 absDelta = uint256(-_ticketDelta);
                require(tree[treeNodeIndex] >= absDelta, "Tree underflow at internal node");
                tree[treeNodeIndex] = tree[treeNodeIndex] - absDelta;
            }
        }
    }

    function _queryWinnerLeafSlotId(uint256 _targetTicketNumIndex) internal view returns (uint256) {
        uint256 totalTicketsInLottery = tree[1]; // Root node has total sum
        require(totalTicketsInLottery > 0, "No tickets in lottery");
        require(_targetTicketNumIndex < totalTicketsInLottery, "Target ticket index out of bounds");

        uint256 treeNodeIndex = 1; // Start at the root

        // Traverse down until we reach a conceptual leaf node range
        // In our 1-indexed tree mapping where leaves start at MAX_PARTICIPANTS_POW2:
        // A node is an internal node if treeNodeIndex < MAX_PARTICIPANTS_POW2
        while (treeNodeIndex < MAX_PARTICIPANTS_POW2) {
            uint256 leftChildTreeIndex = treeNodeIndex * 2;
            uint256 ticketsInLeftChild = tree[leftChildTreeIndex];

            if (_targetTicketNumIndex < ticketsInLeftChild) {
                treeNodeIndex = leftChildTreeIndex; // Go left
            } else {
                _targetTicketNumIndex -= ticketsInLeftChild; // Adjust for right subtree
                treeNodeIndex = leftChildTreeIndex + 1;   // Go right
            }
        }

        // treeNodeIndex is now the index in the `tree` mapping corresponding to the winning leaf's node
        // Convert it back to the 1-based _leafSlotId
        return treeNodeIndex - MAX_PARTICIPANTS_POW2 + 1;
    }


    function _distribute(address user) internal {
        uint256 winAmount = ( address(this).balance * rollOver ) / 100;
        if (isContract(user)) {
            WETH.deposit{value: winAmount}();
            WETH.transfer(user, winAmount);
        } else {
            (bool s,) = payable(user).call{value: winAmount}("");
            if (!s) {
                emit DividendPaymentFailed(user, winAmount);
            } else {
                emit EthPotDistributed(user, winAmount);
            }
        }
    }
     
    ///////////////////////////////////////////////
    //////////      Read Functions      ///////////
    ///////////////////////////////////////////////

    function getTotalTickets() external view returns (uint256) {
        return tree[1];
    }

    function getNumResults() external view returns (uint256) {
        return results.length;
    }

    function getResults(uint256 start, uint256 end) external view returns (Results[] memory memResults) {
        if (end > results.length) {
            end = results.length;
        }
        memResults = new Results[](end - start);
        for (uint i = start; i < end; i++) {
            memResults[i - start] = results[i];
        }
    }

    function getCurrentPot() external view returns (uint256) {
        return ( address(this).balance * rollOver ) / 100;
    }

    function isContract(address account) internal view returns (bool) {
        // According to EIP-1052, 0x0 is the value returned for not-yet created accounts
        // and 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470 is returned
        // for accounts without code, i.e. `keccak256('')`
        bytes32 codehash;
        bytes32 accountHash = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;
        // solhint-disable-next-line no-inline-assembly
        assembly { codehash := extcodehash(account) }
        return (codehash != accountHash && codehash != 0x0);
    }

    receive() external payable {
        unchecked {
            totalPrizes += msg.value;
        }
    }

}
