# macOS TestFlight Archive Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prepare the macOS app for App Store Connect / TestFlight by enabling the minimum sandbox entitlements, fixing sandbox-sensitive attachment import behavior, and adding a repeatable archive/export CLI path.

**Architecture:** Keep the existing Xcode project and automatic signing model, but add a committed entitlements file and explicit archive/export tooling for the App Store Connect path. Runtime behavior that depends on user-selected files moves to app-controlled copied files so sandboxed TestFlight builds behave like local builds.

**Tech Stack:** Xcode, `xcodebuild`, Xcode project build settings, macOS App Sandbox entitlements, SwiftUI, Foundation file APIs, Security framework, existing `TrixMac` app code.

---

## File Structure

### Existing files to modify

- `apps/macos/TrixMac.xcodeproj/project.pbxproj`
  - wire the app entitlements file into the app target and set the application category
- `apps/macos/project.yml`
  - keep the XcodeGen source of truth aligned with the committed project settings
- `apps/macos/Sources/TrixMac/App/AppModel.swift`
  - make imported attachments safe for sandboxed later use
- `apps/macos/Sources/TrixMac/Features/Workspace/WorkspaceView.swift`
  - adjust the importer call site only if needed to route through the new import flow

### New files to create

- `apps/macos/TrixMac.entitlements`
  - minimum App Sandbox entitlements for the App Store Connect path
- `apps/macos/scripts/archive-testflight.sh`
  - repeatable `archive` / `exportArchive` flow
- `apps/macos/AppStoreConnectExportOptions.plist`
  - stable export settings for `app-store-connect`

### Optional test files to create

- `apps/macos/Tests/TrixMacTests/ImportedAttachmentStoreTests.swift`
  - focused coverage if attachment-copy logic is extracted into an independently testable helper

## Task 1: Add App Store Entitlements And Metadata

**Files:**
- Create: `apps/macos/TrixMac.entitlements`
- Modify: `apps/macos/TrixMac.xcodeproj/project.pbxproj`
- Modify: `apps/macos/project.yml`

- [ ] **Step 1: Implement the configuration changes**

Add the entitlements file with:

```xml
<key>com.apple.security.app-sandbox</key>
<true/>
<key>com.apple.security.network.client</key>
<true/>
<key>com.apple.security.files.user-selected.read-only</key>
<true/>
```

Update the app target build settings to include:

```text
CODE_SIGN_ENTITLEMENTS = TrixMac.entitlements
```

and set:

```text
LSApplicationCategoryType = public.app-category.social-networking
```

- [ ] **Step 2: Verify the project configuration**

Run:

```bash
xcodebuild -project "apps/macos/TrixMac.xcodeproj" -scheme "TrixMac" -showBuildSettings | rg "CODE_SIGN_ENTITLEMENTS|PRODUCT_BUNDLE_IDENTIFIER|MARKETING_VERSION"
```

Expected:

- `CODE_SIGN_ENTITLEMENTS = TrixMac.entitlements`
- `PRODUCT_BUNDLE_IDENTIFIER = com.softgrid.trixapp`

## Task 2: Make Attachment Import Sandbox-Safe

**Files:**
- Modify: `apps/macos/Sources/TrixMac/App/AppModel.swift`
- Modify: `apps/macos/Sources/TrixMac/Features/Workspace/WorkspaceView.swift`
- Test: `apps/macos/Tests/TrixMacTests/ImportedAttachmentStoreTests.swift` if a helper is extracted

- [ ] **Step 1: Write the failing test or helper harness**

If the import/copy logic is extracted, add a test that proves a source file is copied into app-owned storage and the copied file preserves name and byte count.

Suggested test shape:

```swift
func testImportCopiesAttachmentIntoOwnedStorage() throws {
    let sourceURL = temporaryDirectory.appendingPathComponent("hello.txt")
    try Data("hello".utf8).write(to: sourceURL)

    let copied = try ImportedAttachmentStore(rootURL: destinationRoot).importFile(at: sourceURL)

    XCTAssertNotEqual(copied.fileURL, sourceURL)
    XCTAssertTrue(FileManager.default.fileExists(atPath: copied.fileURL.path))
    XCTAssertEqual(copied.fileName, "hello.txt")
    XCTAssertEqual(copied.fileSizeBytes, 5)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
swift test --package-path apps/macos --filter ImportedAttachmentStoreTests
```

Expected: FAIL because the helper does not exist yet, or because the copy behavior is not implemented.

- [ ] **Step 3: Implement the minimal runtime change**

Change the import flow so user-selected files are copied immediately into app-owned storage before `AttachmentDraft` is stored. The later send path should read from the copied file URL, not the original external location.

- [ ] **Step 4: Run targeted verification**

Run:

```bash
swift test --package-path apps/macos --filter ImportedAttachmentStoreTests
```

Expected: PASS for the helper test if the helper exists.

Then run a normal macOS build:

```bash
xcodebuild -project "apps/macos/TrixMac.xcodeproj" -scheme "TrixMac" -configuration Release -destination "generic/platform=macOS" build CODE_SIGNING_ALLOWED=NO
```

Expected: `** BUILD SUCCEEDED **`

## Task 3: Add A Repeatable TestFlight Archive Script

**Files:**
- Create: `apps/macos/AppStoreConnectExportOptions.plist`
- Create: `apps/macos/scripts/archive-testflight.sh`

- [ ] **Step 1: Write the export options file**

Use an App Store Connect export configuration similar to:

```xml
<key>method</key>
<string>app-store-connect</string>
<key>destination</key>
<string>export</string>
<key>signingStyle</key>
<string>automatic</string>
<key>uploadSymbols</key>
<true/>
```

- [ ] **Step 2: Implement the archive script**

The script should:

1. define archive/export output paths
2. run `xcodebuild archive`
3. optionally run `xcodebuild -exportArchive`
4. pass `-allowProvisioningUpdates`
5. print the final archive/export locations

Suggested core commands:

```bash
xcodebuild \
  -project "$APP_ROOT/TrixMac.xcodeproj" \
  -scheme "TrixMac" \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -archivePath "$ARCHIVE_PATH" \
  -allowProvisioningUpdates \
  archive

xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$APP_ROOT/AppStoreConnectExportOptions.plist" \
  -allowProvisioningUpdates
```

- [ ] **Step 3: Verify archive creation**

Run:

```bash
apps/macos/scripts/archive-testflight.sh
```

Expected:

- `xcodebuild archive` succeeds
- an `.xcarchive` exists at the printed path
- export succeeds when signing/profiles are available locally

## Task 4: Validate Distribution Readiness

**Files:**
- Inspect only

- [ ] **Step 1: Inspect entitlements on the archived app**

Run:

```bash
codesign -d --entitlements :- "path/to/TrixMac.xcarchive/Products/Applications/TrixMac.app"
```

Expected: the output contains:

- `com.apple.security.app-sandbox`
- `com.apple.security.network.client`
- `com.apple.security.files.user-selected.read-only`

- [ ] **Step 2: Re-check diagnostics**

Run lints/diagnostics for recently edited files and fix any introduced issues.

- [ ] **Step 3: Smoke-check the app store path**

If export succeeds, confirm the exported artifact exists and is ready for the next upload step via Xcode Organizer, `xcodebuild`, or Transporter.
