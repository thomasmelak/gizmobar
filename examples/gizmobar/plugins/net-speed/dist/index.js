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
  var net_speed_exports = {};
  __export(net_speed_exports, {
    default: () => net_speed_default
  });
  var import_sdk = __require("@gizmobar/sdk");
  var net_speed_default = (0, import_sdk.definePlugin)({
    id: "net-speed",
    setup(ctx) {
      const net = ctx.use("network", { every: "2s" });
      const down = [];
      const up = [];
      let peak = 1;
      return () => {
        const n = net.value;
        down.push(n?.downBps ?? 0);
        up.push(n?.upBps ?? 0);
        if (down.length > 30) {
          down.shift();
          up.shift();
        }
        peak = Math.max(1, ...down, ...up);
        const scaled = (xs) => xs.map((x) => x / peak);
        return import_sdk.ui.pill({ popover: () => import_sdk.ui.column([
          import_sdk.ui.text(n?.up ? `${n.kind === "wifi" ? "Wi-Fi" : "Ethernet"} \xB7 ${n.interface ?? ""}` : "Offline", { size: 13 }),
          import_sdk.ui.row([import_sdk.ui.icon("arrow.down", "theme.netDown"), import_sdk.ui.graph(scaled(down), "theme.netDown"), import_sdk.ui.text(import_sdk.fmt.bits(n?.downBps ?? 0), { mono: true })]),
          import_sdk.ui.row([import_sdk.ui.icon("arrow.up", "theme.netUp"), import_sdk.ui.graph(scaled(up), "theme.netUp"), import_sdk.ui.text(import_sdk.fmt.bits(n?.upBps ?? 0), { mono: true })]),
          import_sdk.ui.text(n?.ip ? `IP ${n.ip}` : "", { size: 11 })
        ], 8) }, [
          import_sdk.ui.stack({ axis: "v", gap: 0 }, [
            import_sdk.ui.text(`\u2191 ${import_sdk.fmt.bits(n?.upBps ?? 0)}`, { size: 10, color: "theme.netUp", mono: true }),
            import_sdk.ui.text(`\u2193 ${import_sdk.fmt.bits(n?.downBps ?? 0)}`, { size: 10, color: "theme.netDown", mono: true })
          ])
        ]);
      };
    }
  });
  return __toCommonJS(net_speed_exports);
})();
