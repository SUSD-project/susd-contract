pragma solidity ^0.8.18;

import "./TestContracts/DevTestSetup.sol";

contract MulticollateralTest is DevTestSetup {
    uint256 NUM_COLLATERALS = 4;
    LiquityContracts[] public contractsArray;

    function openMulticollateralTroveNoHints100pctWithIndex(
        uint256 _collIndex,
        address _account,
        uint256 _index,
        uint256 _coll,
        uint256 _boldAmount,
        uint256 _annualInterestRate
    ) public returns (uint256 troveId) {
        TroveChange memory troveChange;
        troveChange.debtIncrease = _boldAmount + BOLD_GAS_COMP;
        troveChange.newWeightedRecordedDebt = troveChange.debtIncrease * _annualInterestRate;
        uint256 avgInterestRate =
            contractsArray[_collIndex].activePool.getNewApproxAvgInterestRateFromTroveChange(troveChange);
        uint256 upfrontFee = calcUpfrontFee(troveChange.debtIncrease, avgInterestRate);

        vm.startPrank(_account);

        troveId = contractsArray[_collIndex].borrowerOperations.openTrove(
            _account,
            _index,
            _coll,
            _boldAmount,
            0, // _upperHint
            0, // _lowerHint
            _annualInterestRate,
            upfrontFee
        );

        vm.stopPrank();
    }

    function makeMulticollateralSPDepositAndClaim(uint256 _collIndex, address _account, uint256 _amount) public {
        vm.startPrank(_account);
        contractsArray[_collIndex].stabilityPool.provideToSP(_amount, true);
        vm.stopPrank();
    }

    function setUp() public override {
        // Start tests at a non-zero timestamp
        vm.warp(block.timestamp + 600);

        accounts = new Accounts();
        createAccounts();

        (A, B, C, D, E, F, G) = (
            accountsList[0],
            accountsList[1],
            accountsList[2],
            accountsList[3],
            accountsList[4],
            accountsList[5],
            accountsList[6]
        );

        TroveManagerParams[] memory troveManagerParams = new TroveManagerParams[](NUM_COLLATERALS);
        troveManagerParams[0] = TroveManagerParams(110e16, 5e16, 10e16);
        troveManagerParams[1] = TroveManagerParams(120e16, 5e16, 10e16);
        troveManagerParams[2] = TroveManagerParams(120e16, 5e16, 10e16);
        troveManagerParams[3] = TroveManagerParams(125e16, 5e16, 10e16);

        LiquityContracts[] memory _contractsArray;
        (_contractsArray, collateralRegistry, boldToken) = _deployAndConnectContracts(troveManagerParams);
        // Unimplemented feature (...):Copying of type struct LiquityContracts memory[] memory to storage not yet supported.
        for (uint256 c = 0; c < NUM_COLLATERALS; c++) {
            contractsArray.push(_contractsArray[c]);
        }
        // Set price feeds
        contractsArray[0].priceFeed.setPrice(2000e18);
        contractsArray[1].priceFeed.setPrice(200e18);
        contractsArray[2].priceFeed.setPrice(20000e18);
        contractsArray[3].priceFeed.setPrice(2500e18);
        // Just in case
        for (uint256 c = 4; c < NUM_COLLATERALS; c++) {
            contractsArray[c].priceFeed.setPrice(2000e18 + c * 1e18);
        }

        // Give some Collateral to test accounts, and approve it to BorrowerOperations
        uint256 initialCollateralAmount = 10_000e18;

        for (uint256 c = 0; c < NUM_COLLATERALS; c++) {
            for (uint256 i = 0; i < 6; i++) {
                // A to F
                giveAndApproveCollateral(
                    contractsArray[c].WETH,
                    accountsList[i],
                    initialCollateralAmount,
                    address(contractsArray[c].borrowerOperations)
                );
            }
        }

        // Assuming these are universal
        BOLD_GAS_COMP = _contractsArray[0].troveManager.BOLD_GAS_COMPENSATION();
        MIN_NET_DEBT = _contractsArray[0].troveManager.MIN_NET_DEBT();
        MIN_DEBT = _contractsArray[0].troveManager.MIN_DEBT();
        UPFRONT_INTEREST_PERIOD = _contractsArray[0].troveManager.UPFRONT_INTEREST_PERIOD();
    }

    function testMultiCollateralDeployment() public {
        // check deployment
        assertEq(collateralRegistry.totalCollaterals(), NUM_COLLATERALS, "Wrong number of branches");
        for (uint256 c = 0; c < NUM_COLLATERALS; c++) {
            assertNotEq(address(collateralRegistry.getToken(c)), ZERO_ADDRESS, "Missing collateral token");
            assertNotEq(address(collateralRegistry.getTroveManager(c)), ZERO_ADDRESS, "Missing TroveManager");
        }
        for (uint256 c = NUM_COLLATERALS; c < 10; c++) {
            assertEq(address(collateralRegistry.getToken(c)), ZERO_ADDRESS, "Extra collateral token");
            assertEq(address(collateralRegistry.getTroveManager(c)), ZERO_ADDRESS, "Extra TroveManager");
        }
    }

    struct TestValues {
        uint256 troveId;
        uint256 price;
        uint256 unbackedPortion;
        uint256 redeemAmount;
        uint256 fee;
        uint256 collInitialBalance;
        uint256 collFinalBalance;
        uint256 branchDebt;
        uint256 WETHBalBefore_A;
        uint256 redeemed;
        uint256 correspondingETH;
        uint256 ETHFee;
        uint256 spBoldAmount;
    }

    function testMultiCollateralRedemption() public {
        TestValues memory testValues1;
        TestValues memory testValues2;
        TestValues memory testValues3;
        TestValues memory testValues4;
        uint256 redeemAmount = 1600e18;

        // First collateral unbacked Bold: 10k (SP empty)
        testValues1.troveId = openMulticollateralTroveNoHints100pctWithIndex(0, A, 0, 10e18, 10000e18, 5e16);

        // Second collateral unbacked Bold: 5k
        testValues2.troveId = openMulticollateralTroveNoHints100pctWithIndex(1, A, 0, 100e18, 10000e18, 5e16);
        makeMulticollateralSPDepositAndClaim(1, A, 5000e18);

        // Third collateral unbacked Bold: 1k
        testValues3.troveId = openMulticollateralTroveNoHints100pctWithIndex(2, A, 0, 10e18, 10000e18, 5e16);
        makeMulticollateralSPDepositAndClaim(2, A, 9000e18);

        // Fourth collateral unbacked Bold: 0
        testValues4.troveId = openMulticollateralTroveNoHints100pctWithIndex(3, A, 0, 10e18, 10000e18, 5e16);
        makeMulticollateralSPDepositAndClaim(3, A, 10000e18);

        // Check A’s final bal
        // TODO: change when we switch to new gas compensation
        assertEq(boldToken.balanceOf(A), 16000e18, "Wrong Bold balance before redemption");

        // initial balances
        testValues1.collInitialBalance = contractsArray[0].WETH.balanceOf(A);
        testValues2.collInitialBalance = contractsArray[1].WETH.balanceOf(A);
        testValues3.collInitialBalance = contractsArray[2].WETH.balanceOf(A);
        testValues4.collInitialBalance = contractsArray[3].WETH.balanceOf(A);

        testValues1.price = contractsArray[0].priceFeed.getPrice();
        testValues2.price = contractsArray[1].priceFeed.getPrice();
        testValues3.price = contractsArray[2].priceFeed.getPrice();
        testValues4.price = contractsArray[3].priceFeed.getPrice();

        testValues1.unbackedPortion = contractsArray[0].troveManager.getTroveEntireDebt(testValues1.troveId);
        testValues2.unbackedPortion = contractsArray[1].troveManager.getTroveEntireDebt(testValues2.troveId) - 5000e18;
        testValues3.unbackedPortion = contractsArray[2].troveManager.getTroveEntireDebt(testValues3.troveId) - 9000e18;
        testValues4.unbackedPortion = contractsArray[3].troveManager.getTroveEntireDebt(testValues4.troveId) - 10000e18;
        uint256 totalUnbacked = testValues1.unbackedPortion + testValues2.unbackedPortion + testValues3.unbackedPortion
            + testValues4.unbackedPortion;

        testValues1.redeemAmount = redeemAmount * testValues1.unbackedPortion / totalUnbacked;
        testValues2.redeemAmount = redeemAmount * testValues2.unbackedPortion / totalUnbacked;
        testValues3.redeemAmount = redeemAmount * testValues3.unbackedPortion / totalUnbacked;
        testValues4.redeemAmount = redeemAmount * testValues4.unbackedPortion / totalUnbacked;

        // fees
        uint256 fee = collateralRegistry.getEffectiveRedemptionFeeInBold(redeemAmount);
        testValues1.fee = fee * testValues1.redeemAmount / redeemAmount * DECIMAL_PRECISION / testValues1.price;
        testValues2.fee = fee * testValues2.redeemAmount / redeemAmount * DECIMAL_PRECISION / testValues2.price;
        testValues3.fee = fee * testValues3.redeemAmount / redeemAmount * DECIMAL_PRECISION / testValues3.price;
        testValues4.fee = fee * testValues4.redeemAmount / redeemAmount * DECIMAL_PRECISION / testValues4.price;

        // A redeems 1.6k
        redeem(A, redeemAmount);

        // Check bold balance
        // TODO: change when we switch to new gas compensation
        assertApproxEqAbs(boldToken.balanceOf(A), 14400e18, 10, "Wrong Bold balance after redemption");

        // Check collateral balances
        // final balances
        testValues1.collFinalBalance = contractsArray[0].WETH.balanceOf(A);
        testValues2.collFinalBalance = contractsArray[1].WETH.balanceOf(A);
        testValues3.collFinalBalance = contractsArray[2].WETH.balanceOf(A);
        testValues4.collFinalBalance = contractsArray[3].WETH.balanceOf(A);

        assertApproxEqAbs(
            testValues1.collFinalBalance - testValues1.collInitialBalance,
            testValues1.redeemAmount * DECIMAL_PRECISION / testValues1.price - testValues1.fee,
            1e14,
            "Wrong Collateral 1 balance"
        );
        assertApproxEqAbs(
            testValues2.collFinalBalance - testValues2.collInitialBalance,
            testValues2.redeemAmount * DECIMAL_PRECISION / testValues2.price - testValues2.fee,
            1e14,
            "Wrong Collateral 2 balance"
        );
        assertApproxEqAbs(
            testValues3.collFinalBalance - testValues3.collInitialBalance,
            testValues3.redeemAmount * DECIMAL_PRECISION / testValues3.price - testValues3.fee,
            1e13,
            "Wrong Collateral 3 balance"
        );
        assertApproxEqAbs(
            testValues4.collFinalBalance - testValues4.collInitialBalance,
            testValues4.redeemAmount * DECIMAL_PRECISION / testValues4.price - testValues4.fee,
            1e11,
            "Wrong Collateral 4 balance"
        );
    }

    function testMultiCollateralRedemptionFuzz(
        uint256 _spBoldAmount1,
        uint256 _spBoldAmount2,
        uint256 _spBoldAmount3,
        uint256 _spBoldAmount4,
        uint256 _redemptionFraction
    ) public {
        uint256 boldAmount = 10000e18;
        uint256 minBoldBalance = 1;
        // TODO: remove gas compensation
        _spBoldAmount1 = bound(_spBoldAmount1, 0, boldAmount);
        _spBoldAmount2 = bound(_spBoldAmount2, 0, boldAmount);
        _spBoldAmount3 = bound(_spBoldAmount3, 0, boldAmount);
        _spBoldAmount4 = bound(_spBoldAmount4, 0, boldAmount - minBoldBalance);
        _redemptionFraction = bound(_redemptionFraction, DECIMAL_PRECISION / minBoldBalance, DECIMAL_PRECISION);

        _testMultiCollateralRedemption(
            boldAmount, _spBoldAmount1, _spBoldAmount2, _spBoldAmount3, _spBoldAmount4, _redemptionFraction
        );
    }

    function testMultiCollateralRedemptionMaxSPAmount() public {
        uint256 boldAmount = 10000e18;
        uint256 minBoldBalance = 1;

        _testMultiCollateralRedemption(
            boldAmount,
            boldAmount,
            boldAmount,
            boldAmount,
            boldAmount - minBoldBalance,
            DECIMAL_PRECISION / minBoldBalance
        );
    }

    function _testMultiCollateralRedemption(
        uint256 _boldAmount,
        uint256 _spBoldAmount1,
        uint256 _spBoldAmount2,
        uint256 _spBoldAmount3,
        uint256 _spBoldAmount4,
        uint256 _redemptionFraction
    ) internal {
        TestValues memory testValues1;
        TestValues memory testValues2;
        TestValues memory testValues3;
        TestValues memory testValues4;

        testValues1.price = contractsArray[0].priceFeed.getPrice();
        testValues2.price = contractsArray[1].priceFeed.getPrice();
        testValues3.price = contractsArray[2].priceFeed.getPrice();
        testValues4.price = contractsArray[3].priceFeed.getPrice();

        // First collateral
        openMulticollateralTroveNoHints100pctWithIndex(0, A, 0, 10e18, _boldAmount, 5e16);
        if (_spBoldAmount1 > 0) makeMulticollateralSPDepositAndClaim(0, A, _spBoldAmount1);

        // Second collateral
        testValues2.troveId = openMulticollateralTroveNoHints100pctWithIndex(1, A, 0, 100e18, _boldAmount, 5e16);
        if (_spBoldAmount2 > 0) makeMulticollateralSPDepositAndClaim(1, A, _spBoldAmount2);

        // Third collateral
        openMulticollateralTroveNoHints100pctWithIndex(2, A, 0, 10e18, _boldAmount, 5e16);
        if (_spBoldAmount3 > 0) makeMulticollateralSPDepositAndClaim(2, A, _spBoldAmount3);

        // Fourth collateral
        openMulticollateralTroveNoHints100pctWithIndex(3, A, 0, 10e18, _boldAmount, 5e16);
        if (_spBoldAmount4 > 0) makeMulticollateralSPDepositAndClaim(3, A, _spBoldAmount4);

        uint256 boldBalance = boldToken.balanceOf(A);
        // Check A’s final bal
        // TODO: change when we switch to new gas compensation
        //assertEq(boldToken.balanceOf(A), _boldAmount * 4 - _spBoldAmount1 - _spBoldAmount2 - _spBoldAmount3 - _spBoldAmount4, "Wrong Bold balance before redemption");
        // Stack too deep
        //assertEq(boldBalance, _boldAmount * 4 - _spBoldAmount1 - _spBoldAmount2 - _spBoldAmount3 - _spBoldAmount4 - 800e18, "Wrong Bold balance before redemption");

        uint256 redeemAmount = boldBalance * _redemptionFraction / DECIMAL_PRECISION;

        // initial balances
        testValues1.collInitialBalance = contractsArray[0].WETH.balanceOf(A);
        testValues2.collInitialBalance = contractsArray[1].WETH.balanceOf(A);
        testValues3.collInitialBalance = contractsArray[2].WETH.balanceOf(A);
        testValues4.collInitialBalance = contractsArray[3].WETH.balanceOf(A);

        testValues1.unbackedPortion = contractsArray[0].troveManager.getEntireSystemDebt() - _spBoldAmount1;
        testValues2.unbackedPortion = contractsArray[1].troveManager.getEntireSystemDebt() - _spBoldAmount2;
        testValues3.unbackedPortion = contractsArray[2].troveManager.getEntireSystemDebt() - _spBoldAmount3;
        testValues4.unbackedPortion = contractsArray[3].troveManager.getEntireSystemDebt() - _spBoldAmount4;
        uint256 totalUnbacked = testValues1.unbackedPortion + testValues2.unbackedPortion + testValues3.unbackedPortion
            + testValues4.unbackedPortion;

        testValues1.redeemAmount = redeemAmount * testValues1.unbackedPortion / totalUnbacked;
        testValues2.redeemAmount = redeemAmount * testValues2.unbackedPortion / totalUnbacked;
        testValues3.redeemAmount = redeemAmount * testValues3.unbackedPortion / totalUnbacked;
        testValues4.redeemAmount = redeemAmount * testValues4.unbackedPortion / totalUnbacked;

        // fees
        uint256 fee = collateralRegistry.getEffectiveRedemptionFeeInBold(redeemAmount);
        testValues1.fee = fee * testValues1.redeemAmount / redeemAmount * DECIMAL_PRECISION / testValues1.price;
        testValues2.fee = fee * testValues2.redeemAmount / redeemAmount * DECIMAL_PRECISION / testValues2.price;
        testValues3.fee = fee * testValues3.redeemAmount / redeemAmount * DECIMAL_PRECISION / testValues3.price;
        testValues4.fee = fee * testValues4.redeemAmount / redeemAmount * DECIMAL_PRECISION / testValues4.price;

        console.log(testValues1.fee, "fee1");
        console.log(testValues2.fee, "fee2");
        console.log(testValues3.fee, "fee3");
        console.log(testValues4.fee, "fee4");

        // A redeems
        vm.startPrank(A);
        collateralRegistry.redeemCollateral(redeemAmount, 0, 1e18);
        vm.stopPrank();

        // Check bold balance
        assertApproxEqAbs(boldToken.balanceOf(A), boldBalance - redeemAmount, 10, "Wrong Bold balance after redemption");

        // Check collateral balances
        // final balances
        testValues1.collFinalBalance = contractsArray[0].WETH.balanceOf(A);
        testValues2.collFinalBalance = contractsArray[1].WETH.balanceOf(A);
        testValues3.collFinalBalance = contractsArray[2].WETH.balanceOf(A);
        testValues4.collFinalBalance = contractsArray[3].WETH.balanceOf(A);

        console.log(redeemAmount, "redeemAmount");
        console.log(testValues1.unbackedPortion, "testValues1.unbackedPortion");
        console.log(totalUnbacked, "totalUnbacked");
        console.log(testValues1.redeemAmount, "partial redeem amount 1");
        assertApproxEqAbs(
            testValues1.collFinalBalance - testValues1.collInitialBalance,
            testValues1.redeemAmount * DECIMAL_PRECISION / testValues1.price - testValues1.fee,
            10,
            "Wrong Collateral 1 balance"
        );
        assertApproxEqAbs(
            testValues2.collFinalBalance - testValues2.collInitialBalance,
            testValues2.redeemAmount * DECIMAL_PRECISION / testValues2.price - testValues2.fee,
            10,
            "Wrong Collateral 2 balance"
        );
        assertApproxEqAbs(
            testValues3.collFinalBalance - testValues3.collInitialBalance,
            testValues3.redeemAmount * DECIMAL_PRECISION / testValues3.price - testValues3.fee,
            10,
            "Wrong Collateral 3 balance"
        );
        assertApproxEqAbs(
            testValues4.collFinalBalance - testValues4.collInitialBalance,
            testValues4.redeemAmount * DECIMAL_PRECISION / testValues4.price - testValues4.fee,
            10,
            "Wrong Collateral 4 balance"
        );
    }

    function testMultiCollRedemptionIncreasesRedeemerETHBalanceByCorrespondingETHLessTheETHFee() public {
        TestValues memory testValues0;
        TestValues memory testValues1;
        TestValues memory testValues2;
        TestValues memory testValues3;

        uint256 boldAmount = 100000e18;
        testValues0.spBoldAmount = boldAmount / 2;
        testValues1.spBoldAmount = boldAmount / 4;
        testValues2.spBoldAmount = boldAmount / 8;
        testValues3.spBoldAmount = boldAmount / 16;

        uint256 redemptionFraction = 25e16;

        testValues0.price = contractsArray[0].priceFeed.getPrice();
        testValues1.price = contractsArray[1].priceFeed.getPrice();
        testValues2.price = contractsArray[2].priceFeed.getPrice();
        testValues3.price = contractsArray[3].priceFeed.getPrice();

        // First collateral
        openMulticollateralTroveNoHints100pctWithIndex(0, A, 0, 100e18, boldAmount, 5e16);
        makeMulticollateralSPDepositAndClaim(0, A, testValues0.spBoldAmount);

        // Second collateral
        openMulticollateralTroveNoHints100pctWithIndex(1, A, 0, 1000e18, boldAmount, 5e16);
        makeMulticollateralSPDepositAndClaim(1, A, testValues1.spBoldAmount);

        // Third collateral
        openMulticollateralTroveNoHints100pctWithIndex(2, A, 0, 100e18, boldAmount, 5e16);
        makeMulticollateralSPDepositAndClaim(2, A, testValues2.spBoldAmount);

        // Fourth collateral
        openMulticollateralTroveNoHints100pctWithIndex(3, A, 0, 100e18, boldAmount, 5e16);
        makeMulticollateralSPDepositAndClaim(3, A, testValues3.spBoldAmount);

        uint256 boldBalance = boldToken.balanceOf(A);

        uint256 redeemAmount = boldBalance * redemptionFraction / DECIMAL_PRECISION;
        uint256 expectedFeePct =
            collateralRegistry.getEffectiveRedemptionFeeInBold(redeemAmount) * DECIMAL_PRECISION / redeemAmount;
        assertGt(expectedFeePct, 0);

        // Get BOLD debts from each branch
        testValues0.branchDebt = contractsArray[0].troveManager.getEntireSystemDebt();
        testValues1.branchDebt = contractsArray[1].troveManager.getEntireSystemDebt();
        testValues2.branchDebt = contractsArray[2].troveManager.getEntireSystemDebt();
        testValues3.branchDebt = contractsArray[3].troveManager.getEntireSystemDebt();

        testValues0.WETHBalBefore_A = contractsArray[0].WETH.balanceOf(A);
        testValues1.WETHBalBefore_A = contractsArray[1].WETH.balanceOf(A);
        testValues2.WETHBalBefore_A = contractsArray[2].WETH.balanceOf(A);
        testValues3.WETHBalBefore_A = contractsArray[3].WETH.balanceOf(A);

        // A redeems
        redeem(A, redeemAmount);

        // Check how much BOLD was redeemed from each branch
        testValues0.redeemed = testValues0.branchDebt - contractsArray[0].troveManager.getEntireSystemDebt();
        testValues1.redeemed = testValues1.branchDebt - contractsArray[1].troveManager.getEntireSystemDebt();
        testValues2.redeemed = testValues2.branchDebt - contractsArray[2].troveManager.getEntireSystemDebt();
        testValues3.redeemed = testValues3.branchDebt - contractsArray[3].troveManager.getEntireSystemDebt();

        assertGt(testValues0.redeemed, 0);
        assertGt(testValues1.redeemed, 0);
        assertGt(testValues2.redeemed, 0);
        assertGt(testValues3.redeemed, 0);

        // Get corresponding ETH from each branch, and fee
        testValues0.correspondingETH = testValues0.redeemed * DECIMAL_PRECISION / testValues0.price;
        testValues1.correspondingETH = testValues1.redeemed * DECIMAL_PRECISION / testValues1.price;
        testValues2.correspondingETH = testValues2.redeemed * DECIMAL_PRECISION / testValues2.price;
        testValues3.correspondingETH = testValues3.redeemed * DECIMAL_PRECISION / testValues3.price;

        testValues0.ETHFee = testValues0.correspondingETH * expectedFeePct / DECIMAL_PRECISION;
        testValues1.ETHFee = testValues1.correspondingETH * expectedFeePct / DECIMAL_PRECISION;
        testValues2.ETHFee = testValues2.correspondingETH * expectedFeePct / DECIMAL_PRECISION;
        testValues3.ETHFee = testValues3.correspondingETH * expectedFeePct / DECIMAL_PRECISION;
        assertGt(testValues0.ETHFee, 0);
        assertGt(testValues1.ETHFee, 0);
        assertGt(testValues2.ETHFee, 0);
        assertGt(testValues3.ETHFee, 0);

        // Expect WETH balance of redeemer increased by drawn ETH, leaving the ETH fee in the branch
        assertApproxEqAbs(
            contractsArray[0].WETH.balanceOf(A) - testValues0.WETHBalBefore_A,
            testValues0.correspondingETH - testValues0.ETHFee,
            20
        );
        assertApproxEqAbs(
            contractsArray[1].WETH.balanceOf(A) - testValues1.WETHBalBefore_A,
            testValues1.correspondingETH - testValues1.ETHFee,
            100
        );
        assertApproxEqAbs(
            contractsArray[2].WETH.balanceOf(A) - testValues2.WETHBalBefore_A,
            testValues2.correspondingETH - testValues2.ETHFee,
            20
        );
        assertApproxEqAbs(
            contractsArray[3].WETH.balanceOf(A) - testValues3.WETHBalBefore_A,
            testValues3.correspondingETH - testValues3.ETHFee,
            20
        );
    }
}