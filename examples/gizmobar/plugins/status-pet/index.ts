import { definePlugin, ui, fmt } from "@gizmobar/sdk";

// A small robot that acts out what the Mac is doing: it sleeps on a low
// battery, dances while music plays, runs when the CPU is busy and idles
// otherwise. Plugged in, it sits down with a cable in its back while it
// charges, hops when full, and keeps the cable on while it dances.
// Click it to wave; open the popover to orbit around it.
// The model is models/gizmo-bot.glb (rebuild it with models/make_bot.py).
//
//   [plugins.status-pet]
//   charging = false   # turn the charging looks off

interface Config { charging?: boolean }

export default definePlugin<Config>({
  id: "status-pet",
  setup(ctx) {
    const cpu = ctx.use("cpu", { every: "2s" });
    const power = ctx.use("power", { every: "10s" });
    const media = ctx.use("media");
    const chargeLooks = ctx.config.charging !== false;

    const mood = (): string => {
      const p = power.value;
      const plugged = chargeLooks && !!p && (p.charging || p.external);
      if (p && p.percent < 15 && !p.charging && !p.external) return "sleep";
      if (media.value?.playing) return plugged ? "dance-charging" : "dance";
      if ((cpu.value?.usage ?? 0) > 0.8) return "run";
      if (plugged) return p!.percent >= 100 && !p!.charging ? "happy" : "charge";
      return "idle";
    };

    const caption = (m: string): string =>
      ({
        sleep: `Battery ${power.value?.percent ?? 0}%. Plug me in.`,
        dance: `Dancing to ${media.value?.title ?? "something"}`,
        "dance-charging": `Dancing to ${media.value?.title ?? "something"}, charging at ${power.value?.percent ?? 0}%`,
        run: `CPU at ${fmt.percent(cpu.value?.usage ?? 0)}`,
        charge: `Charging, ${power.value?.percent ?? 0}%`,
        happy: "Fully charged",
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
