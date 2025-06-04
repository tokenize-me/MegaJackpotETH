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

interface IWETH {
    function deposit() external payable;
    function transfer(address to, uint256 value) external returns (bool);
}

interface IPool {
    function getCurrentPot() external view returns (uint256);
    function distribute(address to) external;
    function timeLeft() external view returns (uint256);
    function triggerNextPayout() external;
}

interface IDistributor {
    function startDraw() external;
}

contract Pool is Ownable, IPool {

    // distributor that tracks logic
    address public distributor;

    // roll over percentage
    uint256 public remainingAfterRollOver;

    // duration until this pot is awarded
    uint256 public duration;

    // Total ETH collected for prizes, used for tracking purposes only
    uint256 public totalPrizes;

    // last time this was executed
    uint256 public lastTime;

    // WETH contract
    IWETH public constant WETH = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    struct Results {
        address winner;
        uint256 potWon;
    }

    Results[] public results;

    event EthPotDistributed(address indexed winner, uint256 amount);
    event DividendPaymentFailed(address indexed shareholder, uint256 amount);

    constructor(
        address _distributor, 
        uint256 _remainingAfterRollOver,
        uint256 _duration,
        uint256 _timeDelay
    ) {
        distributor = _distributor;
        remainingAfterRollOver = _remainingAfterRollOver;
        duration = _duration;
        lastTime = block.timestamp + _timeDelay;
    }

    function setRemainingAfterRollOver(uint256 newRemainder) external onlyOwner {
        require(newRemainder <= 100 && newRemainder > 0, 'Invalid Roll Over');
        remainingAfterRollOver = newRemainder;
    }

    function setDistributor(address newDistro) external onlyOwner {
        distributor = newDistro;
    }

    function setDuration(uint256 newDuration) external onlyOwner {
        duration = newDuration;
    }

    function withdrawETH(address to, uint256 amount) external onlyOwner {
        (bool s,) = payable(to).call{value: amount}("");
        require(s);
    }

    function withdrawToken(address token, address to, uint256 amount) external onlyOwner {
        IERC20(token).transfer(to, amount);
    }

    function triggerNextPayout() external override {
        require(
            lastTime + duration <= block.timestamp,
            'Invalid Time'
        );

        // reset last time
        lastTime = block.timestamp;

        // trigger distributor to start draw
        IDistributor(distributor).startDraw();
    }

    function distribute(address to) external override {
        require(msg.sender == distributor, 'Only Distributor');

        uint256 winAmount = ( address(this).balance * remainingAfterRollOver ) / 100;
        if (isContract(to)) {
            WETH.deposit{value: winAmount}();
            WETH.transfer(to, winAmount);
            emit EthPotDistributed(to, winAmount);
        } else {
            (bool s,) = payable(to).call{value: winAmount}("");
            if (!s) {
                emit DividendPaymentFailed(to, winAmount);
            } else {
                emit EthPotDistributed(to, winAmount);
            }
        }

        results.push(Results({
            winner: to,
            potWon: winAmount
        }));
    }

    function timeLeft() external view override returns (uint256) {
        uint nextTime = lastTime + duration;
        return nextTime > block.timestamp ? nextTime - block.timestamp : 0;
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

    function getCurrentPot() external view override returns (uint256) {
        return ( address(this).balance * remainingAfterRollOver ) / 100;
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

    receive() external payable {
        unchecked {
            totalPrizes += msg.value;
        }
    }
}