var __plugin = (() => {
  var __defProp = Object.defineProperty;
  var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
  var __getOwnPropNames = Object.getOwnPropertyNames;
  var __hasOwnProp = Object.prototype.hasOwnProperty;
  var __require = /* @__PURE__ */ ((x) => typeof require !== "undefined" ? require : typeof Proxy !== "undefined" ? new Proxy(x, {
    get: (a, b) => (typeof require !== "undefined" ? require : a)[b]
  }) : x)(function(x) {
    if (typeof require !== "undefined") return require.apply(this, arguments);
    throw Error('Dynamic require of "' + x + '" is not supported');
  });
  var __export = (target, all) => {
    for (var name in all)
      __defProp(target, name, { get: all[name], enumerable: true });
  };
  var __copyProps = (to, from, except, desc) => {
    if (from && typeof from === "object" || typeof from === "function") {
      for (let key of __getOwnPropNames(from))
        if (!__hasOwnProp.call(to, key) && key !== except)
          __defProp(to, key, { get: () => from[key], enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable });
    }
    return to;
  };
  var __toCommonJS = (mod) => __copyProps(__defProp({}, "__esModule", { value: true }), mod);

  // index.ts
  var uptime_globe_exports = {};
  __export(uptime_globe_exports, {
    default: () => uptime_globe_default
  });
  var import_sdk = __require("@gizmobar/sdk");
  var defaults = [
    { name: "GitHub", url: "https://github.com", lat: 37.78, lon: -122.39 },
    { name: "Cloudflare", url: "https://www.cloudflare.com", lat: 37.77, lon: -122.42 },
    { name: "BBC", url: "https://www.bbc.co.uk", lat: 51.51, lon: -0.13 },
    { name: "Wikipedia", url: "https://www.wikipedia.org", lat: 52.37, lon: 4.9 }
  ];
  var uptime_globe_default = (0, import_sdk.definePlugin)({
    id: "uptime-globe",
    setup(ctx) {
      const sites = ctx.config.sites?.length ? ctx.config.sites : defaults;
      const state = /* @__PURE__ */ new Map();
      const check = async (s) => {
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
      setInterval(checkAll, Math.max(15, ctx.config.every ?? 60) * 1e3);
      const markers = () => sites.map((s) => {
        const st = state.get(s.name);
        return {
          lat: s.lat,
          lon: s.lon,
          label: s.name,
          color: st === void 0 ? "theme.accent" : st.up ? "theme.good" : "theme.bad",
          pulse: st !== void 0 && !st.up
        };
      });
      return () => {
        const down = sites.filter((s) => state.get(s.name)?.up === false).length;
        return import_sdk.ui.pill({
          popover: () => import_sdk.ui.column([
            import_sdk.ui.globe({ markers: markers(), size: 200, spin: "slow" }),
            ...sites.map((s) => {
              const st = state.get(s.name);
              return import_sdk.ui.row([
                import_sdk.ui.icon(st?.up === false ? "xmark.circle.fill" : "checkmark.circle.fill", st?.up === false ? "theme.bad" : "theme.good"),
                import_sdk.ui.text(s.name),
                import_sdk.ui.spacer(),
                import_sdk.ui.text(st ? st.up ? `${st.ms} ms` : "down" : "\u2026", { mono: true, size: 11 })
              ]);
            })
          ], 6)
        }, [
          import_sdk.ui.globe({ markers: markers(), size: 22, spin: "slow" }),
          ...down > 0 ? [import_sdk.ui.text(`${down} down`, { color: "theme.bad" })] : []
        ]);
      };
    }
  });
  return __toCommonJS(uptime_globe_exports);
})();
