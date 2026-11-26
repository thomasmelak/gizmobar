import SwiftUI
import GizmoCore

/// `Fri 27 Nov 00:11:31 | 16:11 EST` by default, like the SketchyBar clock.
/// Click for the month calendar and every world clock.
struct ClockWidget: View {
    @Environment(BarStore.self) private var store
    @State private var showing = false

    var body: some View {
        let t = store.theme
        let clock = store.config.clock
        Pill(focused: showing) {
            Text(ClockText.bar(store.snapshot.now, clock))
                .font(.custom(t.font, size: t.fontSize + 1).monospacedDigit())
                .foregroundStyle(Color(hex: t.label))
                .lineLimit(1)
                .fixedSize()
        }
        .barAction { showing.toggle() }
        .popover(isPresented: $showing, arrowEdge: store.config.bar.position == .bottom ? .top : .bottom) {
            ClockPopover().environment(store)
        }
    }
}

struct ClockPopover: View {
    @Environment(BarStore.self) private var store

    var body: some View {
        let t = store.theme
        let now = store.snapshot.now
        let clock = store.config.clock
        VStack(alignment: .leading, spacing: 12) {
            if clock.calendar {
                CalendarGrid(grid: MonthGrid(for: now))
            }
            if !clock.world.isEmpty {
                if clock.calendar { Divider().overlay(Color(hex: t.itemBorder)) }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(clock.world) { w in
                        WorldClockRow(clock: w, now: now)
                    }
                }
            }
        }
        .padding(14)
        .frame(minWidth: 240)
        .font(.custom(t.font, size: t.fontSize))
        .foregroundStyle(Color(hex: t.label))
        .background(Color(hex: t.popupBackground))
    }
}

private struct CalendarGrid: View {
    let grid: MonthGrid
    @Environment(BarStore.self) private var store

    var body: some View {
        let t = store.theme
        VStack(alignment: .leading, spacing: 6) {
            Text(grid.title)
                .font(.custom(t.font, size: t.fontSize + 1).weight(.semibold))
                .foregroundStyle(Color(hex: t.accent))
            Grid(horizontalSpacing: 4, verticalSpacing: 2) {
                GridRow {
                    ForEach(["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"], id: \.self) {
                        Text($0).foregroundStyle(Color(hex: t.workspaceIcon)).frame(width: 26)
                    }
                }
                ForEach(Array(grid.weeks.enumerated()), id: \.offset) { _, week in
                    let isThisWeek = week.contains { $0 != nil && $0 == grid.today }
                    GridRow {
                        ForEach(0..<7, id: \.self) { i in
                            let day = week[i]
                            Text(day.map(String.init) ?? "")
                                .monospacedDigit()
                                .frame(width: 26, height: 20)
                                .foregroundStyle(Color(hex: day == grid.today ? t.workspaceFocusIcon : t.label))
                                .background {
                                    if day == grid.today {
                                        RoundedRectangle(cornerRadius: 5).strokeBorder(Color(hex: t.accent), lineWidth: 1)
                                    }
                                }
                        }
                    }
                    .background(isThisWeek ? Color(hex: t.itemBorder).opacity(0.6) : .clear, in: RoundedRectangle(cornerRadius: 5))
                }
            }
        }
    }
}

private struct WorldClockRow: View {
    let clock: WorldClock
    let now: Date
    @Environment(BarStore.self) private var store

    var body: some View {
        let t = store.theme
        let offset = ClockText.dayOffset(now, clock)
        HStack {
            Text(clock.city)
            if offset != 0 {
                Text(offset > 0 ? "tomorrow" : "yesterday")
                    .foregroundStyle(Color(hex: t.workspaceIcon))
            }
            Spacer(minLength: 16)
            Text(clock.timeZone.map { ClockText.format(now, clock.format, zone: $0) } ?? "unknown zone")
                .monospacedDigit()
            Text(clock.timeZone?.abbreviation(for: now) ?? "")
                .foregroundStyle(Color(hex: t.workspaceIcon))
                .frame(minWidth: 40, alignment: .leading)
        }
    }
}
