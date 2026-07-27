# Follow-up corpus scan — 2026-07-26 (after the uniforms/GetPixel/`%`-modulo fixes)

Re-measurement after fixing the three items `corpus-shader-scan-2026-07-26/README.md`'s
original scan had flagged as the next-priority gaps: 99x "undeclared identifier 'uniforms'",
42x "undeclared identifier 'GetPixel'"/`GetBlur1`/`GetBlur2`, and the ~400-450x HLSL `%`
(float modulo) vs. MSL `%` (integer-only) mismatch. See `scan_output.txt` for the full raw
output; rerun the same way as the original scan (copy this folder's `harness_main.swift` in
as `main.swift` — it's identical to the original, unchanged).

**Result**: full 9,795-file corpus, **warp_N= 62.72% (4,970/7,924), comp_N= 68.03%
(5,423/7,971)** — up from the prior 60.03%/65.39% (warp_N= +2.69 points, comp_N= +2.64
points). All three targeted error signatures are gone from the top-30 list.

## A serious regression, found and fixed before this number was trusted

The first re-scan after the `%`-modulo fix landed came back at **14.02%/18.64%** — a massive
*drop*, dominated by a new 9877x "expected expression" error. Root cause: the modulo rewriter
tokenizes and reformats the entire shader body (needed to find `%`'s operand boundaries), and
its tokenizer didn't know about `//`/`/* */` comments — real, common in this corpus (hand-edited
presets routinely have commented-out debug lines). A `//` got tokenized as two separate `/`
division operators and rejoined with a space (`/ /`), which is no longer a comment at all,
turning "commented out" code back into live — and now syntactically broken — code.

Fixed by stripping comments in one pass at the very start of `MilkdropShaderTranslator.translate`,
before any other rewrite sees the text (`stripComments`) — this also protects every *other*
text-substitution pass in the file, old and new, which had the same latent blind spot.

That fix alone still left a smaller, related regression: **120x "expected expression"** in the
next re-scan, from a different but related cause. The modulo rewriter's token-rejoining also
collapsed *all* whitespace (including newlines) to single spaces. A real corpus pattern —
`#if`/`#else`/`#endif` preprocessor conditionals written directly inside `shader_body` (e.g.
"Mig_177.milk"'s `comp_`) — only works because `#` starts its own physical line; collapsing
the surrounding newlines merged the directive onto the same line as the code around it, so the
MSL preprocessor no longer recognized it as a directive at all.

Fixed by making the modulo rewriter preserve original whitespace verbatim (`ModuloToken
.whitespace`) instead of reformatting it — chains of `*`/`/` still get folded correctly (looking
*past* whitespace when checking for chain continuation), but nothing outside an actual rewritten
`%` span has its formatting touched anymore.

**Lesson for whoever touches this rewriter next**: it operates on a full shader body's *raw*
text, not an isolated expression — always re-verify against the full real corpus (not a
synthetic snippet) after any change to it. A synthetic-snippet-only smoke test is exactly what
missed both of these; neither test case happened to include a comment or a preprocessor
directive.
