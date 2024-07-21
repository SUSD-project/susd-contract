// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.18;

import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin-contracts/contracts/utils/math/Math.sol";

import "./Interfaces/IStabilityPool.sol";
import "./Interfaces/IAddressesRegistry.sol";
import "./Interfaces/IStabilityPoolEvents.sol";
import "./Interfaces/ITroveManager.sol";
import "./Interfaces/IBoldToken.sol";
import "./Interfaces/ISortedTroves.sol";
import "./Dependencies/LiquityBase.sol";

// import "forge-std/console2.sol";

/*
 * The Stability Pool holds Bold tokens deposited by Stability Pool depositors.
 *
 * When a trove is liquidated, then depending on system conditions, some of its Bold debt gets offset with
 * Bold in the Stability Pool:  that is, the offset debt evaporates, and an equal amount of Bold tokens in the Stability Pool is burned.
 *
 * Thus, a liquidation causes each depositor to receive a Bold loss, in proportion to their deposit as a share of total deposits.
 * They also receive an Coll gain, as the collateral of the liquidated trove is distributed among Stability depositors,
 * in the same proportion.
 *
 * When a liquidation occurs, it depletes every deposit by the same fraction: for example, a liquidation that depletes 40%
 * of the total Bold in the Stability Pool, depletes 40% of each deposit.
 *
 * A deposit that has experienced a series of liquidations is termed a "compounded deposit": each liquidation depletes the deposit,
 * multiplying it by some factor in range ]0,1[
 *
 *
 * --- IMPLEMENTATION ---
 *
 * We use a highly scalable method of tracking deposits and Coll gains that has O(1) complexity.
 *
 * When a liquidation occurs, rather than updating each depositor's deposit and Coll gain, we simply update two state variables:
 * a product P, and a sum S.
 *
 * A mathematical manipulation allows us to factor out the initial deposit, and accurately track all depositors' compounded deposits
 * and accumulated Coll gains over time, as liquidations occur, using just these two variables P and S. When depositors join the
 * Stability Pool, they get a snapshot of the latest P and S: P_t and S_t, respectively.
 *
 * The formula for a depositor's accumulated Coll gain is derived here:
 * https://github.com/liquity/dev/blob/main/papers/Scalable_Reward_Distribution_with_Compounding_Stakes.pdf
 *
 * For a given deposit d_t, the ratio P/P_t tells us the factor by which a deposit has decreased since it joined the Stability Pool,
 * and the term d_t * (S - S_t)/P_t gives us the deposit's total accumulated Coll gain.
 *
 * Each liquidation updates the product P and sum S. After a series of liquidations, a compounded deposit and corresponding Coll gain
 * can be calculated using the initial deposit, the depositor’s snapshots of P and S, and the latest values of P and S.
 *
 * Any time a depositor updates their deposit (withdrawal, top-up) their accumulated Coll gain is paid out, their new deposit is recorded
 * (based on their latest compounded deposit and modified by the withdrawal/top-up), and they receive new snapshots of the latest P and S.
 * Essentially, they make a fresh deposit that overwrites the old one.
 *
 *
 * --- SCALE FACTOR ---
 *
 * Since P is a running product in range ]0,1] that is always-decreasing, it should never reach 0 when multiplied by a number in range ]0,1[.
 * Unfortunately, Solidity floor division always reaches 0, sooner or later.
 *
 * A series of liquidations that nearly empty the Pool (and thus each multiply P by a very small number in range ]0,1[ ) may push P
 * to its 18 digit decimal limit, and round it to 0, when in fact the Pool hasn't been emptied: this would break deposit tracking.
 *
 * So, to track P accurately, we use a scale factor: if a liquidation would cause P to decrease to <1e-9 (and be rounded to 0 by Solidity),
 * we first multiply P by 1e9, and increment a currentScale factor by 1.
 *
 * The added benefit of using 1e9 for the scale factor (rather than 1e18) is that it ensures negligible precision loss close to the
 * scale boundary: when P is at its minimum value of 1e9, the relative precision loss in P due to floor division is only on the
 * order of 1e-9.
 *
 * --- EPOCHS ---
 *
 * Whenever a liquidation fully empties the Stability Pool, all deposits should become 0. However, setting P to 0 would make P be 0
 * forever, and break all future reward calculations.
 *
 * So, every time the Stability Pool is emptied by a liquidation, we reset P = 1 and currentScale = 0, and increment the currentEpoch by 1.
 *
 * --- TRACKING DEPOSIT OVER SCALE CHANGES AND EPOCHS ---
 *
 * When a deposit is made, it gets snapshots of the currentEpoch and the currentScale.
 *
 * When calculating a compounded deposit, we compare the current epoch to the deposit's epoch snapshot. If the current epoch is newer,
 * then the deposit was present during a pool-emptying liquidation, and necessarily has been depleted to 0.
 *
 * Otherwise, we then compare the current scale to the deposit's scale snapshot. If they're equal, the compounded deposit is given by d_t * P/P_t.
 * If it spans one scale change, it is given by d_t * P/(P_t * 1e9). If it spans more than one scale change, we define the compounded deposit
 * as 0, since it is now less than 1e-9'th of its initial value (e.g. a deposit of 1 billion Bold has depleted to < 1 Bold).
 *
 *
 *  --- TRACKING DEPOSITOR'S Coll GAIN OVER SCALE CHANGES AND EPOCHS ---
 *
 * In the current epoch, the latest value of S is stored upon each scale change, and the mapping (scale -> S) is stored for each epoch.
 *
 * This allows us to calculate a deposit's accumulated Coll gain, during the epoch in which the deposit was non-zero and earned Coll.
 *
 * We calculate the depositor's accumulated Coll gain for the scale at which they made the deposit, using the Coll gain formula:
 * e_1 = d_t * (S - S_t) / P_t
 *
 * and also for scale after, taking care to divide the latter by a factor of 1e9:
 * e_2 = d_t * S / (P_t * 1e9)
 *
 * The gain in the second scale will be full, as the starting point was in the previous scale, thus no need to subtract anything.
 * The deposit therefore was present for reward events from the beginning of that second scale.
 *
 *        S_i-S_t + S_{i+1}
 *      .<--------.------------>
 *      .         .
 *      . S_i     .   S_{i+1}
 *   <--.-------->.<----------->
 *   S_t.         .
 *   <->.         .
 *      t         .
 *  |---+---------|-------------|-----...
 *         i            i+1
 *
 * The sum of (e_1 + e_2) captures the depositor's total accumulated Coll gain, handling the case where their
 * deposit spanned one scale change. We only care about gains across one scale change, since the compounded
 * deposit is defined as being 0 once it has spanned more than one scale change.
 *
 *
 * --- UPDATING P WHEN A LIQUIDATION OCCURS ---
 *
 * Please see the implementation spec in the proof document, which closely follows on from the compounded deposit / Coll gain derivations:
 * https://github.com/liquity/liquity/blob/master/papers/Scalable_Reward_Distribution_with_Compounding_Stakes.pdf
 *
 *
 */
