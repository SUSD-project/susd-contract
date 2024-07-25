// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.18;

import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import "./Interfaces/ICollSurplusPool.sol";
import "./Dependencies/Ownable.sol";

contract CollSurplusPool is Ownable, ICollSurplusPool {
    using SafeERC20 for IERC20;

    string public constant NAME = "CollSurplusPool";

    IERC20 public immutable collToken;
    address public borrowerOperationsAddress;
    address public troveManagerAddress;
    address public activePoolAddress;

    // deposited ether tracker
    uint256 internal collBalance;
    // Collateral surplus claimable by trove owners
    mapping(address => uint256) internal balances;

    // --- Events ---

    event BorrowerOperationsAddressChanged(address _newBorrowerOperationsAddress);
    event TroveManagerAddressChanged(address _newTroveManagerAddress);
    event ActivePoolAddressChanged(address _newActivePoolAddress);

    event CollBalanceUpdated(address indexed _account, uint256 _newBalance);
    event CollSent(address _to, uint256 _amount);

    constructor(address _collAddress) {
        collToken = IERC20(_collAddress);
    }

    // --- Contract setters ---

    function setAddresses(address _borrowerOperationsAddress, address _troveManagerAddress, address _activePoolAddress)
        external
        override
        onlyOwner
    {
        borrowerOperationsAddress = _borrowerOperationsAddress;
        troveManagerAddress = _troveManagerAddress;
        activePoolAddress = _activePoolAddress;

        emit BorrowerOperationsAddressChanged(_borrowerOperationsAddress);
        emit TroveManagerAddressChanged(_troveManagerAddress);
        emit ActivePoolAddressChanged(_activePoolAddress);

        _renounceOwnership();
    }

    /* Returns the collBalance state variable
       Not necessarily equal to the raw coll balance - coll can be forcibly sent to contracts. */
    function getCollBalance() external view override returns (uint256) {
        return collBalance;
    }

    function getCollateral(address _account) external view override returns (uint256) {
        return balances[_account];
    }

    // --- Pool functionality ---

    function accountSurplus(address _account, uint256 _amount) external override {
        _requireCallerIsTroveManager();

        uint256 newAmount = balances[_account] + _amount;
        balances[_account] = newAmount;
        collBalance = collBalance + _amount;

        emit CollBalanceUpdated(_account, newAmount);
    }

    function claimColl(address _account) external override {
        _requireCallerIsBorrowerOperations();
        uint256 claimableColl = balances[_account];
        require(claimableColl > 0, "CollSurplusPool: No collateral available to claim");

        balances[_account] = 0;
        emit CollBalanceUpdated(_account, 0);

        collBalance = collBalance - claimableColl;
        emit CollSent(_account, claimableColl);

        collToken.safeTransfer(_account, claimableColl);
    }

    // --- 'require' functions ---

    function _requireCallerIsBorrowerOperations() internal view {
        require(msg.sender == borrowerOperationsAddress, "CollSurplusPool: Caller is not Borrower Operations");
    }

    function _requireCallerIsTroveManager() internal view {
        require(msg.sender == troveManagerAddress, "CollSurplusPool: Caller is not TroveManager");
    }
}
