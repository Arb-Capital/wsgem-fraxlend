// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {WstGBPFrxUSDConstants, WstGBPFrxUSDMarketScript} from "../script/WstGBPFrxUSD.s.sol";

/// @dev Exposes the internal encoder so the pin suite can compare bytes, nothing more.
contract ConfigDataHarness is WstGBPFrxUSDMarketScript {
    function configData(address oracle_) external view returns (bytes memory) {
        return _configData(oracle_);
    }
}

/// @notice Byte-for-byte pins of the instance constants.
/// @dev Double-entry bookkeeping: every value in `script/WstGBPFrxUSD.s.sol` is retyped here from
///      the instance sheet in docs/, so an edit to either file breaks the suite unless both moved
///      together. Negative assertions also exclude legacy FRAX and its feed.
contract WstGBPFrxUSDDeployScriptTest is Test, WstGBPFrxUSDConstants {
    function test_theChainAndInfrastructureConstantsAreTheMainnetOnes() public pure {
        assertEq(CHAIN_ID(), 1);
        assertEq(PAIR_DEPLOYER(), 0xF767A82a188305461b6f01a7706f7Bc0ba941ffF);
        assertEq(WHITELIST(), 0xDc1cf6863b6100468479fE7dd3D2D1cDe7775265);
    }

    function test_theOracleWiringConstantsMatchTheInstanceSheet() public pure {
        assertEq(WSGEM(), 0x57C3571f10767E49C9d7b60feb6c67804783B7aE);
        assertEq(GEM(), 0x27f6c8289550fCE67f6B50BeD1F519966aFE5287);
        assertEq(ASSET(), 0xCAcd6fd266aF91b8AeD52aCCc382b4e165586E29);
        assertEq(GEM_USD_FEED(), 0x5c0Ab2d9b5a7ed9f470386e82BB36A3613cDd4b5);
        assertEq(ASSET_USD_FEED(), 0x9B4a96210bc8D9D55b1908B465D8B0de68B7fF83);
        assertEq(GEM_USD_MAX_DELAY(), 86_700);
        assertEq(ASSET_USD_MAX_DELAY(), 86_700);
        assertEq(QUOTE_DECIMALS(), 18);
        assertEq(ORACLE_NAME(), "frxUSD/wstGBP DualOracle");
    }

    function test_theOracleWriteBackSlotStartsUnset() public view {
        // Flips to the deployed address after `make oracle-deploy`; until then the market target
        // must refuse to run, and the oracle target must be willing to.
        assertEq(ORACLE(), address(0));
    }

    function test_theAssetIsFrxUsdAndNotLegacyFrax() public pure {
        assertTrue(ASSET() != 0x853d955aCEf822Db058eb8505911ED77F175b99e);
        assertTrue(ASSET_USD_FEED() != 0xB9E1E3A9feFf48998E45Fa90847ed4D467E8BcfD);
    }

    function test_theNameFitsTheOracleSingleWordCap() public pure {
        assertLe(bytes(ORACLE_NAME()).length, 32);
    }

    function test_theReviewedPairParameterProposalIsPinned() public pure {
        // The 5% deviation gate is an intentional tightening from the reference pair's live 10%.
        assertEq(MAX_ORACLE_DEVIATION(), 5_000);
        assertEq(RATE_CONTRACT(), 0x987a96c6637cF7E7B369BA7C1110d5fB69fb2d17);
        assertEq(FULL_UTILIZATION_RATE(), 9_494_822_760);
        assertEq(MAX_LTV(), 75_000);
        assertEq(LIQUIDATION_FEE(), 5_000);
        assertEq(PROTOCOL_LIQUIDATION_FEE(), 2_000);
    }

    function test_theSanityBandBracketsACollateralWorthMoreThanTheAsset() public pure {
        assertEq(MIN_PRICE(), 4e17);
        assertEq(MAX_PRICE(), 1e18);
        assertLt(MIN_PRICE(), MAX_PRICE());
        // Collateral-per-asset direction: a collateral worth MORE than the asset prices BELOW
        // 1e18. A band above 1e18 would mean the direction itself is misunderstood.
        assertLe(MAX_PRICE(), 1e18);
    }

    function test_theConfigDataEncodingIsExactlyTheNineFieldLayout() public {
        ConfigDataHarness harness_ = new ConfigDataHarness();
        address oracle_ = address(0xBEEF);

        bytes memory expected_ = abi.encode(
            0xCAcd6fd266aF91b8AeD52aCCc382b4e165586E29, // asset: frxUSD
            0x57C3571f10767E49C9d7b60feb6c67804783B7aE, // collateral: wstGBP
            oracle_, // oracle
            uint32(5_000), // maxOracleDeviation
            0x987a96c6637cF7E7B369BA7C1110d5fB69fb2d17, // rateContract: Variable Rate V3
            uint64(9_494_822_760), // fullUtilizationRate
            uint256(75_000), // maxLTV
            uint256(5_000), // liquidationFee (clean)
            uint256(2_000) // protocolLiquidationFee
        );

        bytes memory actual_ = harness_.configData(oracle_);
        assertEq(actual_.length, 288);
        assertEq(keccak256(actual_), keccak256(expected_));
    }
}
