# iOS Dark Theme Design

## Summary

This design fixes missing dark-theme support in the iOS onboarding and chat flows by replacing light-only hardcoded surfaces with a small shared theme layer that follows the system light/dark appearance automatically.

The first wave intentionally focuses on the real user-facing surfaces where the bug is visible today:

- onboarding create/link flow
- pending-approval flow
- consumer chat timeline and composer
- obvious related iOS surface hardcodes discovered during the same pass

The change keeps the current branded look and accent color, but moves backgrounds and surfaces onto semantic theme tokens so dark mode becomes predictable and maintainable.

## Context

The current iOS client already mixes semantic system colors and manually tuned light-only colors. The dark-theme bug is most visible in:

- `apps/ios/TrixiOS/Features/Onboarding/CreateAccountView.swift`
- `apps/ios/TrixiOS/Features/Onboarding/PendingApprovalView.swift`
- `apps/ios/TrixiOS/Features/Chats/ConsumerChatDetailView.swift`

These views currently render several surfaces with direct `Color.white` fills and pale blue gradients. In light mode that matches the intended visual style, but in dark mode those surfaces remain bright and break contrast, hierarchy, and overall platform consistency.

The project already has iOS XCTest and XCUITest coverage plus a UI-test launch contract. That makes it practical to add a small amount of theme-oriented verification while keeping the implementation aligned with existing project patterns.

## Goals

- Make onboarding and consumer chat screens automatically adapt to the system light/dark theme.
- Preserve the current branded accent color and general layout structure.
- Introduce a small reusable iOS theme layer so future screens do not reintroduce light-only surfaces.
- Clean up other obvious iOS light-surface hardcodes touched by the same visual system.
- Add focused verification for the new theme layer and dark-mode launch path where it provides real regression value.

## Non-Goals

- No manual theme switcher or persisted theme preference.
- No full design-system rewrite.
- No broad typography, spacing, or navigation redesign.
- No special branding pass for debug/admin screens that already use system `List` styling unless a real dark-mode contrast bug is found there.
- No snapshot-testing framework introduction for this change.

## Decision Summary

The chosen direction is:

1. Add a compact shared iOS theme layer with semantic tokens for backgrounds, cards, elevated fields, incoming chat bubbles, separators, banners, and decorative gradients.
2. Keep the existing brand accent and visual composition, but source all user-facing surfaces from the shared theme layer instead of view-local hardcoded light colors.
3. Prefer semantic system-backed `UIColor` / `Color` values for surfaces and materials so accessibility and platform contrast rules remain consistent across themes.
4. Fully migrate `CreateAccountView`, `PendingApprovalView`, and `ConsumerChatDetailView` to the theme layer in this wave.
5. Replace other obvious iOS light-surface hardcodes found during the pass when the change is a direct thematic cleanup rather than a redesign.
6. Add focused regression coverage for the theme layer and a dark-mode UI-test launch path, then verify the affected screens through targeted iOS test runs.

## Architecture

### 1. Shared Theme Layer

Add a new support file in `apps/ios/TrixiOS/Support/` that defines the small set of theme tokens needed by the current iOS client. This is intentionally not a large design system. It is a narrow semantic palette for the existing app:

- branded accent
- screen background
- decorative background gradient stops
- primary / secondary / tertiary surfaces
- elevated field surface
- incoming chat bubble surface
- chip / separator surface
- banner tint background
- subtle surface stroke / edge treatment where dark mode needs separation

The theme tokens should be authored as dynamic `Color` values backed by semantic `UIColor` or trait-aware closures so the values automatically resolve for light and dark mode without duplicating conditional logic throughout every view.

### 2. Onboarding Surface Migration

`CreateAccountView` and `PendingApprovalView` should keep their current structure and messaging, but all view-level hardcoded light surfaces should migrate onto theme tokens:

- root gradient background
- onboarding cards
- unselected segmented buttons / pills
- text-field containers
- technical details cards
- status/device cards

Bottom action areas can continue using material backgrounds when that remains visually correct, but any adjacent custom surfaces must be theme-aware so the whole screen reads consistently in dark mode.

### 3. Consumer Chat Surface Migration

`ConsumerChatDetailView` should keep its current bubble-based chat design, but dark-mode behavior should stop depending on white fills. The migration should cover:

- chat backdrop gradient and decorative glow layers
- attachment preview tray
- composer input surface
- empty attachment hint surface
- day separators
- incoming message bubbles
- system event cards
- banner backgrounds and chip-like supporting surfaces

Outgoing bubbles should continue using the existing accent color unless contrast or readability forces a small tokenized refinement.

### 4. Broader iOS Cleanup

During the same pass, inspect the rest of `apps/ios/TrixiOS` for obvious `Color.white`-style surface hardcodes. If the use is clearly part of the shared UI language rather than a one-off debug control, replace it with the new theme tokens or semantic system colors.

This broader cleanup should stay scoped to obvious theme debt. The change should not evolve into a redesign of stable system-styled screens.

### 5. UI-Test Appearance Control

Extend the iOS UI-test launch contract so XCUITests can request a specific interface style, at least for dark-mode validation. The app bootstrap should be able to force dark appearance for test runs without adding a user-facing theme preference.

This gives the project a stable way to exercise onboarding and chat flows under dark mode in CI/local smoke runs.

## Verification Strategy

Before calling the work complete, verification should include:

- targeted unit tests for the theme layer behavior that was introduced for this change
- targeted unit tests for any new UI-test launch parsing added for interface-style overrides
- targeted UI smoke coverage that launches core iOS flows in dark mode when the signal is meaningful
- targeted manual/visual verification of onboarding and seeded DM/group chat flows in both light and dark mode
- diagnostics/lints for recently edited iOS files

Expected verification emphasis:

- unit tests protect the theme primitives and launch contract
- UI tests prove the screens can launch and exercise their normal paths in dark mode
- manual inspection confirms contrast/readability on the visually important screens

## Risks And Mitigations

### Risk: dark surfaces lose separation and feel muddy

Mitigation: use a small semantic surface ladder plus a subtle dynamic stroke where cards or chips need visual edges in dark mode.

### Risk: chat visuals regress by over-normalizing to system colors

Mitigation: keep the brand accent and current composition, and only move surfaces/backgrounds to semantic tokens rather than redesigning the whole screen.

### Risk: tests give weak signal for a visual bug

Mitigation: keep automated tests focused on the shared theme primitives and dark-mode launch path, then pair them with targeted manual verification of the affected screens.

### Risk: theme fixes spread into unrelated screens

Mitigation: broader cleanup is limited to obvious light-surface hardcodes that share the same visual system; debug/system screens stay system-styled unless they show a real bug.

## Validation Plan

- Run the targeted iOS unit tests added/updated for the theme layer and launch configuration
- Run targeted iOS UI tests for onboarding and seeded chat flows in dark mode
- Inspect the updated onboarding and consumer chat screens in both light and dark appearance
- Read diagnostics for the edited iOS files and fix introduced issues before marking the work complete
