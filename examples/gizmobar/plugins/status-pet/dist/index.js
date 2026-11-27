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
  var status_pet_exports = {};
  __export(status_pet_exports, {
    default: () => status_pet_default
  });
  var import_sdk = __require("@gizmobar/sdk");
  var status_pet_default = (0, import_sdk.definePlugin)({
    id: "status-pet",
    setup(ctx) {
      const cpu = ctx.use("cpu", { every: "2s" });
      const power = ctx.use("power");
      const media = ctx.use("media");
      const chargeLooks = ctx.config.charging !== false;
      const mood = () => {
        const p = power.value;
        const plugged = chargeLooks && !!p && (p.charging || p.external);
        if (p && p.percent < 15 && !p.charging && !p.external) return "sleep";
        if (media.value?.playing) return plugged ? "dance-charging" : "dance";
        if ((cpu.value?.usage ?? 0) > 0.8) return "run";
        if (plugged) return p.percent >= 100 && !p.charging ? "happy" : "charge";
        return "idle";
      };
      const caption = (m) => ({
        sleep: `Battery ${power.value?.percent ?? 0}%. Plug me in.`,
        dance: `Dancing to ${media.value?.title ?? "something"}`,
        "dance-charging": `Dancing to ${media.value?.title ?? "something"}, charging at ${power.value?.percent ?? 0}%`,
        run: `CPU at ${import_sdk.fmt.percent(cpu.value?.usage ?? 0)}`,
        charge: `Charging, ${power.value?.percent ?? 0}%`,
        happy: "Fully charged",
        idle: "All quiet"
      })[m] ?? "";
      return () => {
        const m = mood();
        return import_sdk.ui.scene({
          model: "models/gizmo-bot.glb",
          size: 28,
          look: "toon",
          animation: { clip: m, loop: true, blend: 0.3 },
          camera: { yaw: 20 },
          caption: caption(m),
          onClick: () => ctx.scene.play("wave", { once: true }),
          popover: { size: 240, orbit: true }
        });
      };
    }
  });
  return __toCommonJS(status_pet_exports);
})();
