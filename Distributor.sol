//SPDX-License-Identifier: MIT
pragma solidity 0.8.28;


interface IERC20 {

    function totalSupply() external view returns (uint256);
    
    function symbol() external view returns(string memory);
    
    function name() external view returns(string memory);

    /**
     * @dev Returns the amount of tokens owned by `account`.
     */
    function balanceOf(address account) external view returns (uint256);
    
    /**
     * @dev Returns the number of decimal places
     */
    function decimals() external view returns (uint8);

    /**
     * @dev Moves `amount` tokens from the caller's account to `recipient`.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transfer(address recipient, uint256 amount) external returns (bool);

    /**
     * @dev Returns the remaining number of tokens that `spender` will be
     * allowed to spend on behalf of `owner` through {transferFrom}. This is
     * zero by default.
     *
     * This value changes when {approve} or {transferFrom} are called.
     */
    function allowance(address owner, address spender) external view returns (uint256);

    /**
     * @dev Sets `amount` as the allowance of `spender` over the caller's tokens.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * IMPORTANT: Beware that changing an allowance with this method brings the risk
     * that someone may use both the old and the new allowance by unfortunate
     * transaction ordering. One possible solution to mitigate this race
     * condition is to first reduce the spender's allowance to 0 and set the
     * desired value afterwards:
     * https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
     *
     * Emits an {Approval} event.
     */
    function approve(address spender, uint256 amount) external returns (bool);

    /**
     * @dev Moves `amount` tokens from `sender` to `recipient` using the
     * allowance mechanism. `amount` is then deducted from the caller's
     * allowance.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);

    /**
     * @dev Emitted when `value` tokens are moved from one account (`from`) to
     * another (`to`).
     *
     * Note that `value` may be zero.
     */
    event Transfer(address indexed from, address indexed to, uint256 value);

