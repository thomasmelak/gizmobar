# Writing plugins

A plugin is a small TypeScript program that describes a widget. The bar
runs it in its own JavaScriptCore context and draws the result natively,
so a plugin looks and behaves like the built-in widgets: same pills,
glass, hover styling, pointer cursor and popovers.

## Five minutes to the bar

```sh
gizmo new cpu-meter              # ~/.config/gizmobar/plugins/cpu-meter
brew install esbuild             # the bar rebuilds plugins on save
```

Add the id to your layout in `~/.config/gizmobar/config.toml`:

```toml
[layout]
right = ["cpu-meter", "network", "clock"]
```

Edit `index.ts` and save; the plugin rebuilds and reloads in place,
keeping its `ctx.storage`. Without esbuild on your PATH, run
`npm install && npm run build` in the plugin folder instead.

## Anatomy

```
plugins/cpu-meter/
  plugin.json      # id, version, entry, permissions
  index.ts         # your code
  gizmobar.d.ts    # types for @gizmobar/sdk (refresh: gizmo types > gizmobar.d.ts)
  dist/index.js    # the bundle the bar loads
```

```ts
import { definePlugin, ui, fmt } from "@gizmobar/sdk";

export default definePlugin({
  id: "cpu-meter",
  setup(ctx) {
    const cpu = ctx.use("cpu", { every: "2s" });   // needs "provider:cpu"
    return () =>
      ui.row({
        icon: "cpu",
        label: fmt.percent(cpu.value?.usage ?? 0),
        popover: () => ui.column([ui.text("Busy cores")]),
      });
  },
});
```

`setup` runs once and returns a render function. The bar calls render
again whenever something it read changed: a provider update, a timer, a
click, a fetch result. Keep render cheap and pure; do work in `setup`,
timers and callbacks.

## Providers

`ctx.use(name)` gives a signal whose `.value` is the latest data. Each
needs `provider:<name>` in `plugin.json`. `every` sets a minimum interval
("500ms", "2s", "1m").

| Provider | What |
| --- | --- |
| `workspaces` | AeroSpace workspaces and their apps |
| `apps` | the frontmost app |
| `clock` | ticks every second |
| `network` | throughput, interface, Wi-Fi or Ethernet, IP |
| `cpu` | CPU and GPU load, temperature |
| `memory` | RAM, swap and disk |
| `power` | battery percent, charging, Low Power Mode |
| `media` | now playing: title, artist, art, position, color |
| `audio` | volume, mute, output device |
| `displays` | displays and their brightness |

The exact shapes are in `gizmobar.d.ts`; they're generated from the Swift
definitions, so they always match what the bar sends.

## Widgets

`ui.row`, `ui.pill`, `ui.stack`, `ui.column`, `ui.text` (with `marquee`
and `mono`), `ui.icon` (any SF Symbol name), `ui.image`, `ui.appIcon`
(follows your icon settings), `ui.graph`/`ui.sparkline`, `ui.slider`,
`ui.toggle`, `ui.button`, `ui.scene`/`ui.globe` (3D), `ui.spacer`.

Colors are hex (`"#ff5c7a"`) or theme tokens (`"theme.accent"`,
`"theme.good"`, `"theme.netDown"`...), so plugins follow theme changes.

## Context

| | Permission |
| --- | --- |
| `ctx.use(provider, { every })` | `provider:<name>` |
| `ctx.on(topic, cb)`: any bus topic, e.g. from `gizmo trigger` | none |
| `ctx.emit(topic, payload)`: publishes `plugin.<id>.<topic>` | none |
| `ctx.request(name)`: built-in actions like `theme.set:nord` | `requests` |
| `ctx.fetch(url)` | `net:<host>` |
| `ctx.exec(cmd, args)` | `exec` |
| `ctx.storage.get/set`: kept across reloads | none |
| `ctx.open(url)`, `ctx.rerender()`, `ctx.config`, `ctx.theme` | none |

`ctx.config` is the `[plugins.<id>]` table from config.toml.
`setTimeout`/`setInterval` work as usual.

## 3D scenes

`ui.scene` puts a model on the bar. Drop a `.glb`, `.gltf` or `.usdz` in
your plugin folder and point at it:

```ts
ui.scene({
  model: "models/gizmo-bot.glb",
  size: 28,                                   // clamped to the bar height
  look: "toon",                               // toon | pbr | unlit
  animation: { clip: "dance", loop: true, blend: 0.3 },
  parts: { Antenna: { color: "theme.accent" } },
  caption: "Dancing",                         // tooltip, and under the popover model
  onClick: () => ctx.scene.play("wave", { once: true }),
  popover: { size: 240, orbit: true },        // a bigger copy you can drag around
});
```

- **Clips**: glTF animations play by name. Changing `animation.clip`
  cross-fades over `blend` seconds. `ctx.scene.play(clip, { once })` plays
  one on top and returns to the current clip; `ctx.scene.clips()` lists
  them once the model has loaded.
- **Parts**: `parts` and `ctx.scene.set(name, { color, visible, rotation })`
  change glTF nodes by name. `ctx.scene.on("click", (part) => ...)` tells
  you which node was clicked.
- **Looks**: `toon` is flat color with an outline (the default; the outline needs macOS 15), `pbr` uses
  the model's own materials and lighting, `unlit` is flat color only.
- **Cost**: a scene only renders while it animates or you drag it. When it
  is still, it is swapped for a snapshot, so a resting model costs nothing.
- `popover` can also be a function that returns your own widget tree,
  like any pill.

`ui.globe` is the built-in dot globe, with the day side lit from the sun's
real position:

```ts
ui.globe({
  size: 22,
  spin: "slow",                               // degrees per second, or slow | medium | fast
  markers: [{ lat: 9.03, lon: 38.74, color: "theme.good", label: "Addis", pulse: true }],
});
```

Without a plugin, add `"globe"` to a `[layout]` list for a globe that marks
where you are and your `[[clock.world]]` zones.

## Guard rails

- **Permissions**: nothing beyond the list above is reachable; there is no
  file system, no network without `net:<host>`, no processes without `exec`.
- **Isolation**: each plugin has its own JavaScriptCore VM on its own
  queue. A crash shows a warning pill for that plugin only.
- **Budget**: every render is timed. Five renders in a row over 2 ms pause
  the plugin (`gizmo plugins resume <id>`). A render stuck in a loop is
  stopped after 250 ms.
- **Debug**: `gizmo debug` lists render counts, average and worst render
  times, overruns and provider update counts; `gizmo plugins log` shows
  each plugin's console output and errors.

## Examples

`examples/gizmobar/plugins/`:

- `net-speed`: the built-in network widget as a plugin (providers, graphs, popover)
- `theme-picker`: config, storage and requests
- `status-pet`: a robot model that sleeps, dances, runs or idles with the
  battery, music and CPU, and sits down with a cable in while charging
  (`ui.scene`, clips, click to wave; `charging = false` turns that off)
- `uptime-globe`: pings your sites and pins them on the globe (`ctx.fetch`,
  timers, `ui.globe`)
