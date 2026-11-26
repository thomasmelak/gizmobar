// @gizmobar/sdk: the contract between a plugin and the Gizmobar host.
//
// A plugin describes what to show; the host draws it natively. Plugins run in
// their own JavaScriptCore context with a 2 ms render budget, and only reach
// providers, the network or `exec` when plugin.json grants it.
//
// The JavaScriptCore runtime ships in Phase 4. Until then this file fixes
// the API so plugins and the host can be written against it. Provider
// payload types will be generated from the Swift definitions.

export type Color = `#${string}`;

// ---------------------------------------------------------------- providers

export interface Providers {
  workspaces: {
    focused: string | null;
    list: { id: string; focused: boolean; apps: AppRef[] }[];
  };
  apps: { front: AppRef | null };
  clock: { now: number };
  network: { ssid: string | null; up: boolean; downBps: number; upBps: number };
  cpu: { usage: number; temperature: number | null };
  memory: { used: number; total: number; pressure: "normal" | "warn" | "critical" };
  power: { percent: number; charging: boolean; lowPower: boolean; timeRemaining: number | null };
  media: {
    playing: boolean;
    title: string | null;
    artist: string | null;
    album: string | null;
    artwork: string | null;
    position: number;
    duration: number;
    source: string | null;
  };
  audio: { volume: number; muted: boolean; output: string };
  displays: { id: number; name: string; builtIn: boolean; brightness: number | null }[];
}

export type ProviderName = keyof Providers;

export interface AppRef {
  bundleId: string | null;
  name: string;
}

export interface Signal<T> {
  readonly value: T;
}

// ------------------------------------------------------------------- widgets

export type Node =
  | { kind: "row"; children: Node[]; gap?: number }
  | { kind: "column"; children: Node[]; gap?: number }
  | { kind: "pill"; child: Node; focused?: boolean; onClick?: () => void; popover?: () => Node }
  | { kind: "text"; text: string; color?: Color; marquee?: boolean; mono?: boolean }
  | { kind: "icon"; name: string; set?: "sf" | "phosphor"; color?: Color }
  | { kind: "image"; src: string; size?: number; radius?: number }
  | { kind: "appIcon"; bundleId: string; style?: "auto" | "system" | "pack" }
  | { kind: "graph"; values: number[]; color?: Color; width?: number }
  | { kind: "slider"; value: number; onChange: (v: number) => void }
  | { kind: "toggle"; value: boolean; onChange: (v: boolean) => void }
  | { kind: "scene"; scene: SceneOptions }
  | { kind: "spacer" };

// Any node with onClick (pill, row, scene, slider, toggle) shows the
// pointing-hand cursor on hover; the host applies it, plugins don't need to.

export interface RowOptions {
  icon?: string;
  label?: string;
  color?: Color;
  onClick?: () => void;
  popover?: () => Node;
}

export interface SceneOptions {
  /** Path to a .glb/.gltf/.usdz in the plugin's models/ folder, or a built-in scene. */
  model?: string;
  builtin?: "globe";
  animation?: string;
  look?: "toon" | "pbr" | "unlit";
  size?: number;
  spin?: number;
  onClick?: () => void;
  popover?: () => Node;
  [key: string]: unknown;
}

export interface GlobeOptions {
  markers?: { lat: number; lon: number; color?: Color; pulse?: boolean; label?: string }[];
  arcs?: { from: [number, number]; to: [number, number]; color?: Color }[];
  spin?: number;
}

export const ui = {
  row: (o: RowOptions | Node[]): Node =>
    Array.isArray(o)
      ? { kind: "row", children: o }
      : {
          kind: "pill",
          onClick: o.onClick,
          popover: o.popover,
          child: {
            kind: "row",
            gap: 6,
            children: [
              ...(o.icon ? [{ kind: "icon", name: o.icon, color: o.color } as Node] : []),
              ...(o.label !== undefined ? [{ kind: "text", text: o.label } as Node] : []),
            ],
          },
        },
  column: (children: Node[], gap?: number): Node => ({ kind: "column", children, gap }),
  text: (text: string, o: Omit<Extract<Node, { kind: "text" }>, "kind" | "text"> = {}): Node => ({ kind: "text", text, ...o }),
  icon: (name: string, color?: Color): Node => ({ kind: "icon", name, color }),
  image: (src: string, size?: number, radius?: number): Node => ({ kind: "image", src, size, radius }),
  appIcon: (bundleId: string, style: "auto" | "system" | "pack" = "auto"): Node => ({ kind: "appIcon", bundleId, style }),
  graph: (values: number[], color?: Color): Node => ({ kind: "graph", values, color }),
  slider: (value: number, onChange: (v: number) => void): Node => ({ kind: "slider", value, onChange }),
  toggle: (value: boolean, onChange: (v: boolean) => void): Node => ({ kind: "toggle", value, onChange }),
  scene: (scene: SceneOptions): Node => ({ kind: "scene", scene }),
  globe: (o: GlobeOptions): Node => ({ kind: "scene", scene: { builtin: "globe", ...o } }),
  spacer: (): Node => ({ kind: "spacer" }),
};

// ------------------------------------------------------------------- context

export interface SceneControl {
  play(clip: string, opts?: { once?: boolean; blend?: number }): void;
  set(part: string, o: { rotation?: [number, number, number]; color?: Color; visible?: boolean }): void;
  on(event: "click", cb: (part: string) => void): void;
  clips(): string[];
}

export interface Context<Config = Record<string, unknown>> {
  config: Config;
  theme: Record<string, Color>;
  use<P extends ProviderName>(provider: P, opts?: { every?: number }): Signal<Providers[P]>;
  on(topic: string, cb: (payload: unknown) => void): () => void;
  emit(topic: string, payload?: unknown): void;
  storage: { get<T>(key: string): T | undefined; set<T>(key: string, value: T): void };
  fetch(url: string, init?: { method?: string; headers?: Record<string, string>; body?: string }): Promise<{ status: number; text(): Promise<string>; json<T>(): Promise<T> }>;
  exec(cmd: string, args?: string[]): Promise<{ code: number; stdout: string }>;
  open(url: string): void;
  scene: SceneControl;
}

export interface PluginDefinition<Config> {
  id: string;
  permissions?: string[];
  /** Called once; returns a render function the host calls when inputs change. */
  setup(ctx: Context<Config>): () => Node;
}

export function definePlugin<Config = Record<string, unknown>>(def: PluginDefinition<Config>): PluginDefinition<Config> {
  return def;
}

// ----------------------------------------------------------------- formatting

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
  duration(seconds: number): string {
    const m = Math.floor(seconds / 60);
    const s = Math.floor(seconds % 60);
    return `${m}:${s.toString().padStart(2, "0")}`;
  },
};
