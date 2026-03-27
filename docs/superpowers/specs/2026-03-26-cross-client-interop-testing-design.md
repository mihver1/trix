# Cross-Client Interoperability Testing Design

## Summary

This design introduces a real cross-client interoperability harness for `trix` that exercises the iOS, macOS, and Android clients against one shared backend state while still preparing the necessary per-platform local seed state for each client.

The first rollout intentionally targets two complementary layers:

- `interop-seeded`: each real client boots against the same server-side fixture bundle plus its own platform-local seeded state and proves it can restore, load, and present that state correctly
- `interop-cross`: orchestrated cross-client end-to-end scenarios where one client mutates state, a second client receives it, and a third client verifies converged state

The goal is to make interoperability coverage strong enough to catch regressions in shared state convergence, restore flows, device approval, DM/group message propagation, and basic multi-client consistency without requiring one giant always-on tri-UI rig on a single laptop.

## Context

The repository already has useful but separate pieces:

- strong Rust and FFI end-to-end coverage in `trix-core`
- a growing iOS UI-testing contour with deterministic launch and seeded scenarios
- an in-progress macOS UI-testing contour with the same general architecture
- Android local and UI coverage through Gradle/JVM/instrumentation suites
- a shared smoke entrypoint in `scripts/client-smoke-harness.sh`

Those are necessary, but they do not yet prove that the three native clients interoperate with one another through one live backend over the flows users actually care about. A seeded iOS UI test says iOS can render a seeded DM. An Android unit test says Android local projection logic is sane. Neither proves that:

- Android can send something that iOS and macOS both converge on
- device approval initiated from one client is recoverable from another
- restore paths on each client still converge onto the same server state
- chat list, unread state, and timeline projections agree across three separate client implementations

The obvious brute-force answer would be a single UI-driven mega-rig that keeps a macOS app, an iOS simulator, and an Android emulator alive and actively driven at once. On a developer laptop, that is the wrong tradeoff: it is memory-heavy, flaky, slow, and difficult to debug. The harness should instead treat UI smoke and cross-client interoperability as related but separate responsibilities.

## Goals

- Add a shared cross-client interoperability harness that exercises iOS, macOS, and Android against one live backend.
- Cover both seeded restore/presentation smoke and real cross-client mutation/receipt/verification flows.
- Keep the harness laptop-friendly by default through sequential execution and app-owned semantic driver actions.
- Require every client to participate as a mutating actor, receiving participant, and asserting participant across the scenario matrix.
- Integrate the resulting interop suites into `scripts/client-smoke-harness.sh`.
- Preserve platform-local UI suites as independent proof that production UI still works.

## Non-Goals

- No first-wave attempt to drive all three clients entirely through long-lived full UI automation at the same time.
- No generic Android local runtime abstraction in wave 1; Android local interop is `Genymotion-only`.
- No first-wave attachment send/download interop coverage.
- No first-wave background/resume or lifecycle stress matrix.
- No replacement of platform-local suites such as `ios-ui`, `macos-ui`, or Android instrumentation; they remain separate.
- No requirement that wave 1 run efficiently in remote CI before it is proven locally.

## Decision Summary

The chosen direction is:

1. Add an external `interop orchestrator` instead of embedding cross-client coordination inside any one app.
2. Add one semantic `client driver` per platform with the same action-oriented contract.
3. Keep platform-local UI smoke as a separate proof layer rather than making interop depend on long-running full-UI driving for all three clients.
4. Run the local harness sequentially and resource-aware, keeping heavy runtimes alive only when a scenario step needs them.
5. Split the first rollout into `interop-seeded`, `interop-cross`, and an opt-in future `interop-full`.
6. Standardize Android local interop on a pre-running `Genymotion` device connected over `adb`.

## Architecture

### 1. Orchestrator Layer

Add a repo-level interoperability orchestrator under a neutral location such as `scripts/interop/`.

Responsibilities:

