import { definePlugin, ui, fmt } from "@gizmobar/sdk";

// A small robot that acts out what the Mac is doing: it sleeps on a low
// battery, dances while music plays, runs when the CPU is busy and idles
// otherwise. Click it to wave; open the popover to orbit around it.
// The model is models/gizmo-bot.glb (rebuild it with models/make_bot.py).
export default definePlugin({
  id: "status-pet",
  setup(ctx) {
    const cpu = ctx.use("cpu", { every: "2s" });
    const power = ctx.use("power", { every: "10s" });
    const media = ctx.use("media");

    const mood = (): string => {
      const p = power.value;
      if (p && p.percent < 15 && !p.charging && !p.external) return "sleep";
      if (media.value?.playing) return "dance";
      if ((cpu.value?.usage ?? 0) > 0.8) return "run";
      return "idle";
    };

    const caption = (m: string): string =>
      ({
        sleep: `Battery ${power.value?.percent ?? 0}%. Plug me in.`,
        dance: `Dancing to ${media.value?.title ?? "something"}`,
        run: `CPU at ${fmt.percent(cpu.value?.usage ?? 0)}`,
        idle: "All quiet",
      })[m] ?? "";

    return () => {
      const m = mood();
      return ui.scene({
        model: "models/gizmo-bot.glb",
        size: 28,
        look: "toon",
        animation: { clip: m, loop: true, blend: 0.3 },
        camera: { yaw: 20 },
        caption: caption(m),
        onClick: () => ctx.scene.play("wave", { once: true }),
        popover: { size: 240, orbit: true },
      });
    };
  },
});
