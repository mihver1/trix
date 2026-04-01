# Onboarding Simplification Review

## Understanding Summary

- Simplify onboarding across iOS, macOS, and Android.
- Remove feature-marketing copy and large explanatory panels from the bootstrap screens.
- Keep the onboarding focused on four tasks: set server URL, check server availability, create a user, or link a device.
- Keep `handle` in onboarding.
- Remove `bio` from onboarding.
- Keep pending-approval as a separate, explicit state instead of folding it into the initial onboarding form.

## Approaches Considered

### 1. Cosmetic Copy Trim Only

- Keep the current layouts and remove some text.
- Rejected because it would leave three different onboarding structures in place and would not fix Android parity gaps around server checking.

### 2. Shared Task-First Onboarding

- Use the same information architecture in all clients:
  1. Server section
  2. Mode switch
  3. Mode-specific form
  4. Primary action
- Accepted because it keeps the scope moderate while making the flow simpler and more consistent.

### 3. Wizard / Stepper

- Split onboarding into separate steps for server, account creation, and linking.
- Rejected because it adds state and UI complexity without solving a real product need.

## Decision Log

1. Use a shared task-first onboarding structure across clients.
   - Alternatives: cosmetic trim only; wizard/stepper.
   - Rationale: best balance of simplicity, parity, and implementation cost.

2. Remove `bio` from onboarding.
   - Alternative: move it into an advanced section.
   - Rationale: not bootstrap-critical and explicitly out of scope for the simpler flow.

3. Keep `handle` in onboarding.
   - Alternative: remove it with `bio`.
   - Rationale: explicitly requested by the user.

4. Keep a small amount of critical helper copy.
   - Alternative: remove nearly all copy.
   - Rationale: users still need concise trust-model guidance for linking and pending approval.

5. In link mode, resolve the effective server endpoint from the link payload when it includes `base_url`; otherwise use the editable server URL field.
   - Alternative: always use or check the visible field only.
   - Rationale: avoids checking or submitting against the wrong backend.

6. Clear visible health/check state whenever the effective endpoint may have changed.
   - Alternative: keep the last successful check visible until the next check.
   - Rationale: avoids stale success signals and check/submit drift.

7. Make handle labeling explicit that it is public and optional.
   - Alternative: keep the old ambiguous handle label.
   - Rationale: reduces privacy confusion and form hesitation.

## Review Findings And Resolutions

### Skeptic / Challenger

1. Wrong-endpoint checks in link mode.
   - Resolution: accepted; link-mode checks now use the effective endpoint from the parsed payload when available.

2. Removing too much copy can obscure the trust model.
   - Resolution: accepted; keep concise link/pending-approval guidance while removing feature copy.

3. Cross-client parity is more than layout.
   - Resolution: accepted; parity is defined as shared information architecture plus shared user-facing semantics, not identical internals.

4. Preserving identifiers will not eliminate all UI test churn.
   - Resolution: accepted; preserve semantic identifiers where unchanged, but update tests intentionally where needed.

### Constraint Guardian

5. Endpoint-resolution drift between check and submit.
   - Resolution: accepted; endpoint-affecting changes clear visible check state, and checks remain advisory rather than submit gates.

### User Advocate

6. Silent server override in link mode.
   - Resolution: accepted; link mode must visibly indicate when the link code supplies the server target.

7. Approval state can become too easy to miss after simplification.
   - Resolution: accepted; pending approval remains a separate, explicit screen with strong messaging.

8. Handle meaning becomes unclear if it stays in onboarding.
   - Resolution: accepted; label it as public and optional.

## Final Design

- Each client shows a compact onboarding flow with:
  - a server section with editable URL and explicit availability check
  - a create/link mode switch
  - a mode-specific form
  - one primary action
- Create mode keeps:
  - profile name
  - handle (public, optional)
  - device name
- Link mode keeps:
  - link payload/code
  - device name
- Link mode explicitly surfaces when the link code overrides the server URL.
- Pending approval remains separate and prominent.

## Final Disposition

APPROVED

The reviewer loop found no unresolved blockers after the endpoint-resolution and trust-model clarifications were added to the design.
