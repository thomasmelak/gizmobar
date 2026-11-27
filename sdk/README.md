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
    return () => ui.row({ icon: "wifi", label: net.value?.ip ?? "Offline" });
  },
});
```

`src/providers.ts` is generated from the Swift provider definitions
(`gizmo types --sdk > src/providers.ts`); a test fails when it drifts.
`gizmobar.d.ts` is the same API as one ambient module, which `gizmo new`
copies into each plugin. See ../docs/plugins.md.
