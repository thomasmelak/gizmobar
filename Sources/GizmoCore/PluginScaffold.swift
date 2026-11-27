import Foundation

/// The files `gizmo new <id>` writes: a working plugin with types, ready
/// for `npm run build` (or the bar's own esbuild build on save).
public enum PluginScaffold {
    public static func files(id: String) -> [String: String] {
        let name = id.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        return [
            "plugin.json": """
            {
              "id": "\(id)",
              "name": "\(name)",
              "version": "0.1.0",
              "entry": "dist/index.js",
              "permissions": ["provider:cpu", "provider:memory"]
            }

            """,
            "index.ts": """
            import { definePlugin, ui, fmt } from "@gizmobar/sdk";

            // Add "\(id)" to [layout] in ~/.config/gizmobar/config.toml to show it.
            // Saving this file rebuilds and reloads the plugin.
            export default definePlugin({
              id: "\(id)",
              setup(ctx) {
                const cpu = ctx.use("cpu", { every: "2s" });
                const mem = ctx.use("memory", { every: "5s" });
                const history: number[] = [];

                return () => {
                  const usage = cpu.value?.usage ?? 0;
                  history.push(usage);
                  if (history.length > 30) history.shift();
                  return ui.row({
                    icon: "cpu",
                    label: fmt.percent(usage),
                    color: usage > 0.8 ? "theme.bad" : undefined,
                    popover: () =>
                      ui.column([
                        ui.text("\(name)", { size: 13 }),
                        ui.graph(history, "theme.accent"),
                        ui.text(`Memory ${fmt.bytes(mem.value?.used ?? 0)} of ${fmt.bytes(mem.value?.total ?? 0)}`),
                      ], 8),
                  });
                };
              },
            });

            """,
            "package.json": """
            {
              "name": "gizmobar-plugin-\(id)",
              "private": true,
              "version": "0.1.0",
              "scripts": {
                "build": "esbuild index.ts --bundle --format=iife --global-name=__plugin --platform=neutral --target=es2020 --external:@gizmobar/sdk --outfile=dist/index.js",
                "check": "tsc --noEmit"
              },
              "devDependencies": {
                "esbuild": "^0.24.0",
                "typescript": "^5.6.3"
              }
            }

            """,
            "tsconfig.json": """
            {
              "compilerOptions": {
                "target": "ES2020",
                "module": "ESNext",
                "moduleResolution": "bundler",
                "strict": true,
                "noEmit": true,
                "skipLibCheck": true,
                "lib": ["ES2020"]
              },
              "include": ["index.ts", "gizmobar.d.ts"]
            }

            """,
            "gizmobar.d.ts": "// Types for @gizmobar/sdk. Refresh with `gizmo types > gizmobar.d.ts`.\n" + SDKTypes.declaration
                + "\ndeclare function setTimeout(fn: (...a: unknown[]) => void, ms?: number, ...a: unknown[]): number;\n"
                + "declare function setInterval(fn: (...a: unknown[]) => void, ms?: number, ...a: unknown[]): number;\n"
                + "declare function clearTimeout(id: number): void;\ndeclare function clearInterval(id: number): void;\n"
                + "declare const console: { log(...a: unknown[]): void; warn(...a: unknown[]): void; error(...a: unknown[]): void };\n",
            ".gitignore": "node_modules/\ndist/\n",
        ]
    }

    /// Plugin ids: lowercase letters, digits and dashes.
    public static func isValid(id: String) -> Bool {
        !id.isEmpty && id.count <= 40 && id.first!.isLetter
            && id.allSatisfy { ($0.isLetter && $0.isLowercase) || $0.isNumber || $0 == "-" }
    }
}
