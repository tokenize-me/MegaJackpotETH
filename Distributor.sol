//SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./IERC20.sol";
import "./ReentrantGuard.sol";
import "./Ownable.sol";

interface ISwapper {
    function swap(
        address token,
        address recipient,
        uint8 buyTax,
        uint256 minOut
    ) external payable;
}

interface IWETH {
    function deposit() external payable;
    function transfer(address to, uint256 value) external returns (bool);
}

interface IDistributor {
    function distribute(uint256[] calldata randomWords) external;
}

/** Distributes And Tracks Reward Tokens for LightSpeed Holders based on weight */
contract Distributor is Ownable, ReentrancyGuard {
    
    // Token Contract
    address public immutable _token;

    // WETH contract
    IWETH public constant WETH = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    
    // Share of Token
    struct Share {
        uint256 numShares;
        bool isRewardExempt;
    }
    
    // shareholder fields
    address[] public shareholders;
    mapping (address => uint256) private shareholderIndexes;
    mapping (address => uint256) public totalClaimedByUser;
    mapping (address => Share) public shares;
    
    // shares math and fields
    uint256 public totalShares;
    uint256 public totalDividends;
    uint256 public dividendsPerShare;
    uint256 constant dividendsPerShareAccuracyFactor = 10 ** 18;

    uint256 public constant TICKET_SIZE = 10_000 ether;

    uint256 public currentIndex;

    event DividendPaymentFailed(address indexed shareholder, uint256 amount);
    
    modifier onlyToken() {
        require(msg.sender == _token, 'Not Token'); 
        _;
    }

    constructor (address token) {
        _token = token;
    }
    
    ///////////////////////////////////////////////
    //////////      Only Token Owner    ///////////
    ///////////////////////////////////////////////

    function setRewardExempt(address shareholder, bool exempt) external onlyOwner {
        shares[shareholder].isRewardExempt = exempt;
        if (exempt) {
            if (shares[shareholder].numShares > 0) {
                // if the shareholder is exempt, we do not need to track their shares
                totalShares -= shares[shareholder].numShares;
                shares[shareholder].numShares = 0;
                removeShareholder(shareholder);
            }
        }
    }

    ///////////////////////////////////////////////
    //////////    Only Token Contract   ///////////
    ///////////////////////////////////////////////
    
    /** Sets Share For User */
    function setShare(address shareholder, uint256 amount) external onlyToken {
        if (shares[shareholder].isRewardExempt) {
            // if the shareholder is exempt, we do not need to track their shares
            return;
        }

        if (amount < TICKET_SIZE && shares[shareholder].numShares == 0) {
            // holder change, not above minimum, do nothing
            return;
        }

        if (amount >= TICKET_SIZE && shares[shareholder].numShares > 0) {

            uint256 newShares = amount / TICKET_SIZE;
            uint256 oldShares = shares[shareholder].numShares;

            // share holder is already holding enough shares, update the total
            totalShares = ( totalShares + newShares ) - oldShares;
            shares[shareholder].numShares = newShares;
            return;
        }

        if( amount >= TICKET_SIZE && shares[shareholder].numShares == 0){

            uint256 newShares = amount / TICKET_SIZE;
            
            unchecked {
                totalShares += newShares;
            }
            shares[shareholder].numShares = newShares;
            addShareholder(shareholder, newShares);

        } else if(amount < TICKET_SIZE && shares[shareholder].numShares > 0){

            totalShares -= shares[shareholder].numShares;
            shares[shareholder].numShares = 0;
            removeShareholder(shareholder);

        }
    }


    ///////////////////////////////////////////////
    //////////    Internal Functions    ///////////
    ///////////////////////////////////////////////


    function addTickets(address user, uint256 numTickets) internal {

        
    }

    function addShareholder(address shareholder) internal {
        uint index = shareholderIndexes[shareholder];
        if (index < shareholders.length) {
            if (shareholders[index] == shareholder) {
                return; // Shareholder already exists
            }
        }

        shareholderIndexes[shareholder] = shareholders.length;
        shareholders.push(shareholder);
    }

    function removeShareholder(address shareholder) internal { 
        uint index = shareholderIndexes[shareholder];
        if (index < shareholders.length) {
            if (shareholders[index] != shareholder) {
                return; // Shareholder already exists
            }
        }

        shareholders[shareholderIndexes[shareholder]] = shareholders[shareholders.length-1];
        shareholderIndexes[shareholders[shareholders.length-1]] = shareholderIndexes[shareholder]; 
        shareholders.pop();
        delete shareholderIndexes[shareholder];
    }

    function _distribute(address user) internal {
        if (isContract(user)) {
            WETH.deposit{value: msg.value}();
            WETH.transfer(user, msg.value);
        } else {
            (bool s,) = payable(user).call{value: msg.value}("");
            if (!s) {
                emit DividendPaymentFailed(user, msg.value);
            }
        }
    }
     
    ///////////////////////////////////////////////
    //////////      Read Functions      ///////////
    ///////////////////////////////////////////////
    
    function getShareholders() external view returns (address[] memory) {
        return shareholders;
    }
    
    function getShareForHolder(address holder) external view returns(uint256) {
        return shares[holder].amount;
    }

    function getCumulativeDividends(uint256 share) internal view returns (uint256) {
        return ( share * dividendsPerShare ) / dividendsPerShareAccuracyFactor;
    }
    
    function getNumShareholders() external view returns(uint256) {
        return shareholders.length;
    }

    function paginateShareholders(uint256 start, uint256 end) external view returns (address[] memory) {
        if (end > shareholders.length) {
            end = shareholders.length;
        }
        address[] memory paginatedShareholders = new address[](end - start);
        for (uint256 i = start; i < end; i++) {
            paginatedShareholders[i - start] = shareholders[i];
        }
        return paginatedShareholders;
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
        // update main dividends
        totalDividends += msg.value;
        dividendsPerShare += ( msg.value * dividendsPerShareAccuracyFactor ) / totalShares;
    }

}
