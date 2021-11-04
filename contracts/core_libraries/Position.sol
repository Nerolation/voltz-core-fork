// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "../utils/FullMath.sol";
import "../utils/FixedPoint128.sol";
import "../utils/LiquidityMath.sol";
import "prb-math/contracts/PRBMathSD59x18Typed.sol";

/// @title Position
/// @notice Positions represent an owner address' liquidity between a lower and upper tick boundary
/// @dev Positions store additional state for tracking fees owed to the position
library Position {
    // info stored for each user's position
    struct Info {
        // the amount of liquidity owned by this position
        uint128 liquidity;
        // fee growth per unit of liquidity as of the last update to liquidity or fees owed
        uint256 feeGrowthInsideLastX128;
        int256 margin;

        int256 fixedTokenGrowthInsideLast;
        int256 variableTokenGrowthInsideLast;
        
        int256 fixedTokenBalance;
        int256 variableTokenBalance;
    }

    /// @notice Returns the Info struct of a position, given an owner and position boundaries
    /// @param self The mapping containing all user positions
    /// @param owner The address of the position owner
    /// @param tickLower The lower tick boundary of the position
    /// @param tickUpper The upper tick boundary of the position
    /// @return position The position info struct of the given owners' position
    function get(
        mapping(bytes32 => Info) storage self,
        address owner,
        int24 tickLower,
        int24 tickUpper
    ) internal view returns (Position.Info storage position) {
        position = self[
            keccak256(abi.encodePacked(owner, tickLower, tickUpper))
        ];
    }

    /// @notice Credits accumulated fees to a user's position
    /// @param self The individual position to update
    /// @param liquidityDelta The change in pool liquidity as a result of the position update
    /// @param feeGrowthInsideX128 The all-time fee growth in underlyingToken, per unit of liquidity, inside the position's tick boundaries
    function update(
        Info storage self,
        int128 liquidityDelta,
        uint256 feeGrowthInsideX128,
        int256 updatedMargin,
        int256 fixedTokenGrowthInside,
        int256 variableTokenGrowthInside
    ) internal {
        Info memory _self = self;

        uint128 liquidityNext;
        if (liquidityDelta == 0) {
            require(_self.liquidity > 0, "NP"); // disallow pokes for 0 liquidity positions
            liquidityNext = _self.liquidity;
        } else {
            liquidityNext = LiquidityMath.addDelta(
                _self.liquidity,
                liquidityDelta
            );
        }

        // calculate accumuldated fixed and variable tokens
        int256 fixedTokenBalance = PRBMathSD59x18Typed.mul(
            
            PRBMathSD59x18Typed.sub(

                PRBMath.SD59x18({
                    value: fixedTokenGrowthInside
                }),

                PRBMath.SD59x18({
                    value: _self.fixedTokenGrowthInsideLast
                })
            ),

            PRBMath.SD59x18({
                value: int256(uint256(_self.liquidity))
            })

        ).value;


        int256 variableTokenBalance = PRBMathSD59x18Typed.mul(
            
            PRBMathSD59x18Typed.sub(

                PRBMath.SD59x18({
                    value: variableTokenGrowthInside
                }),

                PRBMath.SD59x18({
                    value: _self.variableTokenGrowthInsideLast
                })
            ),

            PRBMath.SD59x18({
                value: int256(uint256(_self.liquidity))
            })

        ).value;

        // update the position
        if (liquidityDelta != 0) self.liquidity = liquidityNext;
        self.feeGrowthInsideLastX128 = feeGrowthInsideX128;
        self.fixedTokenGrowthInsideLast = fixedTokenGrowthInside;
        self.variableTokenGrowthInsideLast = variableTokenGrowthInside;
        self.margin = updatedMargin;

        if (fixedTokenBalance > 0 || variableTokenBalance > 0) {
            
            self.fixedTokenBalance = PRBMathSD59x18Typed.add(

                PRBMath.SD59x18({
                    value: self.fixedTokenBalance
                }),

                PRBMath.SD59x18({
                    value: fixedTokenBalance
                })
            ).value;


            self.variableTokenBalance = PRBMathSD59x18Typed.add(

                PRBMath.SD59x18({
                    value: self.variableTokenBalance
                }),

                PRBMath.SD59x18({
                    value: variableTokenBalance
                })
            ).value;

        }


    }
}
