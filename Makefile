PREFIX ?= $(HOME)/.local
APP := build/Gizmobar.app

# With only the Command Line Tools installed (no Xcode), SwiftPM doesn't put
# swift-testing on the search path. Point it there so `make test` works.
DEV_DIR := $(shell xcode-select -p 2>/dev/null)
ifeq ($(findstring CommandLineTools,$(DEV_DIR)),CommandLineTools)
CLT_FW := $(DEV_DIR)/Library/Developer/Frameworks
TEST_FLAGS := -Xswiftc -F -Xswiftc $(CLT_FW) -Xlinker -F -Xlinker $(CLT_FW) \
	-Xlinker -rpath -Xlinker $(CLT_FW) -Xlinker -rpath -Xlinker $(DEV_DIR)/Library/Developer/usr/lib
endif

.PHONY: build test app run install uninstall config clean hooks

build:
	swift build

test:
	swift test $(TEST_FLAGS)

app:
	./scripts/bundle.sh

run: app
	-pkill -x Gizmobar
	open $(APP)

install: app
	rm -rf /Applications/Gizmobar.app
	cp -R $(APP) /Applications/Gizmobar.app
	mkdir -p $(PREFIX)/bin
	ln -sf /Applications/Gizmobar.app/Contents/MacOS/gizmo $(PREFIX)/bin/gizmo
	@echo "installed; gizmo linked into $(PREFIX)/bin"

uninstall:
	-pkill -x Gizmobar
	rm -rf /Applications/Gizmobar.app $(PREFIX)/bin/gizmo

# Copies the example config into ~/.config/gizmobar without overwriting.
config:
	mkdir -p $(HOME)/.config/gizmobar
	cp -Rn examples/gizmobar/ $(HOME)/.config/gizmobar/ || true

# Commit-msg hook that rejects attribution trailers (scripts/hooks).
hooks:
	git config core.hooksPath scripts/hooks
	@echo "hooks installed from scripts/hooks"

clean:
	rm -rf .build build
