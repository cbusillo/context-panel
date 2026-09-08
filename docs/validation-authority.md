# Validation Authority and Operator Route

Start here before selecting a validation path. This page routes decisions to
owning sources; it does not define policy values, fixture contents, thresholds,
or active train status. Keep those in their existing sources.

## Sources of truth

Explicit user instructions define the requested outcome. The accepted contract
is recorded in [#608](https://github.com/cbusillo/context-panel/issues/608)
(simulator-first, risk-triggered validation) and
[#655](https://github.com/cbusillo/context-panel/issues/655)
(host-side capture and consolidated shared-view review).

| Question | Owning source |
| --- | --- |
| What behavior is agreed? | #608 and #655 acceptance criteria and decisions |
| Is the current policy qualified for cutover? | [#616](https://github.com/cbusillo/context-panel/issues/616) and [#612](https://github.com/cbusillo/context-panel/issues/612), including their evidence and dependencies |
| What must this exact candidate prove? | [Surface policy](../Config/ContextPanelSurfacePolicy.json), [release-evidence policy](../Config/ContextPanelReleaseEvidencePolicy.json), [matrix](../Config/ContextPanelSharedViewMatrix.json), and the complete source/build-manifest comparison |
| How does the implemented path operate? | [Release procedure](release.md), [coordinator](signed-validation-operator-flow.md), and [capture mechanisms](signed-validation-galleries.md) |

Code, tests, documentation, and historical artifacts show implemented behavior
and evidence. They do not independently redefine the agreed outcome. If these
sources disagree, reconcile the owning plan and implementation before proceeding
with the dependent decision; continue independent work. Do not choose whichever
interpretation makes the current run pass.

Desired behavior is implemented through normal reviewed changes. A plan or
desired outcome alone never authorizes bypassing a runtime or submission gate,
omitting evidence, downgrading submission evidence enforcement, or declaring a
pending qualification gate passed. Preserve implemented execution gates while
reconciling a discrepancy.

## Evaluation and submission

**Candidate-policy shadow evaluation** and **live submission evidence
enforcement** are separate operations. They do not select different policies.
Both bind the current configured policy and surface-policy digests.

Use the [release evaluator](../scripts/context-panel-release-gate.py) in shadow
mode to collect candidate-policy results and classify disagreements against the
physical runbook. Qualification and cutover are governed by #616 and #612;
source availability or an earlier policy's qualification does not complete them.

The [submission workflow](../.github/workflows/submit-app-store-review.yml)
and [submission CLI](../scripts/submit-app-store-review.py) already default to
`release_evidence_mode=enforce`. That mode controls report acceptance strictness,
not policy selection. Preserve this existing control, as #612's decisions
require. It can correctly reject a candidate lacking qualified current-policy
evidence. Shadow evaluation is not permission to switch a live submission to
shadow to bypass that rejection. An enabled submission verifier is not proof
that the current risk-policy cutover is complete.

## Capture before review

1. Read the owning plan and identify the exact previous/current source and
   signed build identities. Generate the full comparison with every archive
   layout's expected-build manifests. Follow [the release procedure](release.md);
   do not filter or rewrite `requiredEvidence` or `requiredSurfaces`.
2. Prepare visual requirements from the canonical matrix and the comparison's
   fresh visual classes. The full release evaluator must resolve eligible
   carry-forward from valid lineage; a smaller current review queue does not
   waive the complete evidence requirements.
3. Open an exact-build runtime session only when the comparison requires it,
   using exactly `requiredSurfaces.actual-runtime`. Follow the canonical
   Production runtime/cache checks in [AGENTS.md](../AGENTS.md). Observe normal
   install and receipt propagation through the coordinator before requesting
   manual recovery.
4. For shared views, supply all required capture inputs to the
   [supported simulator capture path](signed-validation-galleries.md).
   If inputs are missing, correct the invocation as machine work. A terminal
   `unsupported` attempt can expose a review action without producing an image;
   inspect the capture result rather than treating that action as proof that
   capture succeeded or as an instruction to navigate a signed gallery.
5. An unsupported adapter is an explicit collection gap. Preserve its diagnostic
   result, identify the missing mechanism, and continue independent supported
   capture or receipt work. Do not turn this result into a live-gallery
   walkthrough unless the user explicitly requests that diagnostic route.
   Do not narrow the plan, fabricate evidence, or label the gap a product bug.
6. Present captured shared views in a consolidated review batch. Keep explicit
   human decisions bound to their exact required contexts. Automation collects
   artifacts; it does not approve them. OS-composited placement remains a
   separate physical review with its own exact-runtime prerequisites.
7. Evaluate the complete evidence with the full release gate and validate its
   reconstruction using the same authoritative inputs. Release must bind the
   selected approved RC. Neither a successful capture nor a completed
   coordinator slice establishes full release approval.

## Implemented capture limits

The executor currently supports iOS, iPadOS, visionOS, and watchOS simulator
capture. macOS and tvOS remain explicit `unsupported-host-mechanism` results;
see [the capture contract](signed-validation-galleries.md#private-simulator-capture).
There is no macOS simulator adapter hidden behind a missing config value.

Existing Mac render tests can export host-rendered PNGs, but those test outputs
are not formal build/requirement-bound capture receipts. The default-text matrix
case and an enlarged-text stress test are distinct valid scenarios. Preserve the
stress coverage; do not relabel it as evidence for a different matrix context.

Simulator or host-rendered shared views cannot satisfy `actual-runtime` or
`os-composited-placement`. Preserve historical manifests, receipts, and fixture
contracts. Use [replay qualification](signed-validation-replay-inventory.md)
without silently upgrading diagnostic or reference-only evidence.
