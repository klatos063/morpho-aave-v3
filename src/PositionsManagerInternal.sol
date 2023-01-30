// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.17;

import {IPriceOracleSentinel} from "@aave-v3-core/interfaces/IPriceOracleSentinel.sol";

import {Types} from "./libraries/Types.sol";
import {Events} from "./libraries/Events.sol";
import {Errors} from "./libraries/Errors.sol";
import {Constants} from "./libraries/Constants.sol";
import {MarketLib} from "./libraries/MarketLib.sol";
import {DeltasLib} from "./libraries/DeltasLib.sol";
import {MarketSideDeltaLib} from "./libraries/MarketSideDeltaLib.sol";
import {MarketBalanceLib} from "./libraries/MarketBalanceLib.sol";

import {DataTypes} from "@aave-v3-core/protocol/libraries/types/DataTypes.sol";
import {ReserveConfiguration} from "@aave-v3-core/protocol/libraries/configuration/ReserveConfiguration.sol";

import {Math} from "@morpho-utils/math/Math.sol";
import {WadRayMath} from "@morpho-utils/math/WadRayMath.sol";
import {PercentageMath} from "@morpho-utils/math/PercentageMath.sol";

import {LogarithmicBuckets} from "@morpho-data-structures/LogarithmicBuckets.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {MatchingEngine} from "./MatchingEngine.sol";

import {ERC20} from "@solmate/tokens/ERC20.sol";

