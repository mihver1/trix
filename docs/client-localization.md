# Client Localization

`Trix` now keeps the shared user-facing client copy in one repo-level catalog: [`strings.yaml`](../strings.yaml).

Today that catalog is used for the shared chat and error surfaces that need to stay aligned across:

- Android resource XML
- iOS generated Swift lookup code
- macOS generated Swift lookup code

Supported locales are currently:

- `en`
- `ru`

## Authoritative Inputs

- catalog: [`strings.yaml`](../strings.yaml)
- generator: [`scripts/generate_strings.rb`](../scripts/generate_strings.rb)

Catalog rules:

- keys must use `snake_case`
- every key must define all supported locales
- placeholders use named tokens like `%{chat_id}` and must stay semantically aligned across locales

## Generate Outputs

Refresh all generated client strings with:

```bash
make strings-generate
```

Equivalent direct command:

```bash
ruby scripts/generate_strings.rb
```

Generated outputs:

- Android: [`apps/android/app/src/main/res/values/strings.xml`](../apps/android/app/src/main/res/values/strings.xml)
- Android Russian: [`apps/android/app/src/main/res/values-ru/strings.xml`](../apps/android/app/src/main/res/values-ru/strings.xml)
- iOS: [`apps/ios/TrixiOS/Generated/TrixStrings.generated.swift`](../apps/ios/TrixiOS/Generated/TrixStrings.generated.swift)
- macOS: [`apps/macos/Sources/TrixMac/Generated/TrixStrings.generated.swift`](../apps/macos/Sources/TrixMac/Generated/TrixStrings.generated.swift)

Do not hand-edit those generated files.

## Build Integration

- iOS prebuild regenerates `TrixStrings.generated.swift` before the `trix-core` bridge step.
- macOS prebuild regenerates `TrixStrings.generated.swift` before the bridge and universal Rust archive steps.
- Android Gradle tracks `strings.yaml` and `scripts/generate_strings.rb` as task inputs and regenerates `res/values*/strings.xml` during the app build.

If you only touch `strings.yaml` and do not run a native platform build locally, run `make strings-generate` before committing so the checked-in generated outputs stay in sync.

## Client Usage

- Apple clients consume the generated lookup helpers through `TrixStrings.text(...)`.
- Apple-specific error sanitizers live in `TrixUserFacingText.swift`; keep mapping logic there and keep the translated copy in `strings.yaml`.
- Android consumes the generated resource IDs through the normal `R.string.*` path.
