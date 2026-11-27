import { definePlugin, ui, fmt } from "@gizmobar/sdk";

// The built-in network widget, rewritten as a plugin: upload and download
// stacked in one pill, with a popover graphing the last minute.
export default definePlugin({
  id: "net-speed",
  setup(ctx) {
    const net = ctx.use("network", { every: "2s" });
    const down: number[] = [];
    const up: number[] = [];
    let peak = 1;

    return () => {
      const n = net.value;
      down.push(n?.downBps ?? 0);
      up.push(n?.upBps ?? 0);
      if (down.length > 30) { down.shift(); up.shift(); }
      peak = Math.max(1, ...down, ...up);
      const scaled = (xs: number[]) => xs.map((x) => x / peak);

      return ui.pill({ popover: () => ui.column([
        ui.text(n?.up ? `${n.kind === "wifi" ? "Wi-Fi" : "Ethernet"} · ${n.interface ?? ""}` : "Offline", { size: 13 }),
        ui.row([ui.icon("arrow.down", "theme.netDown"), ui.graph(scaled(down), "theme.netDown"), ui.text(fmt.bits(n?.downBps ?? 0), { mono: true })]),
        ui.row([ui.icon("arrow.up", "theme.netUp"), ui.graph(scaled(up), "theme.netUp"), ui.text(fmt.bits(n?.upBps ?? 0), { mono: true })]),
        ui.text(n?.ip ? `IP ${n.ip}` : "", { size: 11 }),
      ], 8) }, [
        ui.stack({ axis: "v", gap: 0 }, [
          ui.text(`↑ ${fmt.bits(n?.upBps ?? 0)}`, { size: 10, color: "theme.netUp", mono: true }),
          ui.text(`↓ ${fmt.bits(n?.downBps ?? 0)}`, { size: 10, color: "theme.netDown", mono: true }),
        ]),
      ]);
    };
  },
});
