// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;
import "./IAMM.sol";
import "./IVAMM.sol";
import "./IPositionStructs.sol";
import "../core_libraries/Position.sol";

interface IMarginEngine is IPositionStructs {
    // view functions

    function liquidatorReward() external view returns (uint256);

    /// @notice The address of the IRS AMM linked to this Margin Engine
    /// @return Interface of the IRS AMM linked to this Margin Engine
    function amm() external view returns (IAMM);

    /// @notice Returns the information about a position by the position's key
    /// @param owner The address of the position owner
    /// @param tickLower The lower tick boundary of the position
    /// @param tickUpper The upper tick boundary of the position
    /// Returns position The Position.Info corresponding to the equested position
    function getPosition(
        address owner,
        int24 tickLower,
        int24 tickUpper
    ) external view returns (Position.Info memory position);

    /// @notice Returns the information about a trader by the trader's key
    /// @param key The wallet address of the trader
    /// @return margin Margin (in terms of the underlying tokens) in the trader's Voltz account
    /// Returns fixedTokenBalance The fixed token balance of the tader, at the maturity this balance (if positive) can be redeemed for fixedTokenBalance * Term of the AMM in Years * 1%
    /// Returns variableTokenBalance The variable token balance of the tader, at the maturity this balance (if positive) can be redeemed for variableTokenBalance * Term of the AMM in Years * variable APY generated by the underlying varaible rates pool over the lifetime of the IRS AMM
    /// Returns settled A Trader is considered settled if after the maturity of the IRS AMM, the trader settled the IRS cash-flows generated by their fixed and variable token balances
    function traders(address key)
        external
        view
        returns (
            int256 margin,
            int256 fixedTokenBalance,
            int256 variableTokenBalance,
            bool settled
        );

    // non-view functions

    function setLiquidatorReward(uint256 _liquidatorReward) external;

    /// @notice Updates Position Margin
    /// @dev Must be called by the owner of the position (unless marginDelta is positive?)
    /// @param params Values necessary for the purposes of the updating the Position Margin (owner, tickLower, tickUpper, liquidityDelta)
    /// @param marginDelta Determines the updated margin of the position where the updated margin = current margin + marginDelta
    function updatePositionMargin(
        IPositionStructs.ModifyPositionParams memory params,
        int256 marginDelta
    ) external;

    /// @notice Updates the sender's Trader Margin
    /// @dev Must be called by the trader address
    /// @param marginDelta Determines the updated margin of the trader where the updated margin = current margin + marginDelta
    function updateTraderMargin(int256 marginDelta) external;

    /// @notice Settles a Position
    /// @dev Can be called by anyone
    /// @dev A position cannot be settled before maturity
    /// @dev Steps to settle a position:
    /// @dev 1. Retrieve the current fixed and variable token growth inside the tick range of a position
    /// @dev 2. Calculate accumulated fixed and variable balances of the position since the last mint/poke/burn
    /// @dev 3. Update the postion's fixed and variable token balances
    /// @dev 4. Update the postion's fixed and varaible token growth inside last to enable future updates
    /// @dev 5. Calculates the settlement cashflow from all of the IRS contracts the position has entered since entering the AMM
    /// @dev 6. Updates the fixed and variable token balances of the position to be zero, adds the settlement cashflow to the position's current margin
    /// @param params Values necessary for the purposes of referencing the position being settled (owner, tickLower, tickUpper, _)
    function settlePosition(IPositionStructs.ModifyPositionParams memory params)
        external;

    /// @notice Settles a Trader
    /// @dev Can be called by anyone
    /// @dev A Trader cannot be settled before IRS AMM maturity
    /// @dev Steps to settle: calculate settlement cashflow based on the fixed and variable balances of the trader, update the fixed and variable balances to 0, update the margin to account for IRS settlement cashflow
    function settleTrader() external;

    /// @notice Liquidate a Position
    /// @dev Steps to liquidate: update position's fixed and variable token balances to account for balances accumulated throughout the trades made since the last mint/burn/poke,
    /// @dev Check if the position is liquidatable by calling the isLiquidatablePosition function of the calculator,
    /// @dev Check if the position is liquidatable by calling the isLiquidatablePosition function of the calculator, revert if that is not the case,
    /// @dev Calculate the liquidation reward = current margin of the position * liquidatorReward, subtract the liquidator reward from the position margin,
    /// @dev Burn the position's liquidity ==> not going to enter into new IRS contracts until the AMM maturity, transfer the reward to the liquidator
    /// @param params necessary for the purposes of referencing the position being liquidated (owner, tickLower, tickUpper, _)
    function liquidatePosition(
        IPositionStructs.ModifyPositionParams memory params
    ) external;

    /// @notice Liquidate a Trader
    /// @dev Steps to liquidate: check if the trader is liquidatable (revert if that is not the case),
    /// @dev Calculate liquidator reward, subtract it from the trader margin, unwind the trader, transfer the reward to the liquidator
    /// @param traderAddress The address of the trader being liquidated
    function liquidateTrader(address traderAddress) external;

    /// @notice Update a Position
    /// @dev Steps taken:
    /// @dev 1. Update position liquidity based on params.liquidityDelta
    /// @dev 2. Update fixed and variable token balances of the position based on how much has been accumulated since the last mint/burn/poke
    /// @dev 3. Update position's margin by taking into account the position accumulated fees since the last mint/burnpoke
    /// @dev 4. Update fixed and variable token growth + fee growth in the position info struct for future interactions with the position
    /// @param params necessary for the purposes of referencing the position being updated (owner, tickLower, tickUpper, _)
    /// @param vars Relevant variables from vars: feeGrowthInside, fixedTokenGrowthInside and variabelTokenGrowthInside of the tick range of the given position
    function updatePosition(
        IPositionStructs.ModifyPositionParams memory params,
        IVAMM.UpdatePositionVars memory vars
    ) external;

    /// @notice Update Fixed and Variable Token Balances of a trader
    /// @dev Auth:
    /// @dev Steps taken:
    /// @dev 1. Update Fixed and Variable Token Balances of a trader
    /// @dev 2. Check if the initial margin requirement is still satisfied following the balances update, if that is not the case then revert
    /// @param recipient The address of the trader who wishes to update their balances
    /// @param fixedTokenBalance Current fixed token balance of a trader
    /// @param variableTokenBalance Current variable token balance of a trader
    function updateTraderBalances(
        address recipient,
        int256 fixedTokenBalance,
        int256 variableTokenBalance,
        bool isUnwind
    ) external;

    /// @notice Unwind a position
    /// @dev Auth:
    /// @dev Before unwinding a position, need to check if it is even necessary to unwind it, i.e. check if the most up to date variable token balance of a position is non-zero
    /// @dev If the current fixed token balance of a position is positive, this implies the position is a net Fixed Taker,
    /// @dev Hence to unwind need to enter into a Variable Taker IRS contract with notional = abs(current variable token balance)
    /// @param owner the owner of the position
    /// @param tickLower the lower tick of the position's tick range
    /// @param tickUpper the upper tick of the position's tick range
    function unwindPosition(
        address owner,
        int24 tickLower,
        int24 tickUpper
    )
        external
        returns (int256 _fixedTokenBalance, int256 _variableTokenBalance);

    function checkPositionMarginRequirementSatisfied(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount
    ) external;
}
