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

/** Distributes And Tracks Reward Tokens for LightSpeed Holders based on weight */
contract Distributor is Ownable, ReentrancyGuard {
    
    // Token Contract
    address public immutable _token;

    // WETH contract
    IWETH public constant WETH = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    
    // Share of Token
    struct Share {
        uint256 amount;
        uint256 totalExcluded;
        address rewardToken;
        bool isRewardExempt;
        bool canBatchRewards;
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

    uint256 public minHolding = 10_000 ether;

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

    function setMinHolding(uint256 amount) external onlyOwner {
        minHolding = amount;
    }

    function setMinDistribution(uint256 amount) external onlyOwner {
        minDistribution = amount;
    }

    function setCanPublicDistribute(bool canDistribute) external onlyOwner {
        canPublicDistribute = canDistribute;
    }

    function setRewardExempt(address shareholder, bool exempt) external onlyOwner {
        shares[shareholder].isRewardExempt = exempt;
        if (exempt) {
            if (shares[shareholder].amount > 0) {
                // if the shareholder is exempt, we do not need to track their shares
                totalShares -= shares[shareholder].amount;
                shares[shareholder].amount = 0;
                shares[shareholder].totalExcluded = 0;
                removeShareholder(shareholder);
            }
        }
    }

    function setCanBatchRewards(address shareholder, bool canBatch) external onlyOwner {
        shares[shareholder].canBatchRewards = canBatch;
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

        if(shares[shareholder].amount >= minHolding){
            distributeDividend(shareholder, 0);
        }

        if (amount < minHolding && shares[shareholder].amount == 0) {
            // holder change, not above minimum, do nothing
            return;
        }

        if (amount >= minHolding && shares[shareholder].amount >= minHolding) {
            // share holder is already holding enough shares, update the total
            totalShares = ( totalShares + amount ) - shares[shareholder].amount;
            shares[shareholder].amount = amount;
            shares[shareholder].totalExcluded = getCumulativeDividends(shares[shareholder].amount);
            return;
        }

        if( amount >= minHolding && shares[shareholder].amount == 0){

            addShareholder(shareholder);
            totalShares += amount;
            shares[shareholder].amount = amount;
            shares[shareholder].totalExcluded = getCumulativeDividends(shares[shareholder].amount);

        } else if(amount < minHolding && shares[shareholder].amount > 0){

            removeShareholder(shareholder);
            totalShares -= shares[shareholder].amount;
            shares[shareholder].amount = 0;
            shares[shareholder].totalExcluded = 0;

        }
    }
    
    ///////////////////////////////////////////////
    //////////      Public Functions    ///////////
    ///////////////////////////////////////////////

    function setRewardToken(address token) external {
        require(rewardTokens[token].isApproved || token == address(0), 'Token Not Approved');
        require(shares[msg.sender].amount >= minHolding, 'Sender Balance Too Small');
        shares[msg.sender].rewardToken = token;
    }
    
    function claim(uint256 minOut) external {
        distributeDividend(msg.sender, minOut);
    }

    function batchClaim(address[] calldata users, uint256[] calldata minOuts) external {
        require(shares[msg.sender].canBatchRewards || canPublicDistribute, 'Batch Rewards Not Allowed');
        uint len = users.length;
        for (uint256 i = 0; i < len;) {
            address user = users[i];
            uint256 minOut = minOuts[i];
            if (shouldDistribute(user)) {
                distributeDividend(user, minOut);
            }
            unchecked { ++i; }
        }
    }

    function iterate(uint256 iterations) external {
        require(shares[msg.sender].canBatchRewards || canPublicDistribute, 'Batch Rewards Not Allowed');
        uint256 len = shareholders.length;
        for (uint256 i = 0; i < iterations;) {
            if (currentIndex >= len) {
                currentIndex = 0; // Reset index if it exceeds the length
            }

            address shareholder = shareholders[currentIndex];
            if (shouldDistribute(shareholder)) {
                distributeDividend(shareholder, 0);
            }
            unchecked { ++currentIndex; }
            unchecked { ++i; }
        }
    }

    ///////////////////////////////////////////////
    //////////    Internal Functions    ///////////
    ///////////////////////////////////////////////

    function addShareholder(address shareholder) internal {
        uint index = shareholderIndexes[shareholder];
        if (index < shareholders.length) {
            if (shareholders[index] == shareholder) {
                return; // Shareholder already exists
            }
        }

        shareholderIndexes[shareholder] = shareholders.length;
        shareholders.push(shareholder);
        emit AddedShareholder(shareholder);
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
        emit RemovedShareholder(shareholder);
    }
    
    function distributeDividend(address shareholder, uint256 minOut) internal nonReentrant {
        if(shares[shareholder].amount < minHolding ){ return; }
        
        uint256 amount = pendingRewards(shareholder);
        if(amount > 0){
            
            address token = shares[shareholder].rewardToken;
            unchecked {
                totalClaimedByUser[shareholder] += amount;
            }

            if (token == address(0)) {
                if (isContract(shareholder)) {
                    // if the shareholder is a contract, we cannot send ETH directly, wrap eth into WETH and send
                    WETH.deposit{value: amount}();
                    WETH.transfer(shareholder, amount);
                } else {
                    (bool s,) = payable(shareholder).call{value: amount}("");
                    if (!s) {
                        emit DividendPaymentFailed(shareholder, amount);
                    }
                }
            } else {
                ISwapper(rewardTokens[token].swapper).swap{value: amount}(
                    token,
                    shareholder,
                    rewardTokens[token].buyTax,
                    minOut
                );
            }
        }

        // reset rewards
        shares[shareholder].totalExcluded = getCumulativeDividends(shares[shareholder].amount);
    }
    
    ///////////////////////////////////////////////
    //////////      Read Functions      ///////////
    ///////////////////////////////////////////////
    
    function shouldDistribute(address shareholder) internal view returns (bool) {
        return shares[shareholder].isRewardExempt == false && 
               shares[shareholder].amount >= minHolding && 
               pendingRewards(shareholder) > minDistribution;
    }
    
    function getShareholders() external view returns (address[] memory) {
        return shareholders;
    }
    
    function getShareForHolder(address holder) external view returns(uint256) {
        return shares[holder].amount;
    }

    function pendingRewards(address shareholder) public view returns (uint256) {
        if(shares[shareholder].amount == 0){ return 0; }

        uint256 shareholderTotalDividends = getCumulativeDividends(shares[shareholder].amount);
        uint256 shareholderTotalExcluded = shares[shareholder].totalExcluded;

        if(shareholderTotalDividends <= shareholderTotalExcluded){ return 0; }

        return ( shareholderTotalDividends - shareholderTotalExcluded );
    }
    
    function getRewardTokenForHolder(address holder) public view returns (address) {
        return shares[holder].rewardToken;
    }

    function getCumulativeDividends(uint256 share) internal view returns (uint256) {
        return ( share * dividendsPerShare ) / dividendsPerShareAccuracyFactor;
    }
    
    function isTokenApprovedForSwapping(address token) external view returns (bool) {
        return rewardTokens[token].isApproved;
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

    function paginateShareholdersThatCanDistribute(uint256 start, uint256 end) external view returns (address[] memory) {
        uint256 count = 0;
        uint len = shareholders.length;
        if (end > len) {
            end = len;
        }
        for (uint256 i = start; i < end;) {
            if (shouldDistribute(shareholders[i])) {
                unchecked { ++count; }
            }
            unchecked { ++i; }
        }

        address[] memory paginatedShareholders = new address[](count);
        uint256 index = 0;
        for (uint256 i = start; i < end;) {
            if (shouldDistribute(shareholders[i])) {
                paginatedShareholders[index] = shareholders[i];
                unchecked { ++index; }
            }
            unchecked { ++i; }
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

    // EVENTS 
    event ApproveTokenForSwapping(address token);
    event RemovedTokenForSwapping(address token);
    event SwappedMainTokenAddress(address newMain);
    event UpgradeDistributor(address newDistributor);
    event AddedShareholder(address shareholder);
    event RemovedShareholder(address shareholder);
    event TransferedTokenOwnership(address newOwner);
    event SetRewardTokenForHolder(address holder, address desiredRewardToken);
    event UpdateDistributorCriteria(uint256 minPeriod, uint256 minDistribution);

    receive() external payable {
        // update main dividends
        totalDividends += msg.value;
        dividendsPerShare += ( msg.value * dividendsPerShareAccuracyFactor ) / totalShares;
    }

}
