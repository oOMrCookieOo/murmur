.PHONY: build debug run clean sign-cert install check

# Build a release Murmur.app into ./build
build:
	@./Scripts/build-app.sh

debug:
	@CONFIG=debug ./Scripts/build-app.sh

# Build, then relaunch (killing any running copy first)
run: build
	@pkill -x Murmur 2>/dev/null || true
	@open build/Murmur.app
	@echo "==> Murmur is running. Look for the mic icon in the menu bar."

# Typecheck only; fastest way to validate a change
check:
	@swiftc -typecheck -swift-version 6 \
		-target $$(uname -m)-apple-macos27.0 \
		$$(find Murmur -name '*.swift') && echo "==> No errors or warnings"

# One-time: create a self-signed certificate so permissions survive rebuilds
sign-cert:
	@./Scripts/make-signing-cert.sh

install: build
	@pkill -x Murmur 2>/dev/null || true
	@rm -rf /Applications/Murmur.app
	@cp -R build/Murmur.app /Applications/
	@echo "==> Installed to /Applications/Murmur.app"

clean:
	@rm -rf build
	@echo "==> Cleaned"
