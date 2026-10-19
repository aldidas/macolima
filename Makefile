.PHONY: gen build run test kit-test clean release install

CODE_SIGN_IDENTITY ?= -

gen:
	xcodegen generate

build: gen
	xcodebuild -project Macolima.xcodeproj -scheme Macolima -configuration Debug -derivedDataPath build build CODE_SIGN_IDENTITY="$(CODE_SIGN_IDENTITY)" CODE_SIGN_STYLE=Manual -skipPackagePluginValidation | tail -5

# Optimised build, ad-hoc signed; re-signed without the hardened runtime, fine
# for a locally built copy, not for distribution.
release: gen
	xcodebuild -project Macolima.xcodeproj -scheme Macolima -configuration Release -derivedDataPath build build CODE_SIGN_IDENTITY="$(CODE_SIGN_IDENTITY)" CODE_SIGN_STYLE=Manual -skipPackagePluginValidation | tail -5
	codesign --force --deep --sign - build/Build/Products/Release/Macolima.app

# Replace /Applications/Macolima.app with the local Release build (backs up the
# previous copy next to it once, as Macolima.previous.app).
install: release
	pkill -x Macolima || true
	sleep 1
	if [ -d /Applications/Macolima.app ] && [ ! -d /Applications/Macolima.previous.app ]; then ditto /Applications/Macolima.app /Applications/Macolima.previous.app; fi
	rm -rf /Applications/Macolima.app
	ditto build/Build/Products/Release/Macolima.app /Applications/Macolima.app
	open /Applications/Macolima.app

# `open` only activates an already-running app, so a rebuilt binary would never
# be exercised. Quit the previous Debug instance first (the /Applications copy is untouched).
run: build
	pkill -f 'build/Build/Products/Debug/Macolima.app/Contents/MacOS/Macolima' || true
	sleep 1
	open build/Build/Products/Debug/Macolima.app

kit-test:
	cd Packages/MacolimaKit && swift test

test: kit-test

clean:
	rm -rf build Macolima.xcodeproj Packages/MacolimaKit/.build
