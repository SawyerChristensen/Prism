# Full-corpus shader compile scan — 7/27, rounds 2 and 3 (follow-ups to the narrowing pass)

Continuation of `dev-notes/corpus-shader-scan-2026-07-26-narrowing/` (round 1: general implicit-
narrowing on plain assignments, warp_N= 63.35% -> 66.56%, comp_N= 68.06% -> 76.26%). This session
picked off every other item that scan's error list had identified, in priority order, re-measuring
against the full 9,795-file corpus after each batch. See `../corpus-shader-scan-2026-07-27-round2/`
for round 2's own raw scan output; this folder's `scan_output.txt` is round 3's.

## Round 2 — swizzled-LHS/compound-assignment narrowing, int casts, `mul`/`all`/`any`, static/const

- **Swizzled-LHS writes** (`ret.xyz = wideExpr;`): `narrowWideAssignments` previously only
  recognized a plain-identifier assignment target; `trailingSwizzleWidth` now recognizes a
  component write too, using the swizzle's own length as the target width (no symbol-table lookup
  needed at all).
- **Compound assignment** (`+=`/`-=`/`*=`/`/=`): narrowing the RHS alone is still correct here —
  `(x op rhs).W == x op (rhs).W` whenever `x` is already `W` components wide, which it always is by
  construction (`W` comes from `x`'s own declared/swizzle width).
- **`int`/`int2`/`int3`/`int4` declarations from a float-typed RHS** (42x, e.g. `int2 k1 =
  (texsize.xy*uv)%2;`, confirmed identical across all 42 files): real HLSL/Cg implicitly truncates
  float->int on assignment; MSL doesn't. A fresh int-typed declaration now gets its whole RHS
  wrapped in an explicit `intN(...)` cast, unconditionally (no width inference needed — real HLSL's
  own implicit-conversion rule already guarantees the RHS's component count matches).
- **`milkdrop_mul` scalar/scalar-vector overloads** (35x "no matching function for call to
  'milkdrop_mul'"): real HLSL's `mul` also documents plain scalar-scalar and scalar-vector forms
  (ordinary/componentwise-scale multiplication) — confirmed against "Star Forge v13c.milk"'s warp_
  (`mul(pow(q3, 1.25), .013*tex2D(...))`, a scalar times a `float3`). Added
  `milkdrop_mul(float,float)`/`(float,floatN)`/`(floatN,float)` overloads to the shim header.
- **`all`/`any` on a float vector** (27x): real HLSL's `all`/`any` implicitly test each component
  against zero on *any* numeric vector; MSL's own only accept `boolN`. Added `all(floatN)`/
  `any(floatN)` overloads (not a redefinition risk, unlike `lerp`/`saturate`/`mul` — different
  parameter type).
- **`static`/`const`-qualified preamble declarations silently dropped** (~180x combined across
  `sunpos`/`sw2`/`samples`/`res`/`n` "undeclared identifier" signatures): `preambleDeclarations`'s
  keyword-prefix check only ever looked for `float`/`int`/`bool` at the very start of a statement,
  never past a `static`/`const` qualifier — the *whole declaration* was silently dropped. Fixed by
  stripping recognized qualifiers before the prefix check (the qualifier itself stays in the kept
  statement text).

**Result after round 2**: warp_N= 66.56% -> **72.22%** (5,274 -> 5,723 OK, +449 files), comp_N=
76.26% -> **79.41%** (6,079 -> 6,330 OK, +251 files).

## Round 3 — cleanup of what round 2 itself surfaced

Two of round 2's fixes revealed *further*, previously-unreached problems in the same files (a
normal part of iterative fixing — an earlier error was masking a later one):

- **Bare `static` (no `const`) rejected by MSL** (66x, new: "variables in function scope cannot be
  declared static") — once `preambleDeclarations` stopped dropping `static`-qualified declarations,
  the literal `static` keyword itself started reaching MSL, which (unlike HLSL) never allows it on
  a function-scope variable. `renameIntrinsics` already turned `static const` into `const`; extended
  to also strip a bare `static` outright (semantically a no-op for Milkdrop's usage — always a
  simple named value, never state persisting across invocations).
- **Flat vector-array initializers** (56x, new: "excess elements in array initializer") — real
  HLSL/Cg allows a flat, ungrouped scalar list for an array of vectors (`const float4 samples[5] =
  { 0.0,0.0,0,11.0/3.0, 0.0,1.0,0,-2.0/3.0, ... };`, confirmed identical across all 56 files, always
  a `samples[4]`/`samples[5]` array); MSL's aggregate initialization has no implicit grouping.
  `regroupFlatVectorArrayInitializers` regroups the flat list into `floatN(...)` per element —
  deliberately only when the initializer contains no brace already and the value count divides
  evenly by the element width.
- **Preamble locals referenced from inside a *helper* function** (62x/30x "undeclared identifier
  'sunpos'"/`'res'`, unresolved by the `static`/`const` fix above on its own): a hoisted helper
  function has no more implicit access to a plain preamble-declared local than it does to
  `uniforms`/a texture (confirmed against "414.milk"'s warp_, `cloud(float2 uv_in) { return
  (...)-sunpos...; }`, and "xtramartin (578).milk"'s warp_, `fstep2(float2 xy) {return
  1.0/res*round(res*xy);}`) — needs the exact same explicit-parameter threading `extractHelperFunctions`
  already does for `uniforms`/textures, including the transitive closure for a helper that merely
  *calls* another helper needing the local. Extended with `collectDeclaredTypeKeywords`/
  `threadLocalParameters`, reusing the existing `calledHelpers` call graph.

**Result after round 3**: warp_N= 72.22% -> **72.69%** (5,723 -> 5,760 OK, +37 files), comp_N=
79.41% -> **79.54%** (6,330 -> 6,340 OK, +10 files) — real but visibly smaller gains than rounds
1-2, as expected: these were narrower, more specific gaps than the general narrowing pass.

## Cumulative result, this session (rounds 1-3 combined)

**warp_N= 63.35% -> 72.69% (+9.34 points, 5,020 -> 5,760 OK, +740 files)**
**comp_N= 68.06% -> 79.54% (+11.48 points, 5,425 -> 6,340 OK, +915 files)**

0 parse failures, 0 `translateFail` throughout all three rounds — every gain is a genuine new
compile success, not a shifted failure mode. No runaway/anomalous new top error signature at any
point (unlike the `%`-modulo rewrite's earlier comment-corruption regression).

## What's left (real counts from round 3's `scan_output.txt`, not assumptions)

The remaining top signatures are now visibly smaller in magnitude and more scattered across
distinct root causes than the single dominant narrowing bug rounds 1-3 worked through — genuine
diminishing returns, not a measurement artifact:

- **Still the largest cluster**: "implicit conversions between vector types" in various width
  combinations (521x/348x/307x/297x/273x/243x/192x/153x/66x/34x ≈ 2,400 instances) and the
  "ambiguous call to `dot`/`length`/`clamp`/`min`/`pow`/`fmod`/`max`" cascade (394x/156x/58x/51x/
  47x/45x/21x ≈ 770 instances) these feed. Some of this is the narrowing pass's still-documented
  scope limits (function-call-argument narrowing was never attempted — only assignment RHS/
  compound-assignment/swizzle-write targets); some is likely genuine, different bugs not yet
  investigated.
- **28x "no matching member function for call to 'sample'"**: confirmed (via "Geiss - Reaction
  Diffusion 3..."'s warp_) as `GetBlur1(saturate(ret))` — a texture-helper call whose *coordinate*
  argument evaluates to `float3` (from `ret`), not the `float2` `.sample()` needs. A real, if
  unusual, original-preset pattern; would need the narrowing pass extended to texture-call
  coordinate arguments specifically, not attempted this round.
- **49x "read-only variable is not assignable"**, **20x "redefinition of 'tmp'"**, **40x "invalid
  operands ... float2x2 and int"**, **25x "cannot initialize float3 with float4"** (example:
  414.milk, a *different* declaration than the now-fixed `sunpos` one): not yet investigated —
  newly visible now that earlier errors in the same files are fixed, each likely its own narrower
  root cause.
- **15x "no matching function for call to 'milkdrop_mul'"** (down from 35x): the scalar/vector
  overloads added this round didn't cover every shape — likely the documented-but-unimplemented
  `mul(vector, vector)` form (dot-product semantics), deliberately not guessed at without a
  confirmed real example of what HLSL actually does there.

Re-measure after picking any of these up — real counts, not assumptions, per this project's own
standing method.
