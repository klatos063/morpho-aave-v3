// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.17;

import {Types} from "./Types.sol";
import {Events} from "./Events.sol";
import {Math} from "@morpho-utils/math/Math.sol";
import {WadRayMath} from "@morpho-utils/math/WadRayMath.sol";

/// @title MarketSideDeltaLib
/// @author Morpho Labs
/// @custom:contact security@morpho.xyz
/// @notice Library used to ease increase or decrease deltas.
library MarketSideDeltaLib {
    using Math for uint256;
    using WadRayMath for uint256;

    /// @notice Given variables from a market side, updates the market side delta according to the demoted amount.
    /// @param delta The market deltas to update.
    /// @param underlying The underlying address.
    /// @param amount The amount to supply/borrow (in underlying).
    /// @param indexes The current indexes.
    /// @param borrowSide Whether the market side is borrow.
    function increaseDelta(
        Types.MarketSideDelta storage delta,
        address underlying,
        uint256 amount,
        Types.MarketSideIndexes256 memory indexes,
        bool borrowSide
    ) internal {
        if (amount == 0) return;

        uint256 newScaledP2PDelta = delta.scaledP2PDelta + amount.rayDiv(indexes.poolIndex);

        delta.scaledP2PDelta = newscaledP2PDelta;

        if (borrowSide) emit Events.P2PBorrowDeltaUpdated(underlying, newscaledP2PDelta);
        else emit Events.P2PSupplyDeltaUpdated(underlying, newscaledP2PDelta);
    }

    /// @notice Given variables from a market side, matches the delta and calculates the amount to supply/borrow from delta.
    ///         Updates the market side delta accordingly.
    /// @param delta The market deltas to update.
    /// @param underlying The underlying address.
    /// @param amount The amount to supply/borrow (in underlying).
    /// @param poolIndex The current pool index.
    /// @param borrowSide Whether the market side is borrow.
    /// @return The amount left to process and the amount to repay/withdraw.
    function decreaseDelta(
        Types.MarketSideDelta storage delta,
        address underlying,
        uint256 amount,
        uint256 poolIndex,
        bool borrowSide
    ) internal returns (uint256, uint256) {
        uint256 scaledP2PDelta = delta.scaledP2PDelta;
        if (scaledP2PDelta == 0) return (amount, 0);

        uint256 decreased = Math.min(scaledP2PDelta.rayMulUp(poolIndex), amount); // In underlying.
        uint256 newscaledP2PDelta = scaledP2PDelta.zeroFloorSub(decreased.rayDivDown(poolIndex));

        delta.scaledP2PDelta = newscaledP2PDelta;

        if (borrowSide) emit Events.P2PBorrowDeltaUpdated(underlying, newscaledP2PDelta);
        else emit Events.P2PSupplyDeltaUpdated(underlying, newscaledP2PDelta);

        return (amount - decreased, decreased);
    }
}
