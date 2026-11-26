# @gizmobar/sdk

Types and helpers for Gizmobar plugins. A plugin returns a widget tree; the
host renders it natively, times every render (2 ms budget) and only grants
what `plugin.json` asks for.

```ts
import { definePlugin, ui } from "@gizmobar/sdk";

export default definePlugin({
  id: "wifi",
  permissions: ["provider:network"],
  setup(ctx) {
    const net = ctx.use("network");
    return () => ui.row({ icon: "wifi", label: net.value.ssid ?? "Offline" });
  },
});
```

The JavaScriptCore runtime lands in Phase 4; until then this package defines
the API surface. Provider payload types will be generated from the Swift
definitions.
