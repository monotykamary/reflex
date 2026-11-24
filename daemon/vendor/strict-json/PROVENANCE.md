# strict-json

The JSON reader in `daemon/src/js.ts` (`read`) is a TypeScript port of the
strict-json reader reflexd used while it was written in Bend: the same state
machine, the same refusals in the same words. That reader was copied from
jev-fabric native/vendor/strict-json, itself adapted from H4ad/bend-stdlib
(Apache-2.0; see LICENSE and jev-fabric's PROVENANCE.md).