- parse scenario definitions and suite selection
- allocate a unique `scenarioLabel` / run identifier
- prepare platform runtimes and pass common launch configuration
- invoke client drivers through a stable contract
- collect structured evidence for every step
- enforce preflight checks, timeouts, and failure policy
- tear down runtimes when they are no longer needed

The orchestrator should know only semantic operations such as:

- `prepare`
- `bootstrapAccount`
- `createLinkIntent`
- `registerPendingDevice`
- `restoreSession`
- `reconnectAfterApproval`
- `approvePendingDevice`
- `awaitDeviceState`
- `createDM`
- `createGroup`
- `sendText`
- `awaitChatVisible`
- `awaitMessageVisible`
- `awaitUnreadState`
- `markChatRead`
- `snapshotState`
- `shutdown`

It should not know platform-specific selectors, view hierarchies, or gesture details.

The orchestrator should also treat each scenario as an ordered step list rather than a fixed global role triple. Each step should declare:

- `actor`
- optional `targetClient` or `targetClients`
- optional `assertingClients`
- the semantic action being performed
- the expected evidence

That keeps DM, group, restore, and device-link scenarios expressible under one model even when one client mutates in one step and a different client mutates in a later step.

### 2. Client Driver Layer

Add one driver per platform:

- `ios`
- `macos`
- `android`

Each driver must implement the same semantic contract while remaining free to use platform-specific internals:

- iOS can use launch-contract bootstrap, app-owned test seams, and targeted UI proof points
- macOS can use the same deterministic launch/bootstrap pattern and app-owned assertions
- Android can use instrumentation or debug-bridge-driven actions exposed over the same semantic contract

The contract should be data-driven and structured, for example JSON in and JSON out, so the orchestrator can stay platform-neutral.

Each driver must report:

- resolved identifiers such as `accountId`, `deviceId`, `chatId`, `messageId`
- timing/evidence metadata
- explicit unsupported capabilities

### 3. Capability Model

Not every capability needs to land in wave 1, so the driver layer should expose an explicit capability model rather than making missing support ambiguous.

Expected first-wave capability buckets:

- `seededBootstrap`
- `restoreSession`
- `dmText`
- `groupText`
- `deviceApproval`
- `chatListAssertions`
- `timelineAssertions`
- `unreadAssertions`

Deferred wave-2 examples:

- `attachmentSend`
- `attachmentDownload`
- `backgroundResume`
- `lifecycleTransitions`

The orchestrator should fail when a required capability is missing for a selected suite, rather than silently turning a real gap into a green run.

### 4. Evidence Layer

Every scenario run should write structured artifacts, not only streaming logs.

Minimum artifacts:

- `scenario.json`
- `step-results.json`
- per-platform logs or command transcripts
- screenshots only on failure for UI-backed steps
- resolved ids and state snapshots per step

Minimum structured evidence fields:

- scenario name
- step id
- acting client
- targeted client or clients when applicable
- asserting client or clients
- `accountId`
- `deviceId`
- `chatId`
- `messageId`
- expected vs observed state
- timeout or retry metadata

This keeps failures diagnosable without reopening all three clients and manually reconstructing which state diverged.

## Execution Model

### 1. Local-First Sequential Execution

The first target runtime model is local and regular execution on one developer machine. That rules out a permanently parallel tri-UI rig as the default mode.

The orchestrator should therefore:

- run scenarios sequentially
- avoid keeping both the iOS simulator and Android runtime active unless a step truly requires that overlap
- allow the macOS client to act as the cheapest local observer where appropriate
- prefer app-owned semantic assertions over long UI-driving loops

The local harness should optimize for correctness and reproducibility before speed.

### 2. Android Runtime: Genymotion Only

Wave 1 local Android interop uses `Genymotion` only.

Requirements:

- the interop harness does not attempt to boot an Android Studio emulator or rely on an AVD
- Android preflight requires one live `adb`-connected Genymotion device
- selecting an interop suite that needs Android must fail if the Genymotion device is unavailable

Wave-1 acceptance rule:

