// SPDX-License-Identifier: MIT

pragma solidity 0.8.18;

import "./IActivePool.sol";
import "./ILiquityBase.sol";
import "./IBorrowerOperations.sol";
import "./IBoldToken.sol";
import "./ITroveManager.sol";

/*
 * The Stability Pool holds Bold tokens deposited by Stability Pool depositors.
 *
 * When a trove is liquidated, then depending on system conditions, some of its Bold debt gets offset with
 * Bold in the Stability Pool:  that is, the offset debt evaporates, and an equal amount of Bold tokens in the Stability Pool is burned.
 *
 * Thus, a liquidation causes each depositor to receive a Bold loss, in proportion to their deposit as a share of total deposits.
 * They also receive an ETH gain, as the ETH collateral of the liquidated trove is distributed among Stability depositors,
 * in the same proportion.
 *
 * When a liquidation occurs, it depletes every deposit by the same fraction: for example, a liquidation that depletes 40%
 * of the total Bold in the Stability Pool, depletes 40% of each deposit.
 *
 * A deposit that has experienced a series of liquidations is termed a "compounded deposit": each liquidation depletes the deposit,
 * multiplying it by some factor in range ]0,1[
 *
 * Please see the implementation spec in the proof document, which closely follows on from the compounded deposit / ETH gain derivations:
 * https://github.com/liquity/liquity/blob/master/papers/Scalable_Reward_Distribution_with_Compounding_Stakes.pdf
 *
*/
interface IStabilityPool is ILiquityBase {
    function borrowerOperations() external view returns (IBorrowerOperations);
    function boldToken() external view returns (IBoldToken);
    function troveManager() external view returns (ITroveManager);

    /*
     * Called only once on init, to set addresses of other Liquity contracts
     * Callable only by owner, renounces ownership at the end
     */
    function setAddresses(
        address _borrowerOperationsAddress,
        address _troveManagerAddress,
        address _activePoolAddress,
        address _boldTokenAddress,
        address _sortedTrovesAddress,
        address _priceFeedAddress
    ) external;
  
    /*  provideToSP():
    * - Calculates depositor's ETH gain
    * - Calculates the compounded deposit
    * - Increases deposit, and takes new snapshots of accumulators P and S
    * - Sends depositor's accumulated ETH gains to depositor
    */
    function provideToSP(uint _amount) external;


    /*  withdrawFromSP():
    * - Calculates depositor's ETH gain
    * - Calculates the compounded deposit
    * - Sends the requested BOLD withdrawal to depositor 
    * - (If _amount > userDeposit, the user withdraws all of their compounded deposit)
    * - Decreases deposit by withdrawn amount and takes new snapshots of accumulators P and S
    */
    function withdrawFromSP(uint _amount) external;

    /* withdrawETHGainToTrove():
    * - Transfers the depositor's entire ETH gain from the Stability Pool to the caller's trove
    * - Leaves their compounded deposit in the Stability Pool
    * - Takes new snapshots of accumulators P and S 
    */
    function withdrawETHGainToTrove() external;

    /*
     * Initial checks:
     * - Caller is TroveManager
     * ---
     * Cancels out the specified debt against the Bold contained in the Stability Pool (as far as possible)
     * and transfers the Trove's ETH collateral from ActivePool to StabilityPool.
     * Only called by liquidation functions in the TroveManager.
     */
    function offset(uint _debt, uint _coll) external;

    /* setETHSellIntent():
     * Opt-in swap facility liquidation gains
     */
    function setETHSellIntent(uint256 _ethAmount, uint256 _priceDiscount) external;

    /* buyETH():
     * Swap ETH to Bold using opt-in swap facility liquidation gains, from one depositor
     */
    function buyETH(address _depositor, uint256 _ethAmount) external;

    /* buyETHBatch():
     * Swap ETH to Bold using opt-in swap facility liquidation gains, from multiple depositors
     */
    function buyETHBatch(address[] calldata _depositors, uint256 _ethAmount) external;

    /*
     * Returns the total amount of ETH held by the pool, accounted in an internal variable instead of `balance`,
     * to exclude edge cases like ETH received from a self-destruct.
     */
    function getETHBalance() external view returns (uint);

    /*
     * Returns Bold held in the pool. Changes when users deposit/withdraw, and when Trove debt is offset.
     */
    function getTotalBoldDeposits() external view returns (uint);

    /*
     * Calculates the ETH gain earned by the deposit since its last snapshots were taken.
     */
    function getDepositorETHGain(address _depositor) external view returns (uint);

    /*
     * Return the user's compounded deposit.
     */
    function getCompoundedBoldDeposit(address _depositor) external view returns (uint);

    /*
     * Only callable by Active Pool, it pulls ETH and accounts for ETH received
     */
    function receiveETH(uint256 _amount) external;
}