abstract contract PositionsManagerInternal is MatchingEngine {
    using Math for uint256;
    using WadRayMath for uint256;
    using PercentageMath for uint256;
    using MarketLib for Types.Market;
    using DeltasLib for Types.Deltas;
    using MarketSideDeltaLib for Types.MarketSideDelta;
    using MarketBalanceLib for Types.MarketBalances;
    using EnumerableSet for EnumerableSet.AddressSet;
    using LogarithmicBuckets for LogarithmicBuckets.BucketList;
    using ReserveConfiguration for DataTypes.ReserveConfigurationMap;

    /// @dev Validates the manager's permission.
    function _validatePermission(address delegator, address manager) internal view {
        if (!(delegator == manager || _isManaging[delegator][manager])) revert Errors.PermissionDenied();
    }

    /// @dev Validates the input.
    function _validateInput(address underlying, uint256 amount, address user)
        internal
        view
        returns (Types.Market storage market)
    {
        if (user == address(0)) revert Errors.AddressIsZero();
        if (amount == 0) revert Errors.AmountIsZero();

        market = _market[underlying];
        if (!market.isCreated()) revert Errors.MarketNotCreated();
    }

    /// @dev Validates the manager's permission and the input.
    function _validateManagerInput(address underlying, uint256 amount, address onBehalf, address receiver)
        internal
        view
        returns (Types.Market storage market)
    {
        if (receiver == address(0)) revert Errors.AddressIsZero();

        market = _validateInput(underlying, amount, onBehalf);

        _validatePermission(onBehalf, msg.sender);
    }

    /// @dev Validates a supply action.
    function _validateSupply(address underlying, uint256 amount, address user)
        internal
        view
        returns (Types.Market storage market)
    {
        market = _validateInput(underlying, amount, user);
        if (market.isSupplyPaused()) revert Errors.SupplyIsPaused();
    }

    /// @dev Validates a supply collateral action.
    function _validateSupplyCollateral(address underlying, uint256 amount, address user)
        internal
        view
        returns (Types.Market storage market)
    {
        market = _validateInput(underlying, amount, user);
        if (market.isSupplyCollateralPaused()) revert Errors.SupplyCollateralIsPaused();
    }

    /// @dev Authorizes a supply collateral action.
    function _authorizeSupplyCollateral(
        address underlying,
        uint256 amount,
        Types.Market storage market,
        Types.Indexes256 memory indexes
    ) internal view {
        Types.MarketSideDelta memory delta = _market[underlying].deltas.supply;
        uint256 totalP2P = delta.scaledTotalP2P.rayMul(indexes.supply.p2pIndex).zeroFloorSub(
            delta.scaledDeltaPool.rayMul(indexes.supply.poolIndex)
        );

        DataTypes.ReserveConfigurationMap memory config = _POOL.getConfiguration(underlying);
        uint256 supplyCap = config.getSupplyCap() * (10 ** config.getDecimals());
        uint256 totalSupply = ERC20(market.aToken).totalSupply();

        // The total P2P amount on Morpho plus the total supply on Aave must not exceed the supply cap.
        if (amount + totalP2P + totalSupply > supplyCap) revert Errors.ExceedsSupplyCap();
    }

    /// @dev Validates a borrow action.
    function _validateBorrow(address underlying, uint256 amount, address borrower, address receiver)
        internal
        view
        returns (Types.Market storage market)
    {
        market = _validateManagerInput(underlying, amount, borrower, receiver);
        if (market.isBorrowPaused()) revert Errors.BorrowIsPaused();
    }

    /// @dev Authorizes a borrow action.
    function _authorizeBorrow(
        address underlying,
        uint256 amount,
        address borrower,
        Types.Market storage market,
        Types.Indexes256 memory indexes
    ) internal view {
        DataTypes.ReserveData memory reserve = _POOL.getReserveData(underlying);
        DataTypes.ReserveConfigurationMap memory config = reserve.configuration;
        if (!config.getBorrowingEnabled()) revert Errors.BorrowingNotEnabled();
        if (_E_MODE_CATEGORY_ID != 0 && _E_MODE_CATEGORY_ID != config.getEModeCategory()) {
            revert Errors.InconsistentEMode();
        }

        Types.MarketSideDelta memory delta = market.deltas.borrow;
        uint256 totalP2P = delta.scaledTotalP2P.rayMul(indexes.borrow.p2pIndex).zeroFloorSub(
            delta.scaledDeltaPool.rayMul(indexes.borrow.poolIndex)
        );

        uint256 borrowCap = config.getBorrowCap() * (10 ** config.getDecimals());
        uint256 totalDebt = ERC20(market.variableDebtToken).totalSupply() + ERC20(market.stableDebtToken).totalSupply();

        // The total P2P amount on Morpho plus the total borrow on Aave must not exceed the borrow cap.
        if (amount + totalP2P + totalDebt > borrowCap) revert Errors.ExceedsBorrowCap();

        Types.LiquidityData memory values = _liquidityData(underlying, borrower, 0, amount);
        if (values.debt > values.borrowable) revert Errors.UnauthorizedBorrow();
    }

    /// @dev Validates a repay action.
    function _validateRepay(address underlying, uint256 amount, address user)
        internal
        view
        returns (Types.Market storage market)
    {
        market = _validateInput(underlying, amount, user);
        if (market.isRepayPaused()) revert Errors.RepayIsPaused();
    }

    /// @dev Validates a withdraw action.
    function _validateWithdraw(address underlying, uint256 amount, address supplier, address receiver)
        internal
        view
        returns (Types.Market storage market)
    {
        market = _validateManagerInput(underlying, amount, supplier, receiver);
        if (market.isWithdrawPaused()) revert Errors.WithdrawIsPaused();
    }

    /// @dev Validates a withdraw collateral action.
    function _validateWithdrawCollateral(address underlying, uint256 amount, address supplier, address receiver)
        internal
        view
        returns (Types.Market storage market)
    {
        market = _validateManagerInput(underlying, amount, supplier, receiver);
        if (market.isWithdrawCollateralPaused()) revert Errors.WithdrawCollateralIsPaused();
    }

    /// @dev Authorizes a withdraw collateral action.
    function _authorizeWithdrawCollateral(address underlying, uint256 amount, address supplier) internal view {
        if (_getUserHealthFactor(underlying, supplier, amount) < Constants.DEFAULT_LIQUIDATION_THRESHOLD) {
            revert Errors.UnauthorizedWithdraw();
        }
    }

    /// @dev Authorizes a liquidate action.
    function _authorizeLiquidate(address underlyingBorrowed, address underlyingCollateral, address borrower)
        internal
        view
        returns (uint256)
    {
        if (borrower == address(0)) revert Errors.AddressIsZero();

        Types.Market storage borrowMarket = _market[underlyingBorrowed];
        Types.Market storage collateralMarket = _market[underlyingCollateral];

        if (!collateralMarket.isCreated() || !borrowMarket.isCreated()) revert Errors.MarketNotCreated();

        if (collateralMarket.isLiquidateCollateralPaused()) revert Errors.LiquidateCollateralIsPaused();
        if (borrowMarket.isLiquidateBorrowPaused()) revert Errors.LiquidateBorrowIsPaused();

        if (borrowMarket.isDeprecated()) return Constants.MAX_CLOSE_FACTOR; // Allow liquidation of the whole debt.

        uint256 healthFactor = _getUserHealthFactor(address(0), borrower, 0);
        if (healthFactor >= Constants.DEFAULT_LIQUIDATION_THRESHOLD) {
            revert Errors.UnauthorizedLiquidate();
        }

        if (healthFactor >= Constants.MIN_LIQUIDATION_THRESHOLD) {
            address priceOracleSentinel = _ADDRESSES_PROVIDER.getPriceOracleSentinel();

            if (priceOracleSentinel != address(0) && !IPriceOracleSentinel(priceOracleSentinel).isLiquidationAllowed())
            {
                revert Errors.UnauthorizedLiquidate();
            }

            return Constants.DEFAULT_CLOSE_FACTOR;
        }

        return Constants.MAX_CLOSE_FACTOR;
    }

    /// @dev Performs the accounting of a supply action.
    function _accountSupply(
        address underlying,
        uint256 amount,
        address onBehalf,
        uint256 maxIterations,
        Types.Indexes256 memory indexes
    ) internal returns (Types.SupplyRepayVars memory vars) {
        Types.Deltas storage deltas = _market[underlying].deltas;
        Types.MarketBalances storage marketBalances = _marketBalances[underlying];
        vars.onPool = marketBalances.scaledPoolSupplyBalance(onBehalf);
        vars.inP2P = marketBalances.scaledP2PSupplyBalance(onBehalf);

        /// Peer-to-peer supply ///

        // Decrease the peer-to-peer borrow delta.
        (amount, vars.toRepay) = deltas.borrow.decreaseDelta(underlying, amount, indexes.borrow.poolIndex, true);

        // Promote pool borrowers.
        uint256 promoted;
        (promoted, amount,) = _promoteRoutine(underlying, amount, maxIterations, _promoteBorrowers);
        vars.toRepay += promoted;

        // Update the peer-to-peer totals.
        vars.inP2P += deltas.increaseP2P(underlying, promoted, vars.toRepay, indexes, true);

        /// Pool supply ///

        // Supply on pool.
        (vars.toSupply, vars.onPool) = _addToPool(amount, vars.onPool, indexes.supply.poolIndex);

        _updateSupplierInDS(underlying, onBehalf, vars.onPool, vars.inP2P, false);
    }

    /// @dev Performs the accounting of a borrow action.
    function _accountBorrow(
        address underlying,
        uint256 amount,
        address borrower,
        uint256 maxIterations,
        Types.Indexes256 memory indexes
    ) internal returns (Types.BorrowWithdrawVars memory vars) {
        Types.Market storage market = _market[underlying];
        Types.MarketBalances storage marketBalances = _marketBalances[underlying];
        vars.onPool = marketBalances.scaledPoolBorrowBalance(borrower);
        vars.inP2P = marketBalances.scaledP2PBorrowBalance(borrower);

        /// Peer-to-peer borrow ///

        // Decrease the peer-to-peer idle supply.
        uint256 matchedIdle;
        (amount, matchedIdle) = market.decreaseIdle(underlying, amount);

        // Decrease the peer-to-peer supply delta.
        (amount, vars.toWithdraw) =
            market.deltas.supply.decreaseDelta(underlying, amount, indexes.supply.poolIndex, false);

        // Promote pool suppliers.
        uint256 promoted;
        (promoted, amount,) = _promoteRoutine(underlying, amount, maxIterations, _promoteSuppliers);
        vars.toWithdraw += promoted;

        // Update the peer-to-peer totals.
        vars.inP2P += market.deltas.increaseP2P(underlying, promoted, vars.toWithdraw + matchedIdle, indexes, false);

        /// Pool borrow ///

        // Borrow on pool.
        (vars.toBorrow, vars.onPool) = _addToPool(amount, vars.onPool, indexes.borrow.poolIndex);

        _updateBorrowerInDS(underlying, borrower, vars.onPool, vars.inP2P, false);
    }

    /// @dev Performs the accounting of a repay action.
    function _accountRepay(
        address underlying,
        uint256 amount,
        address onBehalf,
        uint256 maxIterations,
        Types.Indexes256 memory indexes
    ) internal returns (Types.SupplyRepayVars memory vars) {
        Types.MarketBalances storage marketBalances = _marketBalances[underlying];
        vars.onPool = marketBalances.scaledPoolBorrowBalance(onBehalf);
        vars.inP2P = marketBalances.scaledP2PBorrowBalance(onBehalf);

        /// Pool repay ///

        // Repay borrow on pool.
        (vars.toRepay, amount, vars.onPool) = _subFromPool(amount, vars.onPool, indexes.borrow.poolIndex);

        // Repay borrow peer-to-peer.
        vars.inP2P = vars.inP2P.zeroFloorSub(amount.rayDivUp(indexes.borrow.p2pIndex)); // In peer-to-peer borrow unit.

        _updateBorrowerInDS(underlying, onBehalf, vars.onPool, vars.inP2P, false);

        if (amount == 0) return vars;

        Types.Market storage market = _market[underlying];

        // Decrease the peer-to-peer borrow delta.
        uint256 toRepayStep;
        (amount, toRepayStep) = market.deltas.borrow.decreaseDelta(underlying, amount, indexes.borrow.poolIndex, true);
        vars.toRepay += toRepayStep;
        uint256 p2pTotalBorrowDecrease = toRepayStep;

        // Repay the fee.
        amount = market.deltas.repayFee(amount, indexes);

        /// Transfer repay ///

        // Promote pool borrowers.
        (toRepayStep, vars.toSupply, maxIterations) =
            _promoteRoutine(underlying, amount, maxIterations, _promoteBorrowers);
        vars.toRepay += toRepayStep;

        /// Breaking repay ///

        // Demote peer-to-peer suppliers.
        uint256 demoted = _demoteSuppliers(underlying, vars.toSupply, maxIterations);

        // Increase the peer-to-peer supply delta.
        market.deltas.supply.increaseDelta(underlying, vars.toSupply - demoted, indexes.supply, false);

        // Update the peer-to-peer totals.
        market.deltas.decreaseP2P(underlying, demoted, vars.toSupply + p2pTotalBorrowDecrease, indexes, false);

        // Handle the supply cap.
        vars.toSupply = market.increaseIdle(underlying, vars.toSupply, _POOL.getConfiguration(underlying));
    }

    /// @dev Performs the accounting of a withdraw action.
    function _accountWithdraw(
        address underlying,
        uint256 amount,
        address supplier,
        uint256 maxIterations,
        Types.Indexes256 memory indexes
    ) internal returns (Types.BorrowWithdrawVars memory vars) {
        Types.MarketBalances storage marketBalances = _marketBalances[underlying];
        vars.onPool = marketBalances.scaledPoolSupplyBalance(supplier);
        vars.inP2P = marketBalances.scaledP2PSupplyBalance(supplier);

        /// Pool withdraw ///

        // Withdraw supply on pool.
        (vars.toWithdraw, amount, vars.onPool) = _subFromPool(amount, vars.onPool, indexes.supply.poolIndex);

        Types.Market storage market = _market[underlying];

        // Withdraw supply peer-to-peer.
        vars.inP2P = vars.inP2P.zeroFloorSub(amount.rayDivUp(indexes.supply.p2pIndex)); // In peer-to-peer supply unit.

        _updateSupplierInDS(underlying, supplier, vars.onPool, vars.inP2P, false);

        if (amount == 0) return vars;

        // Decrease the peer-to-peer idle supply.
        uint256 matchedIdle;
        (amount, matchedIdle) = market.decreaseIdle(underlying, amount);

        // Decrease the peer-to-peer supply delta.
        uint256 toWithdrawStep;
        (amount, toWithdrawStep) =
            market.deltas.supply.decreaseDelta(underlying, amount, indexes.supply.poolIndex, false);
        vars.toWithdraw += toWithdrawStep;
        uint256 p2pTotalSupplyDecrease = toWithdrawStep + matchedIdle;

        /// Transfer withdraw ///

        // Promote pool suppliers.
        (toWithdrawStep, vars.toBorrow, maxIterations) =
            _promoteRoutine(underlying, amount, maxIterations, _promoteSuppliers);
        vars.toWithdraw += toWithdrawStep;

        /// Breaking withdraw ///

        // Demote peer-to-peer borrowers.
        uint256 demoted = _demoteBorrowers(underlying, vars.toBorrow, maxIterations);

        // Increase the peer-to-peer borrow delta.
        market.deltas.borrow.increaseDelta(underlying, vars.toBorrow - demoted, indexes.borrow, true);

        // Update the peer-to-peer totals.
        market.deltas.decreaseP2P(underlying, demoted, vars.toBorrow + p2pTotalSupplyDecrease, indexes, true);
    }

    /// @dev Performs the accounting of a supply action.
    function _accountSupplyCollateral(address underlying, uint256 amount, address onBehalf, uint256 poolSupplyIndex)
        internal
        returns (uint256 collateralBalance)
    {
        Types.MarketBalances storage marketBalances = _marketBalances[underlying];

        collateralBalance = marketBalances.collateral[onBehalf] + amount.rayDivDown(poolSupplyIndex);
        marketBalances.collateral[onBehalf] = collateralBalance;

        _userCollaterals[onBehalf].add(underlying);
    }

    /// @dev Performs the accounting of a withdraw collateral action.
    function _accountWithdrawCollateral(address underlying, uint256 amount, address onBehalf, uint256 poolSupplyIndex)
        internal
        returns (uint256 collateralBalance)
    {
        Types.MarketBalances storage marketBalances = _marketBalances[underlying];

        collateralBalance = marketBalances.collateral[onBehalf].zeroFloorSub(amount.rayDivUp(poolSupplyIndex));
        marketBalances.collateral[onBehalf] = collateralBalance;

        if (collateralBalance == 0) _userCollaterals[onBehalf].remove(underlying);
    }

    /// @dev Executes a supply action.
    function _executeSupply(
        address underlying,
        uint256 amount,
        address from,
        address onBehalf,
        uint256 maxIterations,
        Types.Indexes256 memory indexes
    ) internal returns (Types.SupplyRepayVars memory vars) {
        vars = _accountSupply(underlying, amount, onBehalf, maxIterations, indexes);

        emit Events.Supplied(from, onBehalf, underlying, amount, vars.onPool, vars.inP2P);
    }

    /// @dev Executes a borrow action.
    function _executeBorrow(
        address underlying,
        uint256 amount,
        address onBehalf,
        address receiver,
        uint256 maxIterations,
        Types.Indexes256 memory indexes
    ) internal returns (Types.BorrowWithdrawVars memory vars) {
        vars = _accountBorrow(underlying, amount, onBehalf, maxIterations, indexes);

        emit Events.Borrowed(msg.sender, onBehalf, receiver, underlying, amount, vars.onPool, vars.inP2P);
    }

    /// @dev Executes a repay action.
    function _executeRepay(
        address underlying,
        uint256 amount,
        address repayer,
        address onBehalf,
        uint256 maxIterations,
        Types.Indexes256 memory indexes
    ) internal returns (Types.SupplyRepayVars memory vars) {
        vars = _accountRepay(underlying, amount, onBehalf, maxIterations, indexes);

        emit Events.Repaid(repayer, onBehalf, underlying, amount, vars.onPool, vars.inP2P);
    }

    /// @dev Executes a withdraw action.
    function _executeWithdraw(
        address underlying,
        uint256 amount,
        address onBehalf,
        address receiver,
        uint256 maxIterations,
        Types.Indexes256 memory indexes
    ) internal returns (Types.BorrowWithdrawVars memory vars) {
        vars = _accountWithdraw(underlying, amount, onBehalf, maxIterations, indexes);

        emit Events.Withdrawn(msg.sender, onBehalf, receiver, underlying, amount, vars.onPool, vars.inP2P);
    }

    /// @dev Executes a supply collateral action.
    function _executeSupplyCollateral(
        address underlying,
        uint256 amount,
        address from,
        address onBehalf,
        uint256 poolSupplyIndex
    ) internal {
        uint256 collateralBalance = _accountSupplyCollateral(underlying, amount, onBehalf, poolSupplyIndex);

        emit Events.CollateralSupplied(from, onBehalf, underlying, amount, collateralBalance);
    }

    /// @dev Executes a withdraw collateral action.
    function _executeWithdrawCollateral(
        address underlying,
        uint256 amount,
        address onBehalf,
        address receiver,
        uint256 poolSupplyIndex
    ) internal {
        uint256 collateralBalance = _accountWithdrawCollateral(underlying, amount, onBehalf, poolSupplyIndex);

        emit Events.CollateralWithdrawn(msg.sender, onBehalf, receiver, underlying, amount, collateralBalance);
    }

    /// @notice Given variables from a market side, calculates the amount to supply/borrow and a new on pool amount.
    /// @param amount The amount to supply/borrow.
    /// @param onPool The current user's scaled on pool balance.
    /// @param poolIndex The current pool index.
    /// @return The amount to supply/borrow and the new on pool amount.
    function _addToPool(uint256 amount, uint256 onPool, uint256 poolIndex) internal pure returns (uint256, uint256) {
        if (amount == 0) return (0, onPool);

        return (
            amount,
            onPool + amount.rayDivDown(poolIndex) // In scaled balance.
        );
    }

    /// @notice Given variables from a market side, calculates the amount to repay/withdraw, the amount left to process, and a new on pool amount.
    /// @param amount The amount to repay/withdraw.
    /// @param onPool The current user's scaled on pool balance.
    /// @param poolIndex The current pool index.
    /// @return The amount to repay/withdraw, the amount left to process, and the new on pool amount.
    function _subFromPool(uint256 amount, uint256 onPool, uint256 poolIndex)
        internal
        pure
        returns (uint256, uint256, uint256)
    {
        if (onPool == 0) return (0, amount, onPool);

        uint256 toProcess = Math.min(onPool.rayMul(poolIndex), amount);

        return (
            toProcess,
            amount - toProcess,
            onPool.zeroFloorSub(toProcess.rayDivUp(poolIndex)) // In scaled balance.
        );
    }

    /// @notice Given variables from a market side, promotes users and calculates the amount to repay/withdraw from promote,
    ///         the amount left to process, and the number of iterations left.
    /// @param underlying The underlying address.
    /// @param amount The amount to supply/borrow.
    /// @param maxIterations The maximum number of iterations to run.
    /// @param promote The promote function.
    /// @return The amount to repay/withdraw from promote, the amount left to process, and the number of iterations left.
    function _promoteRoutine(
        address underlying,
        uint256 amount,
        uint256 maxIterations,
        function(address, uint256, uint256) returns (uint256, uint256) promote
    ) internal returns (uint256, uint256, uint256) {
        if (amount == 0 || _market[underlying].isP2PDisabled()) {
            return (0, amount, maxIterations);
        }

        (uint256 promoted, uint256 iterationsDone) = promote(underlying, amount, maxIterations); // In underlying.

        return (promoted, amount - promoted, maxIterations - iterationsDone);
    }
}
