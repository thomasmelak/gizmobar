# Roadmap

Every phase leaves a working bar. SketchyBar keeps running until Gizmobar
reaches parity.

## Phase 1: host skeleton and workspaces (this scaffold)

- [x] SwiftPM package, app bundle script, `gizmo` CLI over a Unix socket
- [x] Event bus with coalescing, observable store
- [x] Config (`config.toml`), default Gizmo theme (Tefer colors) ported from SketchyBar
- [x] Panel per display, glass background, rebuild on display changes
- [x] AeroSpace provider on `aerospace subscribe`, callback fallback
- [x] Logo (app icon by default, any image/text via `[logo]`), workspace pills with app icons, front app
- [x] Clock like the SketchyBar one, with world clocks (`[[clock.world]]`) and a calendar popover
- [x] Icon resolver with overrides and fallback; Tefer Line and sketchybar-app-font packs
- [ ] Verify on the Mac: build, panels on built-in + external display, subscribe stream
- [ ] Focus workspaces over AeroSpace's socket instead of the CLI
- [ ] Launch at login tested from /Applications
- [ ] Hotkey to switch between SketchyBar and Gizmobar during Phases 1–3

## Phase 2: providers and widgets at parity

- [x] Popovers as anchored glass child panels, closed by clicking outside
- [x] System: CPU, GPU, temperature, RAM, swap, disk, lid angle (in-process), Performance popover
- [x] Network: speeds from 64-bit counters, Connectivity popover with Wi-Fi/Bluetooth switches
- [x] Battery: Low Power Mode and No Sleep switches, health, charge limit; Sound: volume slider, mute, output devices
- [x] Displays: brightness (built-in, DDC, software dimming), contrast over DDC, Night Shift
- [ ] Theme picker, Tefer Line icons, right-click icon menu


CPU/GPU, memory, disk, network, power, audio, sensors; display control for
built-in (DisplayServices) and external monitors (DDC/CI, software dimming
fallback); popovers as child panels; first Tefer Line icons; right-click
icon menu; `gizmo icons missing` ranked by use.

## Phase 3: now playing

mediaremote-adapter, art pipeline, color extraction, crossfades, marquee,
Metal spectrum from a Core Audio process tap.

## Phase 4: plugin SDK

JavaScriptCore runtime, widget tree diffing, permissions, budgets, hot
reload, generated TypeScript types, `gizmo new`, `gizmo debug`.

## Phase 5: 3D scene engine

`ui.scene` with glTF/GLB/USDZ, animation clips, per-part changes,
toon/pbr/unlit, popover view; the globe as a built-in scene.

## Phase 6: cut over

Remove SketchyBar from `aerospace.toml` and login items; move bar config
to `gizmobar/.config/gizmobar` in dotfiles.
