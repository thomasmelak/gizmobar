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
  var theme_picker_exports = {};
  __export(theme_picker_exports, {
    default: () => theme_picker_default
  });
  var import_sdk = __require("@gizmobar/sdk");
  var theme_picker_default = (0, import_sdk.definePlugin)({
    id: "theme-picker",
    setup(ctx) {
      const themes = ctx.config.themes ?? ["gizmo", "nord", "dracula", "catppuccin-mocha", "tokyo-night"];
      let current = ctx.storage.get("current") ?? "gizmo";
      const title = (id) => id.split("-").map((w) => w[0].toUpperCase() + w.slice(1)).join(" ");
      return () => import_sdk.ui.pill({ popover: () => import_sdk.ui.column([
        import_sdk.ui.text("Theme", { size: 13 }),
        ...themes.map(
          (id) => import_sdk.ui.button(title(id), () => {
            current = id;
            ctx.storage.set("current", id);
            ctx.request(`theme.set:${id}`);
          }, id === current ? "checkmark.circle.fill" : "circle")
        ),
        import_sdk.ui.button("Custom / system icons", () => ctx.request("icons.style.toggle"), "square.grid.2x2")
      ], 4) }, [import_sdk.ui.icon("paintpalette")]);
    }
  });
  return __toCommonJS(theme_picker_exports);
})();
