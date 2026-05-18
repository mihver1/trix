check:
	cargo check --workspace

fmt:
	cargo fmt --all

check-apple:
	cd apple && xcodegen generate
	xcodebuild -project apple/TrixMatrix.xcodeproj -scheme TrixMatrixMac -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
	xcodebuild -project apple/TrixMatrix.xcodeproj -scheme TrixMatrixiOS -destination 'platform=iOS Simulator,name=iPhone 17' build CODE_SIGNING_ALLOWED=NO

run-push-gateway:
	cargo run -p trix-push-gateway
