# Icon packs

Bundled packs. Packs in `~/.config/gizmobar/icon-packs/` are loaded too and
win on id clashes. The pack named by `[icons].custom_pack` is tried first,
then `[icons].packs` in order. Any pack can be the custom one, and every
change under `icon-packs/` (a new SVG, an edited color) applies live.

Start a new one with `gizmo icons init <id>`.

- `tefer-line/`: the default custom pack. Single-color SVGs on a 24 grid with a
  1.5 stroke (Phosphor Light style), named by bundle ID, `fill="currentColor"`.
  `colors.json` carries the brand colors from SketchyBar's `app_colors.sh`;
  the first 27 icons to draw are exactly those apps.
- `sketchybar-app-font/`: ligatures from the font you use today. Needs the
  font installed (`brew install --cask font-sketchybar-app-font`).
  `glyphs.json` starts with the same 27 apps; the full ~800 mapping gets
  generated from `icon_map_fn.sh` in Phase 2.

Bundle IDs for a few apps (Teams, Claude, Docker) were written from memory;
check with `osascript -e 'id of app "Name"'` and fix them here.
