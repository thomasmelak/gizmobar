# Gizmobar

A fast, native macOS status bar written in Swift. A panel on every display,
AeroSpace workspaces, rich now playing, 3D models, and TypeScript plugins.

Gizmobar replaces a SketchyBar setup that spent its time starting shell
processes. Here nothing on the render path starts a process: providers read
macOS APIs in-process, push events onto one bus, and SwiftUI redraws at most
once per frame.

> Status: early scaffold (Phase 1). Workspaces, front app and clock work;
> everything else is on the [roadmap](docs/roadmap.md).

## Build and run

Requires macOS 14+ (Liquid Glass on macOS 26) and Swift 6.

```sh
make test          # unit tests
make config        # copy examples/gizmobar into ~/.config/gizmobar
make run           # build Gizmobar.app and launch it
make install       # install to /Applications and link `gizmo` into ~/.local/bin
```

Sign with a stable identity so privacy grants survive rebuilds:

```sh
SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" make app
```

## The `gizmo` CLI

```sh
gizmo ping
gizmo trigger vpn.status up=true    # push your own events onto the bus
gizmo reload                        # re-read config, theme and icon packs
gizmo state
gizmo icons missing                 # open apps the icon packs don't cover
gizmo icons init my-icons           # start a custom icon pack
```

## AeroSpace

With AeroSpace 0.21+ the bar keeps one `aerospace subscribe` stream open, so
`aerospace.toml` needs no bar callbacks. On older versions set
`[aerospace] mode = "callback"` and add:

```toml
exec-on-workspace-change = ['gizmo', 'trigger', 'aerospace.workspace']
```

## Configuration

`~/.config/gizmobar/`:

```
config.toml          # layout, bar, icons, aerospace (see examples/gizmobar)
themes/<name>.toml   # design tokens; missing keys fall back to Tefer
icon-packs/<id>/     # extra or replacement icon packs
plugins/<id>/        # TypeScript plugins (runtime arrives in Phase 4)
```

App icons resolve per bundle ID: per-app override, then `style = "system"`
for real macOS icons everywhere, otherwise your custom pack, then the other
packs in order, then the fallback you pick.

The custom pack is whichever pack `custom_pack` names (Tefer Line by
default). Start your own with `gizmo icons init my-icons`, drop
`<bundle-id>.svg` files into it, and the bar picks them up live, no reload.

## Layout

```
Sources/
  GizmoCore/       events, bus, config, theme, icon resolver, plugin manifest
  GizmoIPC/        Unix socket protocol for the CLI
  GizmoProviders/  AeroSpace, apps, clock, displays
  GizmoScene/      3D scene contract (glTF/GLB/USDZ, Phase 5)
  GizmoUI/         panels per display, widgets, icon rendering
  Gizmobar/        the app
  gizmo/           the CLI
sdk/               @gizmobar/sdk for TypeScript plugins
icon-packs/        bundled packs
examples/gizmobar/ example ~/.config/gizmobar
```

See [docs/architecture.md](docs/architecture.md) for how the pieces fit.
