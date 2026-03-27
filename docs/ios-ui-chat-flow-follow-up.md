# iOS UI Chat Flow Follow-Up

The first `ios-ui` rollout now covers three deterministic simulator-backed screen flows:

- create-account onboarding
- pending linked-device approval waiting state
- seeded approved-account dashboard navigation

The next increment is chat-list and chat-detail coverage without re-implementing backend fixture logic inside each `XCUITest`.

## Goal

Extract reusable server-seeding helpers so iOS UI tests can launch directly into:

- a seeded account with one or more visible chats in the dashboard list
- a seeded chat detail screen with a stable message timeline
- a seeded sender account that can send a message and verify local echo plus refresh

## Recommended Extraction

Move the current account/link seeding logic behind a small fixture API in app-target code, for example:

- `UITestServerSeedScenario`
- `UITestSeededAccount`
- `UITestFixtureSeeder`

That layer should own:

- creating approved accounts with bounded handles
- creating pending linked devices
- creating a second approved account for peer conversation setup
- creating a DM or group chat before app launch
- optionally sending one or more seed messages before app launch

## Launch Contract

Extend the UI-test launch contract with scenario inputs that remain stable across app and test bundles:

- account state scenario: approved, pending approval
- conversation scenario: empty dashboard, one DM, one group, populated chat detail
- optional scenario label for uniqueness in server-side fixtures

The app bootstrap should continue doing all server seeding before `AppModel.start(...)` so UI tests stay deterministic and do not need to tap through setup screens.

## Suggested First Scenarios

1. Seed one approved account with one DM and assert the chat appears in the dashboard list.
2. Launch directly into that DM and assert the seeded message timeline is visible.
3. Send a new text message from the chat detail screen and assert it appears locally.
4. Seed a group chat and assert member-driven UI affordances render correctly.

## Guardrails

- Keep fixture creation in app-target support code, not inside UI test methods.
- Continue using stable `accessibilityIdentifier` values for all new chat-list and chat-detail anchors.
- Reuse one simulator-friendly base URL contract for both `ios-server` and `ios-ui`.
- Prefer short, bounded handles and device names so fixture generation cannot fail validation.
