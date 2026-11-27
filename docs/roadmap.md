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
- [x] Theme picker: 12 bundled themes, custom/system icons switch, saved to config.toml
- [x] First Tefer Line icons (the 27 apps with brand colors)
- [x] Right-click icon menu: custom pack, system icon, choose file, reset
- [x] `gizmo icons missing` ranked by use (time in front, activations)
- [ ] Verify every widget and popover on the Mac against SketchyBar

## Phase 3: now playing

- [x] Media provider: Spotify and Music by AppleScript on their change notifications, any app through mediaremote-adapter, `nowplaying-cli` fallback
- [x] Art pipeline: disk cache, color picked from the art, crossfades
- [x] Marquee track text (scrolls on hover only), source picker, scrubbing, shuffle and repeat
- [x] Spectrum from a Core Audio process tap (vDSP FFT), animated fallback
- [x] Popover with tilting art
- [ ] Spectrum drawn with Canvas; move to Metal if it misses the 2% CPU budget while playing

## Phase 4: plugin SDK

- [x] JavaScriptCore runtime: one VM and queue per plugin, timers, fetch, exec, storage
- [x] Widget trees drawn natively, with callbacks and popovers
- [x] Permissions (`provider:*`, `net:<host>`, `exec`, `requests`)
- [x] 2 ms render budget with pause, 250 ms runaway-script limit
- [x] Hot reload: esbuild rebuild on save, storage kept
- [x] Provider types generated from Swift (`gizmo types`), `gizmo new`, `gizmo debug`
- [x] Two built-ins rewritten as plugins: net-speed, theme-picker
- [ ] Re-render only the changed subtree (the whole plugin tree redraws today)
- [ ] Debug overlay on the bar (the numbers are in `gizmo debug` for now)

## Phase 5: 3D scene engine

- [x] glTF/GLB reader (meshes, materials, node tree, animation clips) and USDZ through RealityKit
- [x] `ui.scene`: clips with cross-fades, play-once, per-part color/visibility/rotation, part clicks
- [x] Looks: toon (unlit, with an outline on macOS 15+), pbr, unlit
- [x] Idle scenes freeze to a snapshot; rendering runs only while animating or orbiting
- [x] Popover view you can orbit
- [x] Dot globe as a built-in scene (`ui.globe`, and a `globe` widget): sun-lit day side, markers, pulses
- [x] Examples: status-pet (with its generated model) and uptime-globe
- [ ] Measure the GPU cost of an always-animating model on the bar

## Phase 6: cut over

Remove SketchyBar from `aerospace.toml` and login items; move bar config
to `gizmobar/.config/gizmobar` in dotfiles.
