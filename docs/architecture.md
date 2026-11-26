# Architecture

One process, Swift 6 with strict concurrency. Data flows down; nothing in
the render path starts a process.

```
aerospace subscribe ─┐
NSWorkspace ─────────┤
clock ───────────────┼─▶ EventBus ─▶ BarStore (BarSnapshot) ─▶ SwiftUI in an NSPanel per display
gizmo trigger (CLI) ─┘   coalesce        @Observable
                         per (topic,key)
```

## Event bus

`EventBus` is an actor. Publishers never wait. Events published inside one
flush window (16 ms) collapse to the latest per `(topic, key)`, so a burst
of window events during a workspace switch reaches the UI once. External
scripts publish through `gizmo trigger <topic> k=v`.

## Providers

One actor per source. Push where macOS has a notification, poll on a
coalesced timer only while something visible subscribes.

| Provider   | Source                                         | Phase |
|------------|------------------------------------------------|-------|
| aerospace  | `aerospace subscribe` stream + one-off snapshot | 1 |
| apps       | NSWorkspace activation notifications           | 1 |
| clock      | timer aligned to the second                    | 1 |
| displays   | NSScreen + DisplayServices / DDC/CI / software dimming | 1 (list), 2 (control) |
| cpu, memory, network, power, audio, sensors | in-process APIs | 2 |
| media, audioSpectrum | mediaremote-adapter, Core Audio tap  | 3 |

## Panels

`PanelManager` puts one borderless, non-activating `NSPanel` on each screen
(or only the main one), joining all Spaces, and rebuilds them when the
display layout changes. The panel is transparent; each pill is its own
piece of glass (`NSGlassEffectView` on macOS 26, `NSVisualEffectView`
before) tinted with the theme.

## Icons

`IconResolver` is pure and tested. Order: per-app override → `style =
system` → the custom pack (`custom_pack`, any pack id) → other packs in
order → fallback (`system` mono/color, `monogram`, `generic`).
`GizmoUI.IconCache` rasterises each image once. `ConfigWatcher` (FSEvents
on `~/.config/gizmobar`) reloads packs and drops the cache whenever an icon
file changes, and reloads config/theme on edit.

## Plugins (Phase 4)

TypeScript, one JavaScriptCore context per plugin, off the main thread.
A plugin returns a widget tree (`@gizmobar/sdk`); the host diffs and draws
it. Each render has a 2 ms budget; permissions come from `plugin.json`.

## 3D (Phase 5)

`GizmoScene.SceneDescriptor` is what `ui.scene({...})` produces: a glTF/GLB
or USDZ model (or a built-in like the globe), an animation clip, a look
(toon/pbr/unlit) and per-part overrides. RealityKit first; an own Metal
renderer with GLTFKit2 if RealityKit costs too much at bar size. Draws on
demand: 0 fps when still, 30 fps while animating, nothing when occluded.
