// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/vrf/VRFConsumerBaseV2.sol";
// It's good practice to use an interface for your token
interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
}

contract LotteryDistributor is Ownable, VRFConsumerBaseV2 {

    // --- Constants & Immutables ---
    uint256 public immutable TICKET_VALUE = 10000;

    // MAX_PARTICIPANTS_POW2: Max number of participant slots in the tree.
    // MUST be a power of 2 (e.g., 2^12=4096, 2^13=8192, 2^14=16384).
    // This choice balances capacity vs. gas cost for tree updates.
    uint256 public immutable MAX_PARTICIPANTS_POW2;

    address public immutable TOKEN_CONTRACT;

    // Chainlink VRF v2 Variables
    VRFCoordinatorV2Interface immutable VRF_COORDINATOR;
    uint64 immutable VRF_SUBSCRIPTION_ID;
    bytes32 immutable VRF_KEYHASH;
    uint32 constant VRF_CALLBACK_GAS_LIMIT = 2500000; // Adjust based on testing
    uint16 constant VRF_REQUEST_CONFIRMATIONS = 3;   // Mainnet reasonable value
    uint32 constant VRF_NUM_WORDS = 1;               // We need one random number

    // --- Segment Tree Data ---
    // Stores sum of tickets for each conceptual node. Root is at index 1.
    // Leaves for MAX_PARTICIPANTS_POW2 participants start at index MAX_PARTICIPANTS_POW2.
    mapping(uint256 => uint256) public tree;

    // --- Participant Management ---
    mapping(address => uint256) public ticketsOf;      // User address => their current ticket count
    mapping(address => uint256) public userToLeafSlot; // User address => their assigned leaf slot (1 to MAX_PARTICIPANTS_POW2)
                                                      // 0 if not an active participant with a slot.
    mapping(uint256 => address) public leafSlotToUser; // Leaf slot (1 to MAX_PARTICIPANTS_POW2) => user address

    uint256[] public freeLeafSlots; // Stack of previously used leaf slots that are now free
    uint256 public nextUnassignedLeafSlot = 1; // Counter for assigning new leaf slots, up to MAX_PARTICIPANTS_POW2

    // --- Exempt Addresses ---
    mapping(address => bool) public isExempt;

    // --- Lottery State ---
    uint256 public s_lastRequestId;
    uint256 public s_lastRandomWord; // The random number from VRF
    address public s_lastWinner;
    bool public s_lotteryUpdatesPaused = false; // To pause ticket updates during draw fulfillment

    // --- Events ---
    event TicketsUpdated(address indexed user, uint256 newTicketCount, int256 ticketDelta);
    event ParticipantSlotAssigned(address indexed user, uint256 leafSlot);
    event ParticipantSlotFreed(address indexed user, uint256 leafSlot);
    event ExemptAddressSet(address indexed addr, bool isExempt);
    event DrawRequested(uint256 indexed requestId);
    event WinnerSelected(uint256 indexed requestId, address indexed winner, uint256 winningTicketNumberIndex);
    event DrawFailed(uint256 indexed requestId, string reason);
    event EthPotDistributed(address indexed winner, uint256 amount);


    constructor(
        address _tokenContractAddress,
        uint256 _maxParticipantsPow2,
        address _vrfCoordinatorAddress,
        uint64 _vrfSubscriptionId,
        bytes32 _vrfKeyHash
    ) VRFConsumerBaseV2(_vrfCoordinatorAddress) Ownable(msg.sender) {
        require(_maxParticipantsPow2 > 0 && (_maxParticipantsPow2 & (_maxParticipantsPow2 - 1)) == 0, "Max participants must be > 0 and a power of 2");
        MAX_PARTICIPANTS_POW2 = _maxParticipantsPow2;
        TOKEN_CONTRACT = _tokenContractAddress;

        VRF_COORDINATOR = VRFCoordinatorV2Interface(_vrfCoordinatorAddress);
        VRF_SUBSCRIPTION_ID = _vrfSubscriptionId;
        VRF_KEYHASH = _vrfKeyHash;

        // Initialize some exempt addresses if known at deployment (e.g., token contract itself if it holds tokens)
        // isExempt[address(this)] = true;
        // isExempt[_tokenContractAddress] = true;
    }

    // --- Owner-Only Functions ---
    function setExemptAddress(address _addr, bool _isExemptVal) public onlyOwner {
        bool oldExemptStatus = isExempt[_addr];
        isExempt[_addr] = _isExemptVal;
        emit ExemptAddressSet(_addr, _isExemptVal);

        // If status changed, trigger a ticket recount for this user.
        // This ensures their tickets are added/removed from the lottery.
        if (oldExemptStatus != _isExemptVal) {
            uint256 currentBalance = IERC20Minimal(TOKEN_CONTRACT).balanceOf(_addr);
            _updateUserTickets(_addr, currentBalance);
        }
    }

    function setLotteryUpdatesPaused(bool _paused) public onlyOwner {
        s_lotteryUpdatesPaused = _paused;
    }

    function withdrawLinkBalance() public onlyOwner {
        // If contract holds LINK for VRF fees and has excess
        // LINK.transfer(owner(), LINK.balanceOf(address(this)));
    }

    function withdrawEthPot(address payable _recipient) public onlyOwner {
        // Allows owner to withdraw ETH from the contract if needed (e.g., for manual distribution or other reasons)
        // This is separate from automatic winner payout.
        uint256 balance = address(this).balance;
        require(balance > 0, "No ETH to withdraw");
        (bool success, ) = _recipient.call{value: balance}("");
        require(success, "ETH withdrawal failed");
    }


    // --- Public Function to Update User Tickets ---
    // This should be called by your token contract's _afterTokenTransfer hook for sender and receiver,
    // or by a trusted backend/keeper that monitors balances.
    // For simplicity, making it public but ideally, it needs permissioning.
    function updateUserBalance(address _user, uint256 _newBalance) public {
        // Add permissions: e.g., require(msg.sender == TOKEN_CONTRACT || msg.sender == owner());
        _updateUserTickets(_user, _newBalance);
    }

    // --- Internal Ticket and Segment Tree Logic ---
    function _updateUserTickets(address _user, uint256 _currentBalance) internal {
        require(!s_lotteryUpdatesPaused, "Lottery updates paused");

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
                    userSlot = freeLeafSlots.pop();
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


    // --- Chainlink VRF Functions ---
    function requestRandomnessForDraw() public onlyOwner returns (uint256 requestId) {
        require(!s_lotteryUpdatesPaused, "Lottery updates must be enabled to start a draw");
        require(VRF_SUBSCRIPTION_ID != 0, "VRF Subscription not configured");
        // Add check for LINK balance if your subscription isn't pre-funded

        s_lotteryUpdatesPaused = true; // Pause ticket updates
        requestId = VRF_COORDINATOR.requestRandomWords(
            VRF_KEYHASH,
            VRF_SUBSCRIPTION_ID,
            VRF_REQUEST_CONFIRMATIONS,
            VRF_CALLBACK_GAS_LIMIT,
            VRF_NUM_WORDS
        );
        s_lastRequestId = requestId;
        emit DrawRequested(requestId);
        return requestId;
    }

    function fulfillRandomWords(uint256 _requestId, uint256[] memory _randomWords) internal override {
        require(s_lastRequestId == _requestId, "Invalid request ID");
        s_lastRandomWord = _randomWords[0];

        uint256 totalCurrentTickets = tree[1]; // Get total tickets from segment tree root

        if (totalCurrentTickets == 0) {
            emit DrawFailed(_requestId, "No tickets in the lottery at draw time");
            s_lotteryUpdatesPaused = false; // Re-enable updates
            return;
        }

        uint256 winningTicketNumberIndex = s_lastRandomWord % totalCurrentTickets; // 0-indexed ticket
        uint256 winnerLeafSlotId = _queryWinnerLeafSlotId(winningTicketNumberIndex);
        address winnerAddress = leafSlotToUser[winnerLeafSlotId];

        if (winnerAddress == address(0)) {
            // This implies an empty slot won, or an error in slot management/query
            emit DrawFailed(_requestId, "Selected winner slot is empty or invalid");
            s_lotteryUpdatesPaused = false; // Re-enable updates
            return;
        }
        if (ticketsOf[winnerAddress] == 0) {
            // Winner's tickets became 0 just before this, or other inconsistency
            emit DrawFailed(_requestId, "Selected winner has zero tickets currently");
            s_lotteryUpdatesPaused = false;
            return;
        }


        s_lastWinner = winnerAddress;
        emit WinnerSelected(_requestId, winnerAddress, winningTicketNumberIndex);

        // --- Distribute ETH Pot ---
        uint256 potAmount = address(this).balance;
        if (potAmount > 0) {
            (bool success, ) = payable(winnerAddress).call{value: potAmount}("");
            if (success) {
                emit EthPotDistributed(winnerAddress, potAmount);
            } else {
                // Handle failed transfer, e.g., emit event, allow winner to claim later, or owner to retry
                // For now, we'll assume it can fail and the funds remain for owner withdrawal or retry
            }
        }
        s_lotteryUpdatesPaused = false; // Re-enable ticket updates for the next round
    }

    // --- ETH Pot Management ---
    receive() external payable {
        // Allows the contract to receive ETH for the lottery pot
    }

    // --- View Functions (for convenience and off-chain tools) ---
    function getLotteryTotalTickets() public view returns (uint256) {
        return tree[1]; // Root of the segment tree
    }

    function getParticipantTickets(address _user) public view returns (uint256) {
        return ticketsOf[_user];
    }

    function getParticipantSlot(address _user) public view returns (uint256) {
        return userToLeafSlot[_user];
    }

    function getSlotUser(uint256 _slotId) public view returns (address) {
        require(_slotId > 0 && _slotId <= MAX_PARTICIPANTS_POW2, "Invalid slot ID");
        return leafSlotToUser[_slotId];
    }

    function getTreeNodeSum(uint256 _treeNodeIndex) public view returns (uint256) {
        // Allow querying any node in the tree, e.g., for debugging.
        // Note: treeNodeIndex must be >= 1 and < 2 * MAX_PARTICIPANTS_POW2
        require(_treeNodeIndex > 0 && _treeNodeIndex < (MAX_PARTICIPANTS_POW2 * 2), "Invalid tree node index");
        return tree[_treeNodeIndex];
    }
}