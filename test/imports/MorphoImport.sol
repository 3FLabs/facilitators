// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.19;
// Force foundry to compile Morpho Blue so `deployCode("Morpho.sol", ...)` resolves in
// integration tests. Morpho is never imported by the tests directly (it is 0.8.19 / paris).

import {Morpho} from "../../lib/vault-v2/lib/morpho-blue/src/Morpho.sol";
