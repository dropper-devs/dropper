APP      := Dropper
BUILD    := .build/release/$(APP)
BUNDLE   := build/$(APP).app
CONTENTS := $(BUNDLE)/Contents

.PHONY: all build bundle icon install run clean info dist-build sign notarize dmg upload upload-only release

all: bundle

info:
	@. ./build.conf; \
	echo "App:      $$APP_DISPLAY_NAME"; \
	echo "Version:  $$VERSION"; \
	echo "R2:       $$R2_BUCKET/$$R2_PATH"

build:
	swift build -c release

icon: build/$(APP).icns

build/$(APP).icns: tools/make_icon.swift
	mkdir -p build
	swift tools/make_icon.swift build

bundle: build icon
	rm -rf "$(BUNDLE)"
	mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources"
	cp "$(BUILD)" "$(CONTENTS)/MacOS/$(APP)"
	cp Info.plist "$(CONTENTS)/Info.plist"
	cp build/$(APP).icns "$(CONTENTS)/Resources/$(APP).icns"
	@# SwiftPM resource bundle (onboarding art) — Bundle.module finds it in
	@# Contents/Resources at runtime.
	@if [ -d ".build/release/$(APP)_$(APP).bundle" ]; then \
		cp -R ".build/release/$(APP)_$(APP).bundle" "$(CONTENTS)/Resources/"; \
	fi
	@# Developer ID gives the app a stable code identity, so the Keychain
	@# authorizes the stored token once instead of after every rebuild.
	@if security find-identity -v -p codesigning | grep -q "Developer ID Application: John Wheeler"; then \
		codesign --force --options runtime --sign "Developer ID Application: John Wheeler (2L2A6AD7C2)" "$(BUNDLE)"; \
		echo "Signed with Developer ID"; \
	else \
		codesign --force --sign - "$(BUNDLE)"; \
		echo "Signed ad hoc (Developer ID cert not found)"; \
	fi
	@echo "Built $(BUNDLE)"

install: bundle
	rm -rf "/Applications/$(APP).app"
	cp -R "$(BUNDLE)" /Applications/
	@echo "Installed /Applications/$(APP).app — it lives in the menu bar."

run: bundle
	open "$(BUNDLE)"

# Distribution pipeline, modeled after ScreenCam:
# dist-build -> sign -> notarize -> dmg -> upload.
dist-build:
	@./scripts/build-release.sh

sign: dist-build
	@./scripts/sign.sh

notarize: sign
	@./scripts/notarize.sh

dmg: notarize
	@./scripts/dmg.sh

upload: dmg
	@./scripts/upload.sh

upload-only:
	@./scripts/upload.sh

release: upload
	@echo "Dropper release uploaded to R2."

clean:
	rm -rf .build build dist
