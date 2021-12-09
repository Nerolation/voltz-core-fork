// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./interfaces/IDeployer.sol";
import "./VAMM.sol";
import "./AMM.sol";
import "./MarginEngine.sol";
import "./core_libraries/FixedAndVariableMath.sol";

contract Deployer is IDeployer {
  
  struct AMMParameters {
    address factory;
    address underlyingToken;
    bytes32 rateOracleId;
    uint256 termStartTimestamp;
    uint256 termEndTimestamp;
  }


  struct VAMMParameters {
    address ammAddress;
    uint24 fee;
    int24 tickSpacing;
  }

  struct MarginEngineParameters {
    address ammAddress;
  }


  AMMParameters public override ammParameters;
  VAMMParameters public override vammParameters;
  MarginEngineParameters public override marginEngineParameters;

  function deployMarginEngine(address ammAddress) internal returns (address marginEngine) {
    marginEngineParameters = MarginEngineParameters({
      ammAddress: ammAddress
    });

    marginEngine = address(
      new AMM{
        salt: keccak256(
          abi.encode(
            ammAddress
          )
        )
      }()
    );

    delete marginEngineParameters;

  }
  
  function deployVAMM(
    address ammAddress,
    uint24 fee, 
    int24 tickSpacing
  ) internal returns (address vamm) {
    
    vammParameters = VAMMParameters({
      ammAddress: ammAddress,
      fee: fee,
      tickSpacing: tickSpacing
    });

    vamm = address(
      new AMM{
        salt: keccak256(
          // think don't need tickSpacing here
          abi.encode(
            ammAddress,
            fee
          )
        )
      }()
    );
    delete vammParameters;
  }
  
  /// @dev Deploys an amm with the given parameters by transiently setting the parameters storage slot and then
  /// clearing it after deploying the amm.
  /// @param factory The contract address of the Voltz factory
  /// @param underlyingToken The contract address of the token in the underlying pool
  /// @param rateOracleId rate oracle id
  /// @param termEndTimestamp Number of days between the inception of the pool and its maturity
  function deployAMM(
    address factory,
    address underlyingToken,
    bytes32 rateOracleId,
    uint256 termStartTimestamp,
    uint256 termEndTimestamp
  ) internal returns (address amm) {

    ammParameters = AMMParameters({
      factory: factory,
      underlyingToken: underlyingToken,
      rateOracleId: rateOracleId,
      termStartTimestamp: termStartTimestamp,
      termEndTimestamp: termEndTimestamp
    });

    amm = address(
      new AMM{
        salt: keccak256(
          abi.encode(
            rateOracleId,
            underlyingToken, // todo: redundunt since the rateOracleId incorporates the underlying token?
            termStartTimestamp,
            termEndTimestamp
          )
        )
      }()
    );
    delete ammParameters;
  }
}