- the harness chooses `TRIX_ANDROID_INTEROP_SERIAL` when explicitly provided; otherwise exactly one connected Android device must be eligible
- eligibility requires `adb -s <serial> shell getprop ro.product.manufacturer` to report `Genymobile` (or a documented equivalent Genymotion manufacturer string)
- any other connected Android target does not satisfy interop preflight

The Android driver may still use `adb`-compatible plumbing internally, but wave 1 does not promise support for arbitrary `adb` targets or physical devices.

### 3. Platform Proof Strategy

Platform-local UI suites remain the production-UI proof layer:

- `ios-ui`
- `macos-ui`
- Android instrumentation/UI tests

The interop harness is allowed to use app-owned test seams and semantic actions as long as it still validates user-visible state at the right points, such as:

- a DM row becomes visible
- a timeline contains the expected message
- unread state changes as expected
- restore lands in the correct signed-in or pending state

That keeps the interop harness strong enough to verify shared behavior without making it identical to three simultaneous UI-smoke suites.

## Scenario Matrix

### 1. `interop-seeded`

This suite proves that each real client can restore and present one shared seeded backend fixture bundle.

`Shared` here means:

- one common server-side fixture shape
- per-platform local seed material prepared for each client independently

It does not mean reusing one literal local store snapshot or one device identity across iOS, macOS, and Android. Each client must get its own valid local identity, persisted session material, and app-local store state while still converging on the same server-visible fixture topology.

Expected first-wave coverage:

- one shared server-side approved account / chat-state bundle plus per-client local seeds
- one shared server-side pending-approval bundle plus per-client local seeds
- one shared server-side restore-session bundle plus per-client local seeds
- DM and group seeded content visible from each client

This suite answers:

- can each client restore the same server-backed state?
- can each client surface the seeded DM/group rows and timeline data?
- do local restore/persistence seams still converge on the same backend truth?

### 2. `interop-cross`

This is the first real local interoperability suite.

Each scenario is an ordered sequence of semantic steps with explicit participants per step:

- `actor`
- optional `targetClient` or `targetClients`
- optional `assertingClients`

Across the full first-wave matrix, every client must participate as:

- a mutating actor
- a receiving participant
- an asserting participant

#### DM text ring

Three first-wave scenarios:

- `android -> ios -> macos`
- `ios -> macos -> android`
- `macos -> android -> ios`

Each scenario should:

- establish or resolve the target DM
- send a real text message from the acting client
- assert that the receiving client sees the message
- assert that the third client sees converged chat/timeline/unread state

#### Group creation and reply ring

Three first-wave scenarios:

- `android creates group -> ios sees group -> macos replies`
- `ios creates group -> macos sees group -> android replies`
- `macos creates group -> android sees group -> ios replies`

Each scenario should validate:

- group creation
- group row visibility on the second client
- reply delivery from the third client
- converged timeline visibility on all participating clients

#### Restore interoperability

Each client should act as a restore target at least once:

- persisted session exists
- client relaunches or restores
- client reloads account/chat state
- another client produces a new event after restore
- restored client receives or reconciles that event

#### Device approval interoperability

Wave 1 should include one canonical device-lifecycle proof scenario:

- one client creates a link intent
- another client registers as pending
- a third client approves the pending device
- the pending client restores into active state
- the other clients observe updated device state

This is intentionally weaker than a full three-way role rotation for device approval. Wave 1 proves one end-to-end approval flow exists across three clients; broader creator/pending/approver rotation can land in wave 2 after the canonical flow is stable.

### 3. `interop-full`

`interop-full` is intentionally not part of the initial local baseline.

It should remain opt-in until the lighter suites prove stable and can later absorb:

- attachments
- richer read-state coverage
- member/device removal
- lifecycle/background-resume transitions
- larger scenario permutations

## Driver Contract

The orchestrator should not address clients by file paths, buttons, or platform-specific handles. It should address them by aliases and semantic actions.

Suggested logical identifiers:

- `alice-ios`
- `bob-android`
- `observer-macos`
- `dm-alice-bob`
- `group-core-team`

Suggested command surface:

