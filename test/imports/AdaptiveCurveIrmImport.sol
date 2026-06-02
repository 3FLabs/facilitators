// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.19;
// Force foundry to compile the Adaptive Curve IRM so `deployCode("AdaptiveCurveIrm.sol", ...)`
// resolves in integration tests. Never imported by the tests directly (it is 0.8.19 / paris).

import {AdaptiveCurveIrm} from "../../lib/vault-v2/lib/morpho-blue-irm/src/adaptive-curve-irm/AdaptiveCurveIrm.sol";
