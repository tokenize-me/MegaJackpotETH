//SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

contract AutomationBase {
  error OnlySimulatedBackend();

  /**
   * @notice method that allows it to be simulated via eth_call by checking that
   * the sender is the zero address.
   */
  function _preventExecution() internal view {
    // solhint-disable-next-line avoid-tx-origin
    if (tx.origin != address(0)) {
      revert OnlySimulatedBackend();
    }
  }

  /**
   * @notice modifier that allows it to be simulated via eth_call by checking
   * that the sender is the zero address.
   */
  modifier cannotExecute() {
    _preventExecution();
    _;
  }
}


interface AutomationCompatibleInterface {
  /**
   * @notice method that is simulated by the keepers to see if any work actually
   * needs to be performed. This method does does not actually need to be
   * executable, and since it is only ever simulated it can consume lots of gas.
   * @dev To ensure that it is never called, you may want to add the
   * cannotExecute modifier from KeeperBase to your implementation of this
   * method.
   * @param checkData specified in the upkeep registration so it is always the
   * same for a registered upkeep. This can easily be broken down into specific
   * arguments using `abi.decode`, so multiple upkeeps can be registered on the
   * same contract and easily differentiated by the contract.
   * @return upkeepNeeded boolean to indicate whether the keeper should call
   * performUpkeep or not.
   * @return performData bytes that the keeper should call performUpkeep with, if
   * upkeep is needed. If you would like to encode data to decode later, try
   * `abi.encode`.
   */
  function checkUpkeep(bytes calldata checkData) external returns (bool upkeepNeeded, bytes memory performData);

  /**
   * @notice method that is actually executed by the keepers, via the registry.
   * The data returned by the checkUpkeep simulation will be passed into
   * this method to actually be executed.
   * @dev The input to this method should not be trusted, and the caller of the
   * method should not even be restricted to any single registry. Anyone should
   * be able call it, and the input should be validated, there is no guarantee
   * that the data passed in is the performData returned from checkUpkeep. This
   * could happen due to malicious keepers, racing keepers, or simply a state
   * change while the performUpkeep transaction is waiting for confirmation.
   * Always validate the data passed in.
   * @param performData is the data which was passed back from the checkData
   * simulation. If it is encoded, it can easily be decoded into other types by
   * calling `abi.decode`. This data should not be trusted, and should be
   * validated against the contract's current state.
   */
  function performUpkeep(bytes calldata performData) external;
}

abstract contract AutomationCompatible is AutomationBase, AutomationCompatibleInterface {}

interface IPool {
    function getCurrentPot() external view returns (uint256);
    function distribute(address to) external;
    function timeLeft() external view returns (uint256);
    function triggerNextPayout() external;
}

contract PoolTrigger is AutomationCompatible {

    address public pool1;

    address public pool2;

    address public owner;

    constructor(address _pool1, address _pool2) {

        // set data
        pool1 = _pool1;
        pool2 = _pool2;

        owner = msg.sender;
    }

    function setPool1(address _pool1) external {
        require(msg.sender == owner, 'only owner');
        pool1 = _pool1;
    }

    function setPool2(address _pool2) external {
        require(msg.sender == owner, 'only owner');
        pool2 = _pool2;
    }

    function viewUpkeep() external view returns (bool, bytes memory) {
        if (pool1 != address(0)) {
            bool isTime = IPool(pool1).timeLeft() == 0;
            bool hasFunds = IPool(pool1).getCurrentPot() > 0;
            if (isTime && hasFunds) {
                return (true, new bytes(0));
            }
        }
        if (pool2 != address(0)) {
            bool isTime = IPool(pool2).timeLeft() == 0;
            bool hasFunds = IPool(pool2).getCurrentPot() > 0;
            if (isTime && hasFunds) {
                return (true, new bytes(0));
            }
        }
        return (false, new bytes(0));
    }

    function checkUpkeep(bytes calldata) external override cannotExecute returns (bool upkeepNeeded, bytes memory performData) {
        if (pool1 != address(0)) {
            bool isTime = IPool(pool1).timeLeft() == 0;
            bool hasFunds = IPool(pool1).getCurrentPot() > 0;
            if (isTime && hasFunds) {
                return (true, new bytes(0));
            }
        }
        if (pool2 != address(0)) {
            bool isTime = IPool(pool2).timeLeft() == 0;
            bool hasFunds = IPool(pool2).getCurrentPot() > 0;
            if (isTime && hasFunds) {
                return (true, new bytes(0));
            }
        }
        return (false, new bytes(0));
    }

    function performUpkeep(bytes calldata) external {
        if (pool1 != address(0)) {
            bool isTime = IPool(pool1).timeLeft() == 0;
            bool hasFunds = IPool(pool1).getCurrentPot() > 0;
            if (isTime && hasFunds) {
                IPool(pool1).triggerNextPayout();
            }
        }
        if (pool2 != address(0)) {
            bool isTime = IPool(pool2).timeLeft() == 0;
            bool hasFunds = IPool(pool2).getCurrentPot() > 0;
            if (isTime && hasFunds) {
                IPool(pool2).triggerNextPayout();
            }
        }
    }

    receive() external payable {}
}