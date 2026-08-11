// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Arb Capital
pragma solidity ^0.8.28;

/// @dev Script- and test-facing declarations for the deployed FraxLend system, re-typed from the
///      verified sources of the live v5 `FraxlendPairDeployer` and a live v3.2.0 `FraxlendPair`.
///      Nothing in `src/` proper depends on these; the oracle's only coupling to FraxLend is the
///      `IDualOracle` shape it implements.

/// @title IFraxlendPairDeployer
/// @notice The whitelist-gated factory that instantiates pairs.
/// @dev `deploy()` reverts `WhitelistedDeployersOnly()` unless `msg.sender` passes the whitelist,
///      and reverts unless the deployer contract itself holds the seed amount of the ASSET token:
///      after CREATE2-ing the pair it deposits that seed into it. There is no public getter for
///      the seed amount -- only `setAmountToSeed()` -- so a rehearsal funds the deployer
///      generously rather than reading a number.
interface IFraxlendPairDeployer {
    /// @param configData abi.encode(address asset, address collateral, address oracle,
    ///        uint32 maxOracleDeviation, address rateContract, uint64 fullUtilizationRate,
    ///        uint256 maxLTV, uint256 liquidationFee, uint256 protocolLiquidationFee) --
    ///        nine fields, 288 bytes.
    function deploy(bytes memory configData) external returns (address pairAddress);
    function deployedPairsLength() external view returns (uint256);
    function getNextNameSymbol(address asset, address collateral)
        external
        view
        returns (string memory name, string memory symbol);
    function fraxlendWhitelistAddress() external view returns (address);
    function fraxlendPairRegistryAddress() external view returns (address);
    function version() external pure returns (uint256 major, uint256 minor, uint256 patch);
}

/// @title IFraxlendWhitelist
/// @notice The deployer whitelist the factory consults. Governance-owned; one mapping.
interface IFraxlendWhitelist {
    function fraxlendDeployerWhitelist(address deployer) external view returns (bool);
}

/// @title IFraxlendPair
/// @notice The subset of a deployed pair the market script's post-deploy assertions and the fork
///         rehearsal exercise. A pair is also an ERC-4626 vault over its asset token.
interface IFraxlendPair {
    // --- Wiring reads ---
    function asset() external view returns (address);
    function collateralContract() external view returns (address);
    function exchangeRateInfo()
        external
        view
        returns (
            address oracle,
            uint32 maxOracleDeviation,
            uint184 lastTimestamp,
            uint256 lowExchangeRate,
            uint256 highExchangeRate
        );
    function rateContract() external view returns (address);
    function maxLTV() external view returns (uint256);
    function cleanLiquidationFee() external view returns (uint256);
    function dirtyLiquidationFee() external view returns (uint256);
    function protocolLiquidationFee() external view returns (uint256);
    function version() external pure returns (uint256 major, uint256 minor, uint256 patch);

    // --- The oracle round-trip ---
    /// @dev Pulls `getPrices()` from the oracle, stores both rates, and reports whether the
    ///      low/high deviation is within `maxOracleDeviation` (new borrowing is refused when not).
    function updateExchangeRate()
        external
        returns (bool isBorrowAllowed, uint256 lowExchangeRate, uint256 highExchangeRate);

    // --- Lending / borrowing / liquidation, for the fork rehearsal ---
    function deposit(uint256 amount, address receiver) external returns (uint256 sharesReceived);
    function addCollateral(uint256 collateralAmount, address borrower) external;
    function borrowAsset(uint256 borrowAmount, uint256 collateralAmount, address receiver)
        external
        returns (uint256 sharesAdded);
    function repayAsset(uint256 shares, address borrower) external returns (uint256 amountToRepay);
    function liquidate(uint128 sharesToLiquidate, uint256 deadline, address borrower)
        external
        returns (uint256 collateralForLiquidator);
    function userBorrowShares(address user) external view returns (uint256);
    function userCollateralBalance(address user) external view returns (uint256);
    function totalBorrow() external view returns (uint128 amount, uint128 shares);
    function toBorrowAmount(uint256 shares, bool roundUp, bool previewInterest) external view returns (uint256 amount);
}

/// @title IERC20Minimal
/// @notice The three ERC-20 members the scripts and fork suite touch.
interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function decimals() external view returns (uint8);
}
