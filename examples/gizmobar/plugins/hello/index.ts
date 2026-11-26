import { definePlugin, ui, fmt } from "@gizmobar/sdk";

// Shows CPU usage and turns the accent color when it's busy.
export default definePlugin({
  id: "hello",
  permissions: ["provider:cpu"],
  setup(ctx) {
    const cpu = ctx.use("cpu", { every: 2 });
    return () =>
      ui.row({
        icon: "cpu",
        label: fmt.percent(cpu.value.usage),
        color: cpu.value.usage > 0.8 ? ctx.theme.bad : undefined,
      });
  },
});
