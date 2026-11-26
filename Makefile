PREFIX ?= $(HOME)/.local
APP := build/Gizmobar.app

.PHONY: build test app run install uninstall config clean

build:
	swift build

test:
	swift test

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

clean:
	rm -rf .build build
