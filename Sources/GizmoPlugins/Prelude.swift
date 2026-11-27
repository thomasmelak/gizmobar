/// JavaScript evaluated in every plugin context before the plugin's bundle:
/// the SDK runtime (`ui`, `fmt`, `definePlugin`, resolved through
/// `require("@gizmobar/sdk")`), `console`, timers, and the bridge the host
/// drives (`__setup`, `__render`, `__invoke`...). Keep `ui`/`fmt` in step
/// with sdk/src/index.ts.
enum Prelude {
    static let source = #"""
(function () {
  "use strict";
  const host = globalThis.__host;
  const show = (v) => (typeof v === "string" ? v : (() => { try { return JSON.stringify(v); } catch (e) { return String(v); } })());
  globalThis.console = {
    log: (...a) => host.log("info", a.map(show).join(" ")),
    info: (...a) => host.log("info", a.map(show).join(" ")),
    warn: (...a) => host.log("warn", a.map(show).join(" ")),
    error: (...a) => host.log("error", a.map(show).join(" ")),
  };

  // ---------------------------------------------------------------- sdk
  const row = (o) =>
    Array.isArray(o)
      ? { kind: "row", children: o }
      : {
          kind: "pill",
          onClick: o.onClick,
          popover: o.popover,
          focused: o.focused,
          child: {
            kind: "row",
            gap: 6,
            children: [
              ...(o.icon ? [{ kind: "icon", name: o.icon, color: o.color }] : []),
              ...(o.label !== undefined ? [{ kind: "text", text: String(o.label), color: o.labelColor }] : []),
            ],
          },
        };
  const ui = {
    row,
    pill: (o, children) => ({ kind: "pill", onClick: o.onClick, popover: o.popover, focused: o.focused,
      child: Array.isArray(children) ? { kind: "row", gap: o.gap ?? 6, children } : children }),
    stack: (o, children) => ({ kind: o.axis === "h" ? "row" : "column", gap: o.gap, children }),
    column: (children, gap) => ({ kind: "column", children, gap }),
    text: (text, o = {}) => ({ kind: "text", text: String(text), ...o }),
    icon: (name, color) => ({ kind: "icon", name, color }),
    image: (src, size, radius) => ({ kind: "image", src, size, radius }),
    appIcon: (bundleId, style = "auto") => ({ kind: "appIcon", bundleId, style }),
    graph: (values, color) => ({ kind: "graph", values, color }),
    sparkline: (values, color) => ({ kind: "graph", values, color }),
    slider: (value, onChange) => ({ kind: "slider", value, onChange }),
    toggle: (value, onChange) => ({ kind: "toggle", value, onChange }),
    button: (label, onClick, icon) => ({ kind: "button", label, onClick, icon }),
    scene: (scene) => ({ kind: "scene", scene, onClick: scene.onClick, popover: scene.popover }),
    globe: (o) => ({ kind: "scene", scene: { builtin: "globe", ...o }, onClick: o.onClick, popover: o.popover }),
    spacer: () => ({ kind: "spacer" }),
  };
  const fmt = {
    percent: (v) => `${Math.round(v * 100)}%`,
    bytesPerSecond(bps) {
      const units = ["bps", "Kbps", "Mbps", "Gbps"];
      let v = bps * 8, i = 0;
      while (v >= 1000 && i < units.length - 1) { v /= 1000; i++; }
      return `${v.toFixed(v < 10 && i > 0 ? 1 : 0)} ${units[i]}`;
    },
    bits(bps) { return fmt.bytesPerSecond(bps); },
    bytes(n) {
      const units = ["B", "KB", "MB", "GB", "TB"];
      let v = n, i = 0;
      while (v >= 1024 && i < units.length - 1) { v /= 1024; i++; }
      return `${v.toFixed(v < 10 && i > 0 ? 1 : 0)} ${units[i]}`;
    },
    duration(seconds) {
      const m = Math.floor(seconds / 60), s = Math.floor(seconds % 60);
      return `${m}:${s.toString().padStart(2, "0")}`;
    },
  };
  const sdk = { ui, fmt, definePlugin: (d) => d };
  globalThis.require = (name) => {
    if (name === "@gizmobar/sdk") return sdk;
    throw new Error(`can't require "${name}": bundle it into the plugin`);
  };

  // ------------------------------------------------------------- timers
  const timers = new Map();
  let timerId = 1;
  const addTimer = (fn, ms, repeat, args) => {
    const id = timerId++;
    timers.set(id, { fn, args, repeat });
    host.setTimer(id, Math.max(0, Number(ms) || 0), repeat);
    return id;
  };
  globalThis.setTimeout = (fn, ms, ...args) => addTimer(fn, ms, false, args);
  globalThis.setInterval = (fn, ms, ...args) => addTimer(fn, Math.max(16, Number(ms) || 0), true, args);
  globalThis.clearTimeout = globalThis.clearInterval = (id) => { if (timers.delete(id)) host.clearTimer(id); };
  globalThis.__fire = (id) => {
    const t = timers.get(id);
    if (!t) return;
    if (!t.repeat) timers.delete(id);
    t.fn(...t.args);
  };

  // ------------------------------------------------------- async replies
  const pending = new Map();
  let pendingId = 1;
  const request = (start) => new Promise((resolve, reject) => {
    const id = pendingId++;
    pending.set(id, { resolve, reject });
    start(id);
  });
  globalThis.__resolve = (id, ok, json) => {
    const p = pending.get(id);
    if (!p) return;
    pending.delete(id);
    const v = JSON.parse(json);
    ok ? p.resolve(v) : p.reject(new Error(String(v)));
  };

  // -------------------------------------------------------------- state
  const providers = {};
  const subs = new Map();
  const tables = { bar: new Map(), popover: new Map() };
  let render = null;

  const serialize = (node, table, base) => {
    tables[table] = new Map();
    let n = 0;
    return JSON.stringify(node, (k, v) => {
      if (typeof v !== "function") return v;
      const id = base + ++n;
      tables[table].set(id, v);
      return { $fn: id };
    });
  };
  const lookup = (id) => (id >= 1e6 ? tables.popover : tables.bar).get(id);

  const parseEvery = (e) => {
    if (typeof e === "number") return e;
    const m = /^(\d+(?:\.\d+)?)\s*(ms|s|m)?$/.exec(String(e ?? ""));
    if (!m) return 0;
    const n = Number(m[1]);
    return m[2] === "ms" ? n / 1000 : m[2] === "m" ? n * 60 : n;
  };

  globalThis.__setup = (configJson, themeJson) => {
    const mod = globalThis.__plugin;
    const def = mod && (mod.default ?? mod);
    if (!def || typeof def.setup !== "function") throw new Error("the plugin must `export default definePlugin({ setup })`");
    const theme = JSON.parse(themeJson);
    const ctx = {
      config: JSON.parse(configJson),
      theme,
      use(name, opts) {
        if (!host.use(name, parseEvery(opts && opts.every))) throw new Error(`add "provider:${name}" to permissions in plugin.json`);
        return { get value() { return providers[name]; } };
      },
      on(topic, cb) {
        const list = subs.get(topic) ?? [];
        list.push(cb);
        subs.set(topic, list);
        host.subscribe(topic);
        return () => { const l = subs.get(topic) ?? []; const i = l.indexOf(cb); if (i >= 0) l.splice(i, 1); };
      },
      emit: (topic, payload) => host.emit(String(topic), JSON.stringify(payload ?? null)),
      request: (name) => host.request(String(name)),
      rerender: () => host.rerender(),
      storage: {
        get(key) { const s = host.storageGet(String(key)); return s == null ? undefined : JSON.parse(s); },
        set(key, value) { host.storageSet(String(key), JSON.stringify(value ?? null)); },
      },
      fetch: (url, init) => request((id) => host.fetch(String(url), JSON.stringify(init ?? {}), id)).then((r) => ({
        status: r.status,
        text: async () => r.body,
        json: async () => JSON.parse(r.body),
      })),
      exec: (cmd, args) => request((id) => host.exec(String(cmd), JSON.stringify(args ?? []), id)),
      open: (url) => host.open(String(url)),
      scene: {
        play: (clip, o) => host.emit("scene.play", JSON.stringify({ clip, ...(o ?? {}) })),
        set: (part, o) => host.emit("scene.set", JSON.stringify({ part, ...o })),
        on: (event, cb) => ctx.on("scene." + event, cb),
        clips: () => JSON.parse(host.sceneClips() ?? "[]"),
      },
    };
    render = def.setup(ctx);
    if (typeof render !== "function") throw new Error("setup(ctx) must return a render function");
  };
  globalThis.__render = () => serialize(render(), "bar", 0);
  globalThis.__renderPopover = (id) => {
    const fn = lookup(id);
    return fn ? serialize(fn(), "popover", 1e6) : "null";
  };
  globalThis.__invoke = (id, json) => { const fn = lookup(id); if (fn) fn(JSON.parse(json)); };
  globalThis.__setProvider = (name, json) => { providers[name] = JSON.parse(json); };
  globalThis.__dispatch = (topic, json) => {
    const payload = JSON.parse(json);
    for (const cb of subs.get(topic) ?? []) cb(payload);
  };
})();
"""#
}
