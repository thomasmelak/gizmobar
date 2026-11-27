import { definePlugin, ui, type Color } from "@gizmobar/sdk";

// Pings a list of sites every minute and pins them on the dot globe:
// green when they answer, red (pulsing) when they don't. Set your own in
// config.toml; "net:*" in plugin.json lets it reach any host you list.
//
//   [plugins.uptime-globe]
//   every = 60
//   sites = [
//     { name = "Home lab", url = "https://lab.example.com/health", lat = 9.03, lon = 38.74 },
//   ]

interface Site { name: string; url: string; lat: number; lon: number }
interface Config { sites?: Site[]; every?: number }

const defaults: Site[] = [
  { name: "GitHub", url: "https://github.com", lat: 37.78, lon: -122.39 },
  { name: "Cloudflare", url: "https://www.cloudflare.com", lat: 37.77, lon: -122.42 },
  { name: "BBC", url: "https://www.bbc.co.uk", lat: 51.51, lon: -0.13 },
  { name: "Wikipedia", url: "https://www.wikipedia.org", lat: 52.37, lon: 4.9 },
];

export default definePlugin<Config>({
  id: "uptime-globe",
  setup(ctx) {
    const sites = ctx.config.sites?.length ? ctx.config.sites : defaults;
    const state = new Map<string, { up: boolean; ms: number }>();

    const check = async (s: Site) => {
      const start = Date.now();
      try {
        const r = await ctx.fetch(s.url, { method: "HEAD" });
        state.set(s.name, { up: r.status < 500, ms: Date.now() - start });
      } catch {
        state.set(s.name, { up: false, ms: 0 });
      }
      ctx.rerender();
    };
    const checkAll = () => sites.forEach((s) => void check(s));
    checkAll();
    setInterval(checkAll, Math.max(15, ctx.config.every ?? 60) * 1000);

    const markers = () =>
      sites.map((s) => {
        const st = state.get(s.name);
        return {
          lat: s.lat,
          lon: s.lon,
          label: s.name,
          color: (st === undefined ? "theme.accent" : st.up ? "theme.good" : "theme.bad") as Color,
          pulse: st !== undefined && !st.up,
        };
      });

    return () => {
      const down = sites.filter((s) => state.get(s.name)?.up === false).length;
      return ui.pill({
        popover: () => ui.column([
          ui.globe({ markers: markers(), size: 200, spin: "slow" }),
          ...sites.map((s) => {
            const st = state.get(s.name);
            return ui.row([
              ui.icon(st?.up === false ? "xmark.circle.fill" : "checkmark.circle.fill", st?.up === false ? "theme.bad" : "theme.good"),
              ui.text(s.name),
              ui.spacer(),
              ui.text(st ? (st.up ? `${st.ms} ms` : "down") : "…", { mono: true, size: 11 }),
            ]);
          }),
        ], 6),
      }, [
        ui.globe({ markers: markers(), size: 22, spin: "slow" }),
        ...(down > 0 ? [ui.text(`${down} down`, { color: "theme.bad" })] : []),
      ]);
    };
  },
});
