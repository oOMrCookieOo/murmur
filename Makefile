.PHONY: build debug run clean sign-cert install check test

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

# Compile with the real build flags, without bundling or signing.
#
# Deliberately NOT `-typecheck`: that skips the passes that produce isolation
# diagnostics, so it once reported "no errors or warnings" on code that failed
# to build. A check that can pass while the build fails is worse than no check.
check:
	@mkdir -p build/check
	@swiftc -swift-version 6 -O -whole-module-optimization \
		-target $$(uname -m)-apple-macos27.0 \
		-module-name Murmur \
		-o build/check/Murmur \
		$$(find Murmur -name '*.swift') && echo "==> Compiles clean"

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

# Run the safety tests (pure functions, no app launch)
SHARED_TEST_SOURCES = \
	Murmur/Cleanup/TranscriptCleaner.swift \
	Murmur/Core/Timeout.swift \
	Murmur/Core/Log.swift \
	Murmur/Core/AppSettings.swift \
	Murmur/Input/TriggerKey.swift

test:
	@mkdir -p build/tests
	@swiftc -swift-version 6 -target $$(uname -m)-apple-macos27.0 \
		-o build/tests/cleanup-tests \
		Tests/CleanupTests.swift $(SHARED_TEST_SOURCES)
	@./build/tests/cleanup-tests
	@echo ""
	@swiftc -swift-version 6 -target $$(uname -m)-apple-macos27.0 \
		-o build/tests/settings-tests \
		Tests/SettingsTests.swift $(SHARED_TEST_SOURCES)
	@./build/tests/settings-tests
	@echo ""
	@swiftc -swift-version 6 -target $$(uname -m)-apple-macos27.0 \
		-o build/tests/history-tests \
		Tests/HistoryTests.swift \
		Murmur/Core/TranscriptHistory.swift \
		Murmur/Core/Log.swift
	@./build/tests/history-tests

