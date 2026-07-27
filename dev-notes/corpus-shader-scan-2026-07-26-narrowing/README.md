# Full-corpus shader compile scan — 2026-07-26 (after the general narrowing fix)

Re-measurement after implementing `narrowWideAssignments` — a lightweight symbol table
(`collectDeclarations`/`collectParameterWidths`) plus a width inferencer
(`widthOfExpression`/`widthOfPrimary`/`widthOfCall`) that generalizes the narrowing-swizzle fix
already applied to texture-sample calls (`declaredAssignmentWidth`) to *arbitrary* plain
assignments — the item TO DO.md had flagged as "THE DOMINANT REMAINING CAUSE, several thousand
instances". See `scan_output.txt` for the full raw output; rerun the same way as
`corpus-shader-scan-2026-07-26-followup` (copy this folder's `harness_main.swift` in as
`main.swift`, unchanged from that scan).

**Result**: full 9,795-file corpus, **warp_N= 66.56% (5,274/7,924), comp_N= 76.26% (6,079/7,971)**
— up from the prior 63.35%/68.06% (warp_N= +3.21 points/+254 files, comp_N= +8.20 points/+654
files). Parse failures: 0, `translateFail`: 0/0 (no new translation-level regressions). No
runaway/anomalous new top error signature appeared (unlike the `%`-modulo rewrite's comment-
corruption regression) — every top-30 signature is a recognizable, smaller-magnitude variant of
what was already there.

## Scope: this fixes *reassignment/declaration* narrowing, not every implicit-conversion shape

The remaining top error signatures are still dominated by implicit-conversion errors (518x/515x/
392x `dot`-ambiguous/350x/309x/291x/256x/225x/179x/152x `length`-ambiguous/111x/...) — the
underlying *class* of bug isn't fully closed, only the specific shape this pass targets
(`[<type>] name = <rhs>;`, narrowing direction only). Known gaps, not yet attempted:

- **Swizzled-LHS writes** (`ret.xyz = wideExpr;`, `neu.rgb = ...`) — `trailingTypedIdentifier`
  deliberately bails on these (the trailing text ends in a swizzle/member access, not a plain
  identifier) rather than risk misresolving the swizzle member text as if it were a variable name.
  Real corpus pattern (`"member reference base type 'float' is not a structure or union"`, 291x,
  and part of the remaining `"assigning to 'float' from incompatible type"` counts) — likely a
  meaningful chunk of what's left.
- **Compound assignment operators** (`+=`/`-=`/etc.) — `processStatementChunk`'s `=`-scan
  explicitly excludes these (the char before `=` being one of `<>=!+-*/%` skips that `=` entirely)
  for scope/safety, not because they can't have the same narrowing bug.
- **Widening** (a bare scalar splatting into a vector lvalue — HLSL's *other* implicit-conversion
  direction) is out of scope by design (see `MilkdropShaderTranslator.swift`'s own "MARK: -
  Implicit narrowing on plain assignments" header) — deliberately not attempted this round.
- Any RHS shape the width inferencer isn't confident about (an unrecognized function call, a
  top-level comparison/logical operator, `milkdrop_mul`/`mul` — ambiguous on argument order,
  deliberately bailed rather than guessed) is left completely untouched, silently.

Re-measure after picking any of these up — real counts, not assumptions, per this project's own
standing method.
