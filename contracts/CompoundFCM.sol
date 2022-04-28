// SPDX-License-Identifier: Apache-2.0

pragma solidity =0.8.9;

import "./interfaces/fcms/IFCM.sol";
import "./interfaces/fcms/ICompoundFCM.sol";
import "./storage/FCMStorage.sol";
import "./core_libraries/TraderWithYieldBearingAssets.sol";
import "./interfaces/IERC20Minimal.sol";
import "./interfaces/IVAMM.sol";
import "./interfaces/rate_oracles/ICompoundRateOracle.sol";
import "prb-math/contracts/PRBMathUD60x18.sol";
import "./core_libraries/FixedAndVariableMath.sol";
import "./interfaces/rate_oracles/IRateOracle.sol";
import "./utils/WadRayMath.sol";
import "./utils/Printer.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "./core_libraries/SafeTransferLib.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";

contract CompoundFCM is CompoundFCMStorage, IFCM, ICompoundFCM, Initializable, OwnableUpgradeable, PausableUpgradeable, UUPSUpgradeable {

  using WadRayMath for uint256;
  using SafeCast for uint256;
  using SafeCast for int256;

  using TraderWithYieldBearingAssets for TraderWithYieldBearingAssets.Info;

  using SafeTransferLib for IERC20Minimal;

  /// @dev modifier which checks if the msg.sender is not equal to the address of the MarginEngine, if that's the case, a revert is raised
  modifier onlyMarginEngine () {
    if (msg.sender != address(_marginEngine)) {
        revert CustomErrors.OnlyMarginEngine();
    }
    _;
  }

  // https://docs.openzeppelin.com/upgrades-plugins/1.x/writing-upgradeable
  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor () initializer {}

  /// @dev in the initialize function we set the vamm and the margiEngine associated with the fcm
  function initialize(IVAMM __vamm, IMarginEngine __marginEngine) external override initializer {
    /// @dev we additionally cache the rateOracle, _aaveLendingPool, underlyingToken, cToken
    _vamm = __vamm;
    _marginEngine = __marginEngine;
    _rateOracle = _marginEngine.rateOracle();
    underlyingToken = _marginEngine.underlyingToken();
    _ctoken = ICToken(ICompoundRateOracle(address(_rateOracle)).ctoken());
    tickSpacing = _vamm.tickSpacing(); // retrieve tick spacing of the VAM

    __Ownable_init();
    __Pausable_init();
    __UUPSUpgradeable_init();
  }

    // GETTERS FOR STORAGE SLOTS
    // Not auto-generated by public variables in the storage contract, cos solidity doesn't support that for functions that implement an interface
    /// @inheritdoc ICompoundFCM
    function cToken() external view override returns (ICToken) {
        return _ctoken;
    }
    /// @inheritdoc IFCM
    function marginEngine() external view override returns (IMarginEngine) {
        return _marginEngine;
    }
    /// @inheritdoc IFCM
    function vamm() external view override returns (IVAMM) {
        return _vamm;
    }
    /// @inheritdoc IFCM
    function rateOracle() external view override returns (IRateOracle) {
        return _rateOracle;
    }

  // To authorize the owner to upgrade the contract we implement _authorizeUpgrade with the onlyOwner modifier.
  // ref: https://forum.openzeppelin.com/t/uups-proxies-tutorial-solidity-javascript/7786
  function _authorizeUpgrade(address) internal override onlyOwner {}

  event FullyCollateralisedSwap(
    address indexed trader,
    uint256 marginInScaledYieldBearingTokens,
    int256 fixedTokenBalance,
    int256 variableTokenBalance
  );

  function getTraderWithYieldBearingAssets(
        address trader
    ) external override view returns (TraderWithYieldBearingAssets.Info memory traderInfo) {
      return traders[trader];
    }


  /// @notice Initiate a Fully Collateralised Fixed Taker Swap
  /// @param notional Notional that cover by a fully collateralised fixed taker interest rate swap
  /// @param sqrtPriceLimitX96 The binary fixed point math representation of the sqrtPriceLimit beyond which the fixed taker swap will not be executed with the VAMM
  function initiateFullyCollateralisedFixedTakerSwap(uint256 notional, uint160 sqrtPriceLimitX96) external override returns 
    (int256 fixedTokenDelta, int256 variableTokenDelta, uint256 cumulativeFeeIncurred, int256 fixedTokenDeltaUnbalanced) {

    require(notional!=0, "notional = 0");

    // suggestion: add support for approvals and recipient (similar to how it is implemented in the MarginEngine)

    // initiate a swap
    // the default tick range for a Position associated with the FCM is tickLower: -tickSpacing and tickUpper: tickSpacing
    // isExternal is true since the state updates following a VAMM induced swap are done in the FCM (below)
    IVAMM.SwapParams memory params = IVAMM.SwapParams({
        recipient: address(this),
        amountSpecified: notional.toInt256(),
        sqrtPriceLimitX96: sqrtPriceLimitX96,
        tickLower: -tickSpacing,
        tickUpper: tickSpacing
    });

    (fixedTokenDelta, variableTokenDelta, cumulativeFeeIncurred, fixedTokenDeltaUnbalanced,) = _vamm.swap(params);

    require(variableTokenDelta <=0, "VT delta sign");

    TraderWithYieldBearingAssets.Info storage trader = traders[msg.sender];

    // When dealing with wei (or smallest unit of tokens), rather than human denominations like USD and cUSD, we can simply
    // divide the underlying wei value by the exchange rate to get the number of ctoken wei
    uint256 currentExchangeRate = _ctoken.exchangeRateCurrent();

    uint256 yieldBearingTokenDelta = uint256(-variableTokenDelta).wadDiv(currentExchangeRate);
    uint256 updatedTraderMargin = trader.marginInScaledYieldBearingTokens + yieldBearingTokenDelta;
    trader.updateMarginInScaledYieldBearingTokens(updatedTraderMargin);

    // update trader fixed and variable token balances
    trader.updateBalancesViaDeltas(fixedTokenDelta, variableTokenDelta);

    // deposit notional executed in terms of cTokens (e.g. cDAI) to fully collateralise the position
    // we need a number of tokens equal to the variable token delta divided by the exchange rate
    IERC20Minimal(address(_ctoken)).safeTransferFrom(msg.sender, address(this), yieldBearingTokenDelta);

    // transfer fees to the margin engine (in terms of the underlyingToken e.g. cDAI)
    underlyingToken.safeTransferFrom(msg.sender, address(_marginEngine), cumulativeFeeIncurred);

    emit FullyCollateralisedSwap(
      msg.sender,
      notional,
      sqrtPriceLimitX96,
      cumulativeFeeIncurred,
      fixedTokenDelta, 
      variableTokenDelta,
      fixedTokenDeltaUnbalanced
    );

    emit FCMTraderUpdate(
      msg.sender,
      trader.marginInScaledYieldBearingTokens,
      trader.fixedTokenBalance,
      trader.variableTokenBalance
    );  }

  /// @notice Get Trader Margin In Yield Bearing Tokens
  /// @dev this function takes the scaledBalance associated with a trader and multiplies it by the current Exchange Rate to get the balance (margin) in terms of the underlying token
  /// @param traderMarginInScaledYieldBearingTokens traderMarginInScaledYieldBearingTokens
  function getTraderMarginInYieldBearingTokens(uint256 traderMarginInScaledYieldBearingTokens) internal view returns (uint256 marginInYieldBearingTokens) {
    // uint256 currentExchangeRate = _ctoken.exchangeRateStored();
    // marginInYieldBearingTokens = traderMarginInScaledYieldBearingTokens.rayMul(currentExchangeRate);
    return traderMarginInScaledYieldBearingTokens; // NO scaling to do here. Delete this function?
  }

  function getTraderMarginInCTokens(address traderAddress)
        external
        view
        returns (uint256 marginInYieldBearingTokens)
    {
        TraderWithYieldBearingAssets.Info storage trader = traders[
            traderAddress
        ];
        marginInYieldBearingTokens = trader.marginInScaledYieldBearingTokens;
    }


  /// @notice Unwind Fully Collateralised Fixed Taker Swap
  /// @param notionalToUnwind The amount of notional to unwind (stop securing with a fixed rate)
  /// @param sqrtPriceLimitX96 The sqrt price limit (binary fixed point notation) beyond which the unwind cannot progress
  function unwindFullyCollateralisedFixedTakerSwap(uint256 notionalToUnwind, uint160 sqrtPriceLimitX96) external override returns 
    (int256 fixedTokenDelta, int256 variableTokenDelta, uint256 cumulativeFeeIncurred, int256 fixedTokenDeltaUnbalanced) {

    TraderWithYieldBearingAssets.Info storage trader = traders[msg.sender];

    require(trader.variableTokenBalance <= 0, "Trader VT balance positive");

    /// @dev it is impossible to unwind more variable token exposure than the user already has
    /// @dev hence, the notionalToUnwind needs to be <= absolute value of the variable token balance of the trader
    require(uint256(-trader.variableTokenBalance) >= notionalToUnwind, "notional to unwind > notional");

    // initiate a swap
    /// @dev as convention, specify the tickLower to be equal to -tickSpacing and tickUpper to be equal to tickSpacing
    // since the unwind is in the Variable Taker direction, the amountSpecified needs to be exact output => needs to be negative = -int256(notionalToUnwind),
    IVAMM.SwapParams memory params = IVAMM.SwapParams({
        recipient: address(this),
        amountSpecified: -notionalToUnwind.toInt256(),
        sqrtPriceLimitX96: sqrtPriceLimitX96,
        tickLower: -tickSpacing,
        tickUpper: tickSpacing
    });

    (fixedTokenDelta, variableTokenDelta, cumulativeFeeIncurred, fixedTokenDeltaUnbalanced,) = _vamm.swap(params);

    require(variableTokenDelta >= 0, "VT delta negative");

    // update trader fixed and variable token balances
    (int256 _fixedTokenBalance, int256 _variableTokenBalance) = trader.updateBalancesViaDeltas(fixedTokenDelta, variableTokenDelta);

    uint256 currentExchangeRate = _ctoken.exchangeRateStored();

    uint256 updatedTraderMargin = trader.marginInScaledYieldBearingTokens - uint256(variableTokenDelta).wadDiv(currentExchangeRate);
    trader.updateMarginInScaledYieldBearingTokens(updatedTraderMargin);

    // check the margin requirement of the trader post unwind, if the current balances still support the unwind, they it can happen, otherwise the unwind will get reverted
    checkMarginRequirement(_fixedTokenBalance, _variableTokenBalance, trader.marginInScaledYieldBearingTokens);

    // transfer fees to the margin engine
    underlyingToken.safeTransferFrom(msg.sender, address(_marginEngine), cumulativeFeeIncurred);

    // transfer the yield bearing tokens to trader address and update margin in terms of yield bearing tokens
    // variable token delta should be positive
    IERC20Minimal(address(_ctoken)).safeTransfer(msg.sender, uint256(variableTokenDelta));

    emit FullyCollateralisedUnwind(
      msg.sender,
      notionalToUnwind,
      sqrtPriceLimitX96,
      cumulativeFeeIncurred,
      fixedTokenDelta, 
      variableTokenDelta,
      fixedTokenDeltaUnbalanced
    );

    emit FCMTraderUpdate(
      msg.sender,
      trader.marginInScaledYieldBearingTokens,
      trader.fixedTokenBalance,
      trader.variableTokenBalance
    );
  }


  /// @notice Check Margin Requirement post unwind of a fully collateralised fixed taker
  function checkMarginRequirement(int256 traderFixedTokenBalance, int256 traderVariableTokenBalance, uint256 traderMarginInScaledYieldBearingTokens) internal {

    // variable token balance should never be positive
    // margin in scaled tokens should cover the variable leg from now to maturity

    /// @dev we can be confident the variable token balance of a fully collateralised fixed taker is always going to be negative (or zero)
    /// @dev hence, we can assume that the variable cashflows from now to maturity is covered by a portion of the trader's collateral in yield bearing tokens
    /// @dev once future variable cashflows are covered, we need to check if the remaining settlement cashflow is covered by the remaining margin in yield bearing tokens

    // @audit: casting variableTokenDelta is expected to be positive here, but what if goes below 0 due to rounding imprecision?
    uint256 marginToCoverVariableLegFromNowToMaturity = uint256(-traderVariableTokenBalance);
    int256 marginToCoverRemainingSettlementCashflow = int256(getTraderMarginInYieldBearingTokens(traderMarginInScaledYieldBearingTokens)) - int256(marginToCoverVariableLegFromNowToMaturity);

    int256 remainingSettlementCashflow = calculateRemainingSettlementCashflow(traderFixedTokenBalance, traderVariableTokenBalance);

    if (remainingSettlementCashflow < 0) {

      if (-remainingSettlementCashflow > marginToCoverRemainingSettlementCashflow) {
        revert CustomErrors.MarginRequirementNotMetFCM(int256(marginToCoverVariableLegFromNowToMaturity) + remainingSettlementCashflow);
      }

    }

  }


  /// @notice Calculate remaining settlement cashflow
  function calculateRemainingSettlementCashflow(int256 traderFixedTokenBalance, int256 traderVariableTokenBalance) internal returns (int256 remainingSettlementCashflow) {

    int256 fixedTokenBalanceWad = PRBMathSD59x18.fromInt(traderFixedTokenBalance);

    int256 variableTokenBalanceWad = PRBMathSD59x18.fromInt(
        traderVariableTokenBalance
    );

    /// @dev fixed cashflow based on the full term of the margin engine
    int256 fixedCashflowWad = PRBMathSD59x18.mul(
      fixedTokenBalanceWad,
      int256(
        FixedAndVariableMath.fixedFactor(true, _marginEngine.termStartTimestampWad(), _marginEngine.termEndTimestampWad())
      )
    );

    int256 variableFactorFromTermStartTimestampToNow = int256(_rateOracle.variableFactor(
      _marginEngine.termStartTimestampWad(),
      _marginEngine.termEndTimestampWad()
    ));

    /// @dev variable cashflow form term start timestamp to now
    int256 variableCashflowWad = PRBMathSD59x18.mul(
      variableTokenBalanceWad,
      variableFactorFromTermStartTimestampToNow
    );

    /// @dev the total cashflows as a sum of fixed and variable cashflows
    int256 cashflowWad = fixedCashflowWad + variableCashflowWad;

    /// @dev convert back to non-fixed point representation
    remainingSettlementCashflow = PRBMathSD59x18.toInt(cashflowWad);

  }

  modifier onlyAfterMaturity () {
    if (_marginEngine.termEndTimestampWad() > Time.blockTimestampScaled()) {
        revert CannotSettleBeforeMaturity();
    }
    _;
  }

  /// @notice Settle Trader
  /// @dev This function lets us settle a fully collateralised fixed taker position post term end timestamp of the MarginEngine
  /// @dev the settlement cashflow is calculated by invoking the calculateSettlementCashflow function of FixedAndVariableMath.sol (based on the fixed and variable token balance)
  /// @dev if the settlement cashflow of the trader is positive, then the settleTrader() function invokes the transferMarginToFCMTrader function of the MarginEngine which transfers the settlement cashflow the trader in terms of the underlying tokens
  /// @dev if settlement cashflow of the trader is negative, we need to update trader's margin in terms of scaled yield bearing tokens to account the settlement casflow
  /// @dev once settlement cashflows are accounted for, we safeTransfer the scaled yield bearing tokens in the margin account of the trader back to their wallet address
  function settleTrader() external override onlyAfterMaturity returns (int256 traderSettlementCashflow) {

    TraderWithYieldBearingAssets.Info storage trader = traders[msg.sender];

    int256 settlementCashflow = FixedAndVariableMath.calculateSettlementCashflow(trader.fixedTokenBalance, trader.variableTokenBalance, _marginEngine.termStartTimestampWad(), _marginEngine.termEndTimestampWad(), _rateOracle.variableFactor(_marginEngine.termStartTimestampWad(), _marginEngine.termEndTimestampWad()));
    trader.updateBalancesViaDeltas(-trader.fixedTokenBalance, -trader.variableTokenBalance);

    if (settlementCashflow < 0) {
      uint256 currentExchangeRate = _ctoken.exchangeRateStored();
      uint256 updatedTraderMarginInScaledYieldBearingTokens = trader.marginInScaledYieldBearingTokens - uint256(-settlementCashflow).wadDiv(currentExchangeRate);
      trader.updateMarginInScaledYieldBearingTokens(updatedTraderMarginInScaledYieldBearingTokens);
    }

    // if settlement happens late, additional variable yield beyond maturity will accrue to the trader
    uint256 traderMarginInYieldBearingTokens = getTraderMarginInYieldBearingTokens(trader.marginInScaledYieldBearingTokens);
    trader.updateMarginInScaledYieldBearingTokens(0);
    trader.settleTrader();
    IERC20Minimal(address(_ctoken)).safeTransfer(msg.sender, traderMarginInYieldBearingTokens);
    if (settlementCashflow > 0) {
      // transfers margin in terms of underlying tokens (e.g. USDC) from the margin engine to the msg.sender
      // as long as the margin engine is active and solvent it shoudl be able to cover the settlement cashflows of the fully collateralised traders
      _marginEngine.transferMarginToFCMTrader(msg.sender, uint256(settlementCashflow));
    }

    return settlementCashflow;
  }


  /// @notice Transfer Margin (in underlying tokens) from the FCM to a MarginEngine trader
  /// @dev in case of Compound this is done by redeeming the underlying token directly from the cToken: https://compound.finance/docs/ctokens#redeem-underlying
  function transferMarginToMarginEngineTrader(address account, uint256 marginDeltaInUnderlyingTokens) external onlyMarginEngine whenNotPaused override {
    if (underlyingToken.balanceOf(address(_ctoken)) >= marginDeltaInUnderlyingTokens) {
      require(_ctoken.redeemUnderlying(marginDeltaInUnderlyingTokens) == 0); // Require success
    } else {
      IERC20Minimal(address(_ctoken)).safeTransfer(account, marginDeltaInUnderlyingTokens);
    }
  }


}