contract StabilityPool is LiquityBase, IStabilityPool, IStabilityPoolEvents {
    using SafeERC20 for IERC20;

    string public constant NAME = "StabilityPool";

    IERC20 public immutable collToken;
    ITroveManager public immutable troveManager;
    IBoldToken public immutable boldToken;
    // Needed to check if there are pending liquidations
    ISortedTroves public immutable sortedTroves;

    uint256 internal collBalance; // deposited ether tracker

    // Tracker for Bold held in the pool. Changes when users deposit/withdraw, and when Trove debt is offset.
    uint256 internal totalBoldDeposits;

    // Total remaining Bold yield gains (from Trove interest mints) held by SP, and not yet paid out to depositors
    // TODO: from the contract's perspective, this is a write-only variable. It is only ever read in tests, so it would
    // be better to keep it outside the core contract.
    uint256 internal yieldGainsOwed;

    // --- Data structures ---

    struct Deposit {
        uint256 initialValue;
    }

    struct Snapshots {
        uint256 S; // Coll reward sum liqs
        uint256 P;
        uint256 B; // Bold reward sum from minted interest
        uint128 scale;
        uint128 epoch;
    }

    mapping(address => Deposit) public deposits; // depositor address -> Deposit struct
    mapping(address => Snapshots) public depositSnapshots; // depositor address -> snapshots struct
    mapping(address => uint256) public stashedColl;

    /*  Product 'P': Running product by which to multiply an initial deposit, in order to find the current compounded deposit,
    * after a series of liquidations have occurred, each of which cancel some Bold debt with the deposit.
    *
    * During its lifetime, a deposit's value evolves from d_t to d_t * P / P_t , where P_t
    * is the snapshot of P taken at the instant the deposit was made. 18-digit decimal.
    */
    uint256 public P = P_PRECISION;

    uint256 public constant P_PRECISION = 1e36;

    // A scale change will happen if P decreases by a factor of at least this much
    uint256 public constant SCALE_FACTOR = 1e9;

    // The number of scale changes after which an untouched deposit is considered zero
    uint256 public constant SCALE_SPAN = 4;

    // Each time the scale of P shifts by SCALE_FACTOR, the scale is incremented by 1
    uint128 public currentScale;

    // With each offset that fully empties the Pool, the epoch is incremented by 1
    uint128 public currentEpoch;

    /* Coll Gain sum 'S': During its lifetime, each deposit d_t earns an Coll gain of ( d_t * [S - S_t] )/P_t, where S_t
    * is the depositor's snapshot of S taken at the time t when the deposit was made.
    *
    * The 'S' sums are stored in a nested mapping (epoch => scale => sum):
    *
    * - The inner mapping records the sum S at different scales
    * - The outer mapping records the (scale => sum) mappings, for different epochs.
    */
    mapping(uint128 => mapping(uint128 => uint256)) public epochToScaleToS;
    mapping(uint128 => mapping(uint128 => uint256)) public epochToScaleToB;

    // --- Events ---

    event TroveManagerAddressChanged(address _newTroveManagerAddress);
    event BoldTokenAddressChanged(address _newBoldTokenAddress);
    event SortedTrovesAddressChanged(address _newSortedTrovesAddress);

    constructor(IAddressesRegistry _addressesRegistry) LiquityBase(_addressesRegistry) {
        collToken = _addressesRegistry.collToken();
        troveManager = _addressesRegistry.troveManager();
        boldToken = _addressesRegistry.boldToken();
        sortedTroves = _addressesRegistry.sortedTroves();

        emit TroveManagerAddressChanged(address(troveManager));
        emit BoldTokenAddressChanged(address(boldToken));
        emit SortedTrovesAddressChanged(address(sortedTroves));
    }

    // --- Getters for public variables. Required by IPool interface ---

    function getCollBalance() external view override returns (uint256) {
        return collBalance;
    }

    function getTotalBoldDeposits() external view override returns (uint256) {
        return totalBoldDeposits;
    }

    function getYieldGainsOwed() external view override returns (uint256) {
        return yieldGainsOwed;
    }

    // --- External Depositor Functions ---

    /*  provideToSP():
    * - Calculates depositor's Coll gain
    * - Calculates the compounded deposit
    * - Increases deposit, and takes new snapshots of accumulators P and S
    * - Sends depositor's accumulated Coll gains to depositor
    */
    function provideToSP(uint256 _topUp, bool _doClaim) external override {
        _requireNonZeroAmount(_topUp);

        activePool.mintAggInterest();

        uint256 initialDeposit = deposits[msg.sender].initialValue;

        uint256 currentCollGain = getDepositorCollGain(msg.sender);
        uint256 currentYieldGain = getDepositorYieldGain(msg.sender);
        uint256 compoundedBoldDeposit = getCompoundedBoldDeposit(msg.sender);
        (uint256 keptYieldGain, uint256 yieldGainToSend) = _getYieldToKeepOrSend(currentYieldGain, _doClaim);
        uint256 newDeposit = compoundedBoldDeposit + _topUp + keptYieldGain;
        (uint256 newStashedColl, uint256 collToSend) =
            _getNewStashedCollAndCollToSend(msg.sender, currentCollGain, _doClaim);

        emit DepositOperation(
            msg.sender,
            Operation.provideToSP,
            initialDeposit - compoundedBoldDeposit,
            int256(_topUp),
            currentYieldGain,
            yieldGainToSend,
            currentCollGain,
            collToSend
        );

        _updateDepositAndSnapshots(msg.sender, newDeposit, newStashedColl);
        boldToken.sendToPool(msg.sender, address(this), _topUp);
        _updateTotalBoldDeposits(_topUp + keptYieldGain, 0);
        _decreaseYieldGainsOwed(currentYieldGain);
        _sendBoldtoDepositor(msg.sender, yieldGainToSend);
        _sendCollGainToDepositor(collToSend);
    }

    function _getYieldToKeepOrSend(uint256 _currentYieldGain, bool _doClaim) internal pure returns (uint256, uint256) {
        uint256 yieldToKeep;
        uint256 yieldToSend;

        if (_doClaim) {
            yieldToKeep = 0;
            yieldToSend = _currentYieldGain;
        } else {
            yieldToKeep = _currentYieldGain;
            yieldToSend = 0;
        }

        return (yieldToKeep, yieldToSend);
    }

    /*  withdrawFromSP():
    * - Calculates depositor's Coll gain
    * - Calculates the compounded deposit
    * - Sends the requested BOLD withdrawal to depositor
    * - (If _amount > userDeposit, the user withdraws all of their compounded deposit)
    * - Decreases deposit by withdrawn amount and takes new snapshots of accumulators P and S
    */
    function withdrawFromSP(uint256 _amount, bool _doClaim) external override {
        uint256 initialDeposit = deposits[msg.sender].initialValue;
        _requireUserHasDeposit(initialDeposit);

        activePool.mintAggInterest();

        uint256 currentCollGain = getDepositorCollGain(msg.sender);
        uint256 currentYieldGain = getDepositorYieldGain(msg.sender);
        uint256 compoundedBoldDeposit = getCompoundedBoldDeposit(msg.sender);
        uint256 boldToWithdraw = LiquityMath._min(_amount, compoundedBoldDeposit);
        (uint256 keptYieldGain, uint256 yieldGainToSend) = _getYieldToKeepOrSend(currentYieldGain, _doClaim);
        uint256 newDeposit = compoundedBoldDeposit - boldToWithdraw + keptYieldGain;
        (uint256 newStashedColl, uint256 collToSend) =
            _getNewStashedCollAndCollToSend(msg.sender, currentCollGain, _doClaim);

        emit DepositOperation(
            msg.sender,
            Operation.withdrawFromSP,
            initialDeposit - compoundedBoldDeposit,
            -int256(boldToWithdraw),
            currentYieldGain,
            yieldGainToSend,
            currentCollGain,
            collToSend
        );

        _updateDepositAndSnapshots(msg.sender, newDeposit, newStashedColl);
        _decreaseYieldGainsOwed(currentYieldGain);
        _updateTotalBoldDeposits(keptYieldGain, boldToWithdraw);
        _sendBoldtoDepositor(msg.sender, boldToWithdraw + yieldGainToSend);
        _sendCollGainToDepositor(collToSend);
    }

    function _getNewStashedCollAndCollToSend(address _depositor, uint256 _currentCollGain, bool _doClaim)
        internal
        view
        returns (uint256 newStashedColl, uint256 collToSend)
    {
        if (_doClaim) {
            newStashedColl = 0;
            collToSend = stashedColl[_depositor] + _currentCollGain;
        } else {
            newStashedColl = stashedColl[_depositor] + _currentCollGain;
            collToSend = 0;
        }
    }

    // This function is only needed in the case a user has no deposit but still has remaining stashed Coll gains.
    function claimAllCollGains() external {
        _requireUserHasNoDeposit(msg.sender);

        activePool.mintAggInterest();

        uint256 collToSend = stashedColl[msg.sender];
        stashedColl[msg.sender] = 0;

        emit DepositOperation(msg.sender, Operation.claimAllCollGains, 0, 0, 0, 0, 0, collToSend);
        emit DepositUpdated(msg.sender, 0, 0, 0, 0, 0, 0, 0);

        _sendCollGainToDepositor(collToSend);
    }

    // --- BOLD reward functions ---

    function triggerBoldRewards(uint256 _boldYield) external {
        _requireCallerIsActivePool();

        // When total deposits is very small, B is not updated. In this case, the BOLD issued can not be obtained by later
        // depositors - it is missed out on, and remains in the balance of the SP.
        if (totalBoldDeposits < DECIMAL_PRECISION || _boldYield == 0) return;

        yieldGainsOwed += _boldYield;

        epochToScaleToB[currentEpoch][currentScale] += P * _boldYield / totalBoldDeposits;
        emit B_Updated(epochToScaleToB[currentEpoch][currentScale], currentEpoch, currentScale);
    }

    // --- Liquidation functions ---

    /*
    * Cancels out the specified debt against the Bold contained in the Stability Pool (as far as possible)
    * and transfers the Trove's Coll collateral from ActivePool to StabilityPool.
    * Only called by liquidation functions in the TroveManager.
    */
    function offset(uint256 _debtToOffset, uint256 _collToAdd) external override {
        _requireCallerIsTroveManager();

        epochToScaleToS[currentEpoch][currentScale] += P * _collToAdd / totalBoldDeposits;
        emit S_Updated(epochToScaleToS[currentEpoch][currentScale], currentEpoch, currentScale);

        P -= Math.ceilDiv(P * _debtToOffset, totalBoldDeposits);

        if (P == 0) {
            P = P_PRECISION;

            currentEpoch += 1;
            emit EpochUpdated(currentEpoch);

            currentScale = 0;
            emit ScaleUpdated(currentScale);
        } else {
            while (P <= P_PRECISION / SCALE_FACTOR) {
                P *= SCALE_FACTOR;
                currentScale += 1;
            }

            emit ScaleUpdated(currentScale);
        }

        emit P_Updated(P);

        _moveOffsetCollAndDebt(_collToAdd, _debtToOffset);
    }

    function _moveOffsetCollAndDebt(uint256 _collToAdd, uint256 _debtToOffset) internal {
        // Cancel the liquidated Bold debt with the Bold in the stability pool
        _updateTotalBoldDeposits(0, _debtToOffset);

        // Burn the debt that was successfully offset
        boldToken.burn(address(this), _debtToOffset);

        // Update internal Coll balance tracker
        uint256 newCollBalance = collBalance + _collToAdd;
        collBalance = newCollBalance;

        // Pull Coll from Active Pool
        activePool.sendColl(address(this), _collToAdd);

        emit StabilityPoolCollBalanceUpdated(newCollBalance);
    }

    function _updateTotalBoldDeposits(uint256 _depositIncrease, uint256 _depositDecrease) internal {
        if (_depositIncrease == 0 && _depositDecrease == 0) return;
        uint256 newTotalBoldDeposits = totalBoldDeposits + _depositIncrease - _depositDecrease;
        totalBoldDeposits = newTotalBoldDeposits;
        emit StabilityPoolBoldBalanceUpdated(newTotalBoldDeposits);
    }

    function _decreaseYieldGainsOwed(uint256 _amount) internal {
        if (_amount == 0) return;
        uint256 newYieldGainsOwed = yieldGainsOwed - _amount;
        yieldGainsOwed = newYieldGainsOwed;
    }

    // --- Reward calculator functions for depositor ---

    /* Calculates the Coll gain earned by the deposit since its last snapshots were taken.
    * Given by the formula:  E = d0 * (S - S(0))/P(0)
    * where S(0) and P(0) are the depositor's snapshots of the sum S and product P, respectively.
    * d0 is the last recorded deposit value.
    */
    function getDepositorCollGain(address _depositor) public view override returns (uint256) {
        uint256 initialDeposit = deposits[_depositor].initialValue;
        if (initialDeposit == 0) return 0;

        Snapshots memory snapshots = depositSnapshots[_depositor];

        /*
        * Grab the sum 'S' from the epoch at which the stake was made. The Coll gain may span up to one scale change.
        * If it does, the second portion of the Coll gain is scaled by 1e9.
        * If the gain spans no scale change, the second portion will be 0.
        */
        uint128 epochSnapshot = snapshots.epoch;
        uint128 scaleSnapshot = snapshots.scale;

        uint256 scaleFactor = 1;
        uint256 normalizedGains = epochToScaleToS[epochSnapshot][scaleSnapshot] - snapshots.S;

        for (uint128 i = 1; i <= SCALE_SPAN; ++i) {
            scaleFactor *= SCALE_FACTOR;
            normalizedGains += epochToScaleToS[epochSnapshot][scaleSnapshot + i] / scaleFactor;
        }

        uint256 collGain = initialDeposit * normalizedGains / snapshots.P;
        return collGain;
    }

    function getDepositorYieldGain(address _depositor) public view override returns (uint256) {
        uint256 initialDeposit = deposits[_depositor].initialValue;
        if (initialDeposit == 0) return 0;

        Snapshots memory snapshots = depositSnapshots[_depositor];

        /*
        * Grab the sum 'B' from the epoch at which the stake was made. The Bold gain may span up to one scale change.
        * If it does, the second portion of the Bold gain is scaled by 1e9.
        * If the gain spans no scale change, the second portion will be 0.
        */
        uint128 epochSnapshot = snapshots.epoch;
        uint128 scaleSnapshot = snapshots.scale;

        uint256 scaleFactor = 1;
        uint256 normalizedGains = epochToScaleToB[epochSnapshot][scaleSnapshot] - snapshots.B;

        for (uint128 i = 1; i <= SCALE_SPAN; ++i) {
            scaleFactor *= SCALE_FACTOR;
            normalizedGains += epochToScaleToB[epochSnapshot][scaleSnapshot + i] / scaleFactor;
        }

        uint256 yieldGain = initialDeposit * normalizedGains / snapshots.P;
        return yieldGain;
    }

    function getDepositorYieldGainWithPending(address _depositor) external view override returns (uint256) {
        uint256 initialDeposit = deposits[_depositor].initialValue;
        if (initialDeposit == 0) return 0;

        Snapshots memory snapshots = depositSnapshots[_depositor];

        uint128 epoch = snapshots.epoch;
        uint128 scale = snapshots.scale;
        uint256 B = 0;

        for (uint128 i = 0; i <= SCALE_SPAN; ++i) {
            B += epochToScaleToB[epoch][scale + i] / (SCALE_FACTOR ** i);

            if (currentEpoch == epoch && currentScale == scale + i && totalBoldDeposits >= DECIMAL_PRECISION) {
                B += P * activePool.calcPendingSPYield() / totalBoldDeposits / (SCALE_FACTOR ** i);
            }
        }

        uint256 yieldGain = initialDeposit * (B - snapshots.B) / snapshots.P;
        return yieldGain;
    }

    // --- Compounded deposit ---

    /*
    * Return the user's compounded deposit. Given by the formula:  d = d0 * P/P(0)
    * where P(0) is the depositor's snapshot of the product P, taken when they last updated their deposit.
    */
    function getCompoundedBoldDeposit(address _depositor) public view override returns (uint256) {
        uint256 initialDeposit = deposits[_depositor].initialValue;
        if (initialDeposit == 0) return 0;

        Snapshots memory snapshots = depositSnapshots[_depositor];

        // If stake was made before a pool-emptying event, then it has been fully cancelled with debt -- so, return 0
        if (snapshots.epoch < currentEpoch) return 0;

        uint256 compoundedDeposit;
        uint128 scaleDiff = currentScale - snapshots.scale;

        /* Compute the compounded stake. If a scale change in P was made during the stake's lifetime,
        * account for it. If more than one scale change was made, then the stake has decreased by a factor of
        * at least 1e-9 -- so return 0.
        */
        if (scaleDiff <= SCALE_SPAN) {
            compoundedDeposit = initialDeposit * P / snapshots.P / (SCALE_FACTOR ** scaleDiff);
        } else {
            compoundedDeposit = 0;
        }

        return compoundedDeposit;
    }

    // --- Sender functions for Bold deposit and Coll gains ---

    function _sendCollGainToDepositor(uint256 _collAmount) internal {
        if (_collAmount == 0) return;

        uint256 newCollBalance = collBalance - _collAmount;
        collBalance = newCollBalance;
        emit StabilityPoolCollBalanceUpdated(newCollBalance);
        emit EtherSent(msg.sender, _collAmount);
        collToken.safeTransfer(msg.sender, _collAmount);
    }

    // Send Bold to user and decrease Bold in Pool
    function _sendBoldtoDepositor(address _depositor, uint256 _boldToSend) internal {
        if (_boldToSend == 0) return;
        boldToken.returnFromPool(address(this), _depositor, _boldToSend);
    }

    // --- Stability Pool Deposit Functionality ---

    function _updateDepositAndSnapshots(address _depositor, uint256 _newDeposit, uint256 _newStashedColl) internal {
        deposits[_depositor].initialValue = _newDeposit;
        stashedColl[_depositor] = _newStashedColl;

        if (_newDeposit == 0) {
            delete depositSnapshots[_depositor];
            emit DepositUpdated(_depositor, 0, _newStashedColl, 0, 0, 0, 0, 0);
            return;
        }

        uint128 currentScaleCached = currentScale;
        uint128 currentEpochCached = currentEpoch;
        uint256 currentP = P;

        // Get S for the current epoch and current scale
        uint256 currentS = epochToScaleToS[currentEpochCached][currentScaleCached];
        uint256 currentB = epochToScaleToB[currentEpochCached][currentScaleCached];

        // Record new snapshots of the latest running product P and sum S for the depositor
        depositSnapshots[_depositor].P = currentP;
        depositSnapshots[_depositor].S = currentS;
        depositSnapshots[_depositor].B = currentB;
        depositSnapshots[_depositor].scale = currentScaleCached;
        depositSnapshots[_depositor].epoch = currentEpochCached;

        emit DepositUpdated(
            _depositor,
            _newDeposit,
            _newStashedColl,
            currentP,
            currentS,
            currentB,
            currentScaleCached,
            currentEpochCached
        );
    }

    // --- 'require' functions ---

    function _requireCallerIsActivePool() internal view {
        require(msg.sender == address(activePool), "StabilityPool: Caller is not ActivePool");
    }

    function _requireCallerIsTroveManager() internal view {
        require(msg.sender == address(troveManager), "StabilityPool: Caller is not TroveManager");
    }

    function _requireUserHasDeposit(uint256 _initialDeposit) internal pure {
        require(_initialDeposit > 0, "StabilityPool: User must have a non-zero deposit");
    }

    function _requireUserHasNoDeposit(address _address) internal view {
        uint256 initialDeposit = deposits[_address].initialValue;
        require(initialDeposit == 0, "StabilityPool: User must have no deposit");
    }

    function _requireNonZeroAmount(uint256 _amount) internal pure {
        require(_amount > 0, "StabilityPool: Amount must be non-zero");
    }
}