- `prepare`
- `bootstrapAccount`
- `bootstrapPendingApproval`
- `createLinkIntent`
- `registerPendingDevice`
- `restoreSession`
- `reconnectAfterApproval`
- `approvePendingDevice`
- `awaitDeviceState`
- `createDM`
- `createGroup`
- `sendText`
- `awaitChatVisible`
- `awaitMessageVisible`
- `awaitUnreadState`
- `markChatRead`
- `snapshotState`
- `shutdown`

The driver should return structured ids rather than forcing the orchestrator to scrape them from logs.

The contract should be explicit that:

- semantic app-side actions are preferred
- UI proof points are required at selected checkpoints
- unsupported capabilities are reported explicitly
- timeouts are handled at the driver boundary, not by blind outer sleeps alone
- scenario steps carry explicit participant bindings rather than assuming one fixed triplet for the whole scenario

## Harness Integration

Add new suites to `scripts/client-smoke-harness.sh`:

- `interop-seeded`
- `interop-cross`
- `interop-full`

Expected wave-1 behavior:

- `interop-seeded` and `interop-cross` are opt-in local suites
- `interop-full` exists as an even heavier explicit opt-in path and should not join the default smoke pack

Preflight must include:

- backend health
- iOS simulator availability when an iOS scenario is selected
- macOS Xcode project/UI-test availability when a macOS scenario is selected
- one eligible `adb`-connected Genymotion device, selected by explicit serial or exact-single-match rule, when an Android scenario is selected

The harness must fail preflight when a required runtime is unavailable; it must not report green on a suite that effectively did not run.

## Error Handling And Determinism

- Every run must use a unique `scenarioLabel` to avoid account, device, and chat collisions on the shared backend.
- Driver/bootstrap failures must fail the selected suite rather than quietly degrading to a smaller scenario.
- Missing required client capabilities must fail the scenario.
- If the backend is unavailable, interop suites must fail preflight rather than skip green.
- Evidence mismatch must fail even when the backend mutation itself succeeded.
- The orchestrator should avoid relying only on sleeps; it should poll for semantic evidence with bounded timeouts.
- The harness must clean up local client-owned test state when a scenario requires reset.

## Verification Strategy

Before calling the first rollout complete, verification should include:

- orchestrator parsing/unit coverage for scenario selection and capability gating
- direct local dry-runs of `interop-seeded`
- direct local runs of the reduced `interop-cross` matrix
- regression confirmation that existing platform-local suites still pass independently
- smoke-harness execution through the new interop suites

Expected verification split:

- platform-local proof:
  - `ios-ui`
  - `macos-ui`
  - Android instrumentation/UI
- cross-client proof:
  - `interop-seeded`
  - `interop-cross`

## Rollout Plan

### Wave 1

- add repo-level orchestrator scaffolding
- define the semantic driver contract
- add minimal iOS/macOS/Android drivers
- add `interop-seeded`
- add `interop-cross`
- add resource-aware sequential execution policy
- add harness integration and runbook docs

### Wave 2

- add attachment interop
- expand restore and read-state coverage
- add lifecycle/background-resume scenarios
- add heavier or longer-running nightly-style suites if the local path proves stable

## Risks

- Driver seams that bypass too much UI could weaken confidence if not balanced with explicit UI proof checkpoints.
- Shared backend tests can become flaky if scenario naming is not unique enough.
- Local Genymotion availability becomes a hard dependency for Android interop in wave 1.
- Trying to run too many heavy runtimes simultaneously on one laptop will recreate the memory pressure that prompted this design.
- If platform-local proof suites are allowed to lag behind driver functionality, the harness could validate semantics while missing UI regressions.

## Recommendation

Proceed with a layered interoperability strategy:

- keep platform-local UI suites as UI proof
- add a shared external interop orchestrator
- add semantic drivers for iOS, macOS, and Android
- standardize Android local interop on Genymotion
- start with `interop-seeded` plus a reduced but role-complete `interop-cross` matrix

That gives the project real three-client interoperability coverage without betting the entire local developer workflow on one fragile always-on tri-UI rig.
