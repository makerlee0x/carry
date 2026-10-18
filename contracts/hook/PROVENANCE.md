# Vendored Uniswap DualPoolHook

Verbatim copy of the files `DualPoolHook.sol` imports, with no edits.

- Source: https://github.com/Uniswap/v4-hooks-public, commit `5b73674d8db8ff9ef4f4a09cfee5f12302d68248`
  (`src/alf/DualPoolHook.sol` and its local imports, plus `src/base/BaseHook.sol`). License: MIT (`LICENSE`).
- Upstream audit: OpenZeppelin (per Uniswap's [DualPool post](https://blog.uniswap.org/dualpool-hook-is-now-live)).
  The audit covers upstream's bytecode, so keep this copy byte-identical and rebuild with the same settings.
- Build: `FOUNDRY_PROFILE=hook forge build --use ~/.svm/0.8.26/solc-0.8.26`. Settings follow upstream's `alf`
  profile: solc 0.8.26, via_ir, optimizer runs 200, cancun, bytecode_hash none. Runtime size is 24,388 bytes.
- Dependencies (git submodules, pinned to the commits upstream uses): `v4-core` d153b04, `v4-periphery` 07336f2,
  `solady` acd959a, `blocknumberish` 38fe20b, `openzeppelin-contracts` 45f032d (5.1+, for `ReentrancyGuardTransient`).
  The vault's own build keeps its OpenZeppelin 5.0.2.

Testnet use only until the mainnet plan (issue #20) is reviewed. Deploying needs a hook address whose low bits match
`getHookPermissions()` (mine one with CREATE2); the tests use `deployCodeTo` instead.

To update: copy the new upstream files over these, bump the commit above, and rerun the hook profile tests.
