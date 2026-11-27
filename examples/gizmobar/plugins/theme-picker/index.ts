import { definePlugin, ui } from "@gizmobar/sdk";

// The built-in theme picker, rewritten as a plugin. Lists the themes from
// [plugins.theme-picker] in config.toml and switches with ctx.request,
// the same request the built-in widget sends.
interface Config {
  themes?: string[];
}

export default definePlugin<Config>({
  id: "theme-picker",
  setup(ctx) {
    const themes = ctx.config.themes ?? ["gizmo", "nord", "dracula", "catppuccin-mocha", "tokyo-night"];
    let current = ctx.storage.get<string>("current") ?? "gizmo";
    const title = (id: string) => id.split("-").map((w) => w[0].toUpperCase() + w.slice(1)).join(" ");

    return () =>
      ui.pill({ popover: () => ui.column([
        ui.text("Theme", { size: 13 }),
        ...themes.map((id) =>
          ui.button(title(id), () => {
            current = id;
            ctx.storage.set("current", id);
            ctx.request(`theme.set:${id}`);
          }, id === current ? "checkmark.circle.fill" : "circle"),
        ),
        ui.button("Custom / system icons", () => ctx.request("icons.style.toggle"), "square.grid.2x2"),
      ], 4) }, [ui.icon("paintpalette")]);
  },
});
