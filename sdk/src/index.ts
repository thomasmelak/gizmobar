// @gizmobar/sdk: the contract between a plugin and the Gizmobar host.
//
// A plugin describes what to show; the host draws it natively. Each plugin
// runs in its own JavaScriptCore context with a 2 ms render budget, and only
// reaches providers, the network or `exec` when plugin.json grants it.
// Provider types are generated from the Swift definitions (`gizmo types`).

import type { Providers } from "./providers.js";
export type { Providers } from "./providers.js";

export type Color = `#${string}` | `theme.${string}`;

export interface AppRef {
  bundleId: string | null;
  name: string;
}

export type ProviderName = keyof Providers;

export interface Signal<T> {
  /** Reading it inside render subscribes the render to changes. */
  readonly value: T;
}

export type Node =
  | { kind: "row"; children: Node[]; gap?: number }
  | { kind: "column"; children: Node[]; gap?: number }
  | { kind: "pill"; child: Node; focused?: boolean; onClick?: () => void; popover?: () => Node }
  | { kind: "text"; text: string; color?: Color; size?: number; marquee?: boolean; mono?: boolean }
  | { kind: "icon"; name: string; color?: Color }
  | { kind: "image"; src: string; size?: number; radius?: number }
  | { kind: "appIcon"; bundleId: string; style?: "auto" | "system" | "pack" }
  | { kind: "graph"; values: number[]; color?: Color; width?: number }
  | { kind: "slider"; value: number; onChange: (v: number) => void }
  | { kind: "toggle"; value: boolean; onChange: (v: boolean) => void }
  | { kind: "button"; label: string; icon?: string; onClick: () => void }
  | { kind: "scene"; scene: SceneOptions; onClick?: () => void; popover?: () => Node }
  | { kind: "spacer" };

export interface RowOptions {
  icon?: string;
  label?: string | number;
  color?: Color;
  labelColor?: Color;
  focused?: boolean;
  onClick?: () => void;
  popover?: () => Node;
}

export interface SceneOptions {
  /** A .glb/.gltf/.usdz in the plugin folder, or a built-in scene. */
  model?: string;
  builtin?: "globe";
  /** A clip name, or a clip with looping and cross-fade seconds. */
  animation?: string | { clip: string; loop?: boolean; blend?: number };
  look?: "toon" | "pbr" | "unlit";
  /** Points; clamped to the bar height on the bar. */
  size?: number;
  /** Degrees per second, or "slow" | "medium" | "fast". */
  spin?: number | "slow" | "medium" | "fast";
  camera?: { yaw?: number };
  /** Per-node overrides by glTF node name. */
  parts?: Record<string, { visible?: boolean; color?: Color; rotation?: [number, number, number] }>;
  caption?: string;
  onClick?: () => void;
  /** A popover of your own, or a bigger copy of the model you can orbit. */
  popover?: (() => Node) | { size?: number; orbit?: boolean };
}

export interface GlobeOptions {
  markers?: { lat: number; lon: number; color?: Color; pulse?: boolean; label?: string }[];
  spin?: number | "slow" | "medium" | "fast";
  size?: number;
  caption?: string;
  onClick?: () => void;
  popover?: (() => Node) | { size?: number; orbit?: boolean };
}

export interface SceneControl {
  play(clip: string, opts?: { once?: boolean; blend?: number }): void;
  set(part: string, o: { rotation?: [number, number, number]; color?: Color; visible?: boolean }): void;
  on(event: "click", cb: (part: string) => void): () => void;
  clips(): string[];
}

export interface Context<Config = Record<string, unknown>> {
  /** `[plugins.<id>]` from config.toml. */
  config: Config;
  theme: Record<"accent" | "icon" | "label" | "good" | "warn" | "bad" | "netUp" | "netDown", string>;
  /** Needs "provider:<name>". `every` limits updates, e.g. "2s". */
  use<P extends ProviderName>(provider: P, opts?: { every?: number | string }): Signal<Providers[P]>;
  /** Any bus topic, e.g. one pushed with `gizmo trigger`. */
  on(topic: string, cb: (payload: unknown) => void): () => void;
  /** Publishes "plugin.<id>.<topic>" on the bus. */
  emit(topic: string, payload?: unknown): void;
  /** Needs "requests": the same requests built-in widgets send ("theme.set:nord"...). */
  request(name: string): void;
  /** Draw again now (after changing your own state). */
  rerender(): void;
  storage: { get<T>(key: string): T | undefined; set<T>(key: string, value: T): void };
  /** Needs "net:<host>". */
  fetch(url: string, init?: { method?: string; headers?: Record<string, string>; body?: string }): Promise<{ status: number; text(): Promise<string>; json<T>(): Promise<T> }>;
  /** Needs "exec". */
  exec(cmd: string, args?: string[]): Promise<{ code: number; stdout: string }>;
  open(url: string): void;
  scene: SceneControl;
}

