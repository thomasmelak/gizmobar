/// TypeScript declarations for `@gizmobar/sdk`, written into new plugins
/// by `gizmo new` and printed by `gizmo types`. Provider types come from
/// `PluginProviders`; the rest mirrors sdk/src/index.ts.
public enum SDKTypes {
    public static var declaration: String {
        "declare module \"@gizmobar/sdk\" {\n"
            + (body + PluginProviders.typescript)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.isEmpty ? "" : "  " + $0.replacingOccurrences(of: "export declare ", with: "export ") }
                .joined(separator: "\n")
            + "\n}\n" + globals
    }

    /// What the plugin runtime puts on globalThis (no DOM, no Node).
    static let globals = """

    declare function setTimeout(fn: (...args: unknown[]) => void, ms?: number, ...args: unknown[]): number;
    declare function setInterval(fn: (...args: unknown[]) => void, ms?: number, ...args: unknown[]): number;
    declare function clearTimeout(id?: number): void;
    declare function clearInterval(id?: number): void;
    declare const console: { log(...args: unknown[]): void; warn(...args: unknown[]): void; error(...args: unknown[]): void };

    """

    static let body = #"""
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

export declare const ui: {
  row(o: RowOptions | Node[]): Node;
  pill(o: { onClick?: () => void; popover?: () => Node; focused?: boolean; gap?: number }, children: Node[] | Node): Node;
  stack(o: { axis?: "h" | "v"; gap?: number }, children: Node[]): Node;
  column(children: Node[], gap?: number): Node;
  text(text: string | number, o?: { color?: Color; size?: number; marquee?: boolean; mono?: boolean }): Node;
  icon(name: string, color?: Color): Node;
  image(src: string, size?: number, radius?: number): Node;
  appIcon(bundleId: string, style?: "auto" | "system" | "pack"): Node;
  graph(values: number[], color?: Color): Node;
  sparkline(values: number[], color?: Color): Node;
  slider(value: number, onChange: (v: number) => void): Node;
  toggle(value: boolean, onChange: (v: boolean) => void): Node;
  button(label: string, onClick: () => void, icon?: string): Node;
  scene(scene: SceneOptions): Node;
  globe(o: GlobeOptions): Node;
  spacer(): Node;
};

export declare const fmt: {
  percent(v: number): string;
  bytesPerSecond(bps: number): string;
  bits(bps: number): string;
  bytes(n: number): string;
  duration(seconds: number): string;
};

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

export declare function definePlugin<Config = Record<string, unknown>>(def: PluginDefinition<Config>): PluginDefinition<Config>;

"""#
}