    /**
     * @dev Emitted when the allowance of a `spender` for an `owner` is set by
     * a call to {approve}. `value` is the new allowance.
     */
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

/**
 * @title Owner
 * @dev Set & change owner
 */
contract Ownable {

    address private owner;
    
    // event for EVM logging
    event OwnerSet(address indexed oldOwner, address indexed newOwner);
    
    // modifier to check if caller is owner
    modifier onlyOwner() {
        // If the first argument of 'require' evaluates to 'false', execution terminates and all
        // changes to the state and to Ether balances are reverted.
        // This used to consume all gas in old EVM versions, but not anymore.
        // It is often a good idea to use 'require' to check if functions are called correctly.
        // As a second argument, you can also provide an explanation about what went wrong.
        require(msg.sender == owner, "Caller is not owner");
        _;
    }
    
    /**
     * @dev Set contract deployer as owner
     */
    constructor() {
        owner = msg.sender; // 'msg.sender' is sender of current call, contract deployer for a constructor
        emit OwnerSet(address(0), owner);
    }

    /**
     * @dev Change owner
     * @param newOwner address of new owner
     */
    function changeOwner(address newOwner) public onlyOwner {
        emit OwnerSet(owner, newOwner);
        owner = newOwner;
    }

    /**
     * @dev Return owner address 
     * @return address of owner
     */
    function getOwner() external view returns (address) {
        return owner;
    }
}

interface IRNG {
    function requestRandom() external returns (uint256 requestId); 
}

interface IPool {
    function getCurrentPot() external view returns (uint256);
    function distribute(address to) external;
}

/** Distributes And Tracks Reward Tokens for LightSpeed Holders based on weight */
contract Distributor is Ownable {
    
    // --- Constants & Immutables ---
    uint256 public constant TICKET_VALUE = 10_000 ether;

    // MAX_PARTICIPANTS_POW2: Max number of participant slots in the tree.
    // MUST be a power of 2 (e.g., 2^12=4096, 2^13=8192, 2^14=16384).
    // This choice balances capacity vs. gas cost for tree updates.
    uint256 public constant MAX_PARTICIPANTS_POW2 = 131072;

    address public immutable TOKEN_CONTRACT;

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

    mapping ( address => bool ) public isPool;

    mapping ( uint256 => address ) public requestToPool;

    uint256[] public freeLeafSlots; // Stack of previously used leaf slots that are now free
    uint256 public nextUnassignedLeafSlot = 1; // Counter for assigning new leaf slots, up to MAX_PARTICIPANTS_POW2

    // --- Exempt Addresses ---
    mapping(address => bool) public isExempt;
    
    bool public pause_while_fetching = true;
    bool public pause_all_updates = false; // To pause ticket updates during draw fulfillment

    // --- Events ---
    event ExemptAddressSet(address indexed addr, bool isExempt);
    event DrawRequested(uint256 indexed requestId);
    event WinnerSelected(address indexed winner, uint256 winningTicketNumberIndex, uint256 randomWord);
    event DrawFailed(uint256 indexed requestId, string reason);
    
    modifier onlyToken() {
        require(msg.sender == TOKEN_CONTRACT, 'Not Token'); 
        _;
    }

    constructor(
        address _tokenContractAddress,
        address _rng
    ) {
        // require(_maxParticipantsPow2 > 0 && (_maxParticipantsPow2 & (_maxParticipantsPow2 - 1)) == 0, "Max participants must be > 0 and a power of 2");
        // MAX_PARTICIPANTS_POW2 = _maxParticipantsPow2;
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

    function setPauseWhileFetching(bool _pause_while_fetching) external onlyOwner {
        pause_while_fetching = _pause_while_fetching;
    }

    function setRNG(address _rng) external onlyOwner {
        rng = IRNG(_rng);
    }

    function withdrawETH(address to, uint256 amount) external onlyOwner {
        (bool s,) = payable(to).call{value: amount}("");
        require(s);
    }

    function withdrawToken(address token, address to, uint256 amount) external onlyOwner {
        IERC20(token).transfer(to, amount);
    }

    function setIsPool(address pool, bool _isPool) external onlyOwner {
        isPool[pool] = _isPool;
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
            isPool[msg.sender],
            'Not Pool'
        );
        require(
            IPool(msg.sender).getCurrentPot() > 0,
            'No ETH To Win'
        );
        require(
            tree[1] > 0,
            "No tickets in lottery"
        );
        if (pause_while_fetching) {
            require(
                pause_all_updates == false,
                'Updates Currently Paused'
            );
        }        

        // request random, save ID
        uint256 requestId = rng.requestRandom();

        // map ID to pool
        requestToPool[requestId] = msg.sender;

        // pause all updates
        pause_all_updates = true;
    }

    function distribute(uint256 _requestId, uint256[] calldata randomWords) external {
        require(msg.sender == address(rng), 'Only RNG');
        address pool = requestToPool[_requestId];
        require(pool != address(0), 'No Pool');
    
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

        emit WinnerSelected(winnerAddress, winningTicketNumberIndex, randomWords[0]);

        // --- Distribute ETH Pot ---
        IPool(pool).distribute(winnerAddress);
        delete requestToPool[_requestId];

        pause_all_updates = false; // Re-enable ticket updates for the next round
    }


    ///////////////////////////////////////////////
    //////////    Internal Functions    ///////////
    ///////////////////////////////////////////////


    // --- Internal Ticket and Segment Tree Logic ---
    function _updateUserTickets(address _user, uint256 _currentBalance) internal {
        if (pause_while_fetching) {
            require(!pause_all_updates, "updates paused");
        }
        
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
            }
            // If newTicketCount is 0 and userSlot was 0, no tree update needed.
        } else { // User is already in a leaf slot
            if (newTicketCount == 0) { // User drops all tickets, free up their slot
                freeLeafSlots.push(userSlot);
                userToLeafSlot[_user] = 0; // Mark user as not having a slot
                leafSlotToUser[userSlot] = address(0); // Clear the slot
            }
            // If newTicketCount > 0 and user already in slot, slot remains the same.
        }

        // If user has/had a slot and there's a change in tickets, update the tree
        if (userSlot != 0 && ticketDelta != 0) {
            _updateSegmentTree(userSlot, ticketDelta);
        }
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
     
    ///////////////////////////////////////////////
    //////////      Read Functions      ///////////
    ///////////////////////////////////////////////

    function getTotalTickets() external view returns (uint256) {
        return tree[1];
    }

    receive() external payable {
        
    }

}
