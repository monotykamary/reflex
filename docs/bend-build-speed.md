# Bend build speed on large programs

Measured on jev-fabric 0.6.0 (`native/main.bend`, 426k lines of emitted C),
Bend 2.0.36, a 16 GB M-series Mac that already had ~22 GB in swap.

## Where the time goes

| Phase | Time |
|---|---|
| Type/proof check (`--check-only`) | 22 s |
| C emission (`compile_book`, in Bun/JSC) | 6–18 min |
| clang `-O3` (426k lines) | 43 s (`-O1`: 36 s — not worth it) |

A full `bend native/main.bend -o build/jev-fabric` took **13m18s**, of which
434 s was *system* time: the emitter's JavaScriptCore heap grew to a
**12 GB footprint** and was paging to swap.

## Fix 1 — keep the emitter in RAM (no code change)

Bend's compiler is a Bun binary, so JSC options apply. Telling JSC to assume
less RAM makes it collect earlier:

```sh
export BUN_JSC_forceRAMSize=4294967296   # 4 GiB
```

| | wall | peak footprint |
|---|---|---|
| default (under swap pressure) | 18 min emission | 12 GB |
| `forceRAMSize=4GiB` | **5m56s** emission | 4.7 GB |

Emitted C is byte-identical. `scripts/build-app.sh` sets it, and the same
three lines were added to jev-fabric's `scripts/build-native.sh` and
`scripts/test-native.sh`. Smaller programs pay ~30% more CPU for the extra GC
(reflexd: still ~20 s), so a lower cap only helps when swap is the problem.

## Fix 2 — the quadratic hot spot (compiler patch)

A CPU profile of the emitter on jev-fabric:

```
94.0%  emit_match            comp.ts:2650
75.4%  mat_lits / walk       comp.ts:1086   (U32 literal matches → 32-level bit tree)
58.6%  key                   comp.ts:1088   JSON.stringify(term_lower(t), replacer)
59.2%  term_lower            bend.ts:782
13.2%  stringify (self)
```

At each of the 32 bit levels of a U32-literal match, `mat_lits` decides
whether a default arm is new by **lowering two whole continuation terms and
comparing them as JSON strings**. jev-fabric's large character-class
matchers (strict JSON, UTF-8) make those continuations big, so the cost is
quadratic in function size.

`docs/patches/bend-mat-lits-same-lowered.patch` replaces the string
comparison with `same_lowered`, a lockstep structural comparison with the
same semantics as the replacer (spans dropped, `Ann` stripped, function
fields ignored): binders open on the same fresh variable, the first
difference returns false, and a shared subterm object at the same depth
returns true without being walked.

Run from source with the 4 GiB cap, same machine:

| | wall | user CPU | output |
|---|---|---|---|
| Bend 2.0.35 source | 594.6 s | 609.9 s | — |
| + patch | **239.3 s** | 306.9 s | byte-identical |

Peak footprint varied between the runs (5.9 GB vs 8.4 GB patched) — GC
timing, not live data; worth re-measuring before sending upstream.

To try it:

```sh
cd ~/VCS/working-remote/open-source/bend && git apply ../reflex/docs/patches/bend-mat-lits-same-lowered.patch
BUN_JSC_forceRAMSize=4294967296 bun bend2/main.ts native/main.bend -o build/jev-fabric   # from jev-fabric
```

The patch is against the public source (2.0.35 + main); the installed
`bend` is a compiled 2.0.36 binary, so upstreaming it is the way to get it
into `bend` itself.