export interface PluginDefinition<Config> {
  id: string;
  /** Called once; returns the render function the host calls when inputs change. */
  setup(ctx: Context<Config>): () => Node;
}


// ------------------------------------------------------------- runtime
// The host provides these at run time (the bundle marks @gizmobar/sdk as
// external); these implementations match it, for tests and type checks.

export const ui = {
  row: (o: RowOptions | Node[]): Node =>
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
              ...(o.icon ? [{ kind: "icon", name: o.icon, color: o.color } as Node] : []),
              ...(o.label !== undefined ? [{ kind: "text", text: String(o.label), color: o.labelColor } as Node] : []),
            ],
          },
        },
  pill: (o: { onClick?: () => void; popover?: () => Node; focused?: boolean; gap?: number }, children: Node[] | Node): Node => ({
    kind: "pill",
    onClick: o.onClick,
    popover: o.popover,
    focused: o.focused,
    child: Array.isArray(children) ? { kind: "row", gap: o.gap ?? 6, children } : children,
  }),
  stack: (o: { axis?: "h" | "v"; gap?: number }, children: Node[]): Node =>
    o.axis === "h" ? { kind: "row", gap: o.gap, children } : { kind: "column", gap: o.gap, children },
  column: (children: Node[], gap?: number): Node => ({ kind: "column", children, gap }),
  text: (text: string | number, o: { color?: Color; size?: number; marquee?: boolean; mono?: boolean } = {}): Node => ({ kind: "text", text: String(text), ...o }),
  icon: (name: string, color?: Color): Node => ({ kind: "icon", name, color }),
  image: (src: string, size?: number, radius?: number): Node => ({ kind: "image", src, size, radius }),
  appIcon: (bundleId: string, style: "auto" | "system" | "pack" = "auto"): Node => ({ kind: "appIcon", bundleId, style }),
  graph: (values: number[], color?: Color): Node => ({ kind: "graph", values, color }),
  sparkline: (values: number[], color?: Color): Node => ({ kind: "graph", values, color }),
  slider: (value: number, onChange: (v: number) => void): Node => ({ kind: "slider", value, onChange }),
  toggle: (value: boolean, onChange: (v: boolean) => void): Node => ({ kind: "toggle", value, onChange }),
  button: (label: string, onClick: () => void, icon?: string): Node => ({ kind: "button", label, onClick, icon }),
  scene: (scene: SceneOptions): Node => ({ kind: "scene", scene, onClick: scene.onClick, popover: typeof scene.popover === "function" ? scene.popover : undefined }),
  globe: (o: GlobeOptions): Node => ({ kind: "scene", scene: { builtin: "globe", ...o }, onClick: o.onClick, popover: typeof o.popover === "function" ? o.popover : undefined }),
  spacer: (): Node => ({ kind: "spacer" }),
};

export const fmt = {
  percent: (v: number) => `${Math.round(v * 100)}%`,
  bytesPerSecond(bps: number): string {
    const units = ["bps", "Kbps", "Mbps", "Gbps"];
    let v = bps * 8;
    let i = 0;
    while (v >= 1000 && i < units.length - 1) {
      v /= 1000;
      i++;
    }
    return `${v.toFixed(v < 10 && i > 0 ? 1 : 0)} ${units[i]}`;
  },
  bits: (bps: number): string => fmt.bytesPerSecond(bps),
  bytes(n: number): string {
    const units = ["B", "KB", "MB", "GB", "TB"];
    let v = n;
    let i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return `${v.toFixed(v < 10 && i > 0 ? 1 : 0)} ${units[i]}`;
  },
  duration(seconds: number): string {
    const m = Math.floor(seconds / 60);
    const s = Math.floor(seconds % 60);
    return `${m}:${s.toString().padStart(2, "0")}`;
  },
};

export function definePlugin<Config = Record<string, unknown>>(def: PluginDefinition<Config>): PluginDefinition<Config> {
  return def;
}
