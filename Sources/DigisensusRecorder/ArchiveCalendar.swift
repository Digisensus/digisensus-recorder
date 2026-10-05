import SwiftUI

struct ArchiveCalendar: View {
    @ObservedObject var library: LibraryStore

    private var calendar: Calendar { Calendar.current }

    private var counts: [Date: Int] {
        library.filteredRecordings.reduce(into: [:]) { $0[calendar.startOfDay(for: $1.startedAt), default: 0] += 1 }
    }

    private var cells: [(date: Date, inMonth: Bool)] {
        let month = library.calendarMonth
        guard let days = calendar.range(of: .day, in: .month, for: month) else { return [] }
        let leading = (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
        let total = Int((Double(leading + days.count) / 7).rounded(.up)) * 7
        return (0..<total).compactMap { index in
            calendar.date(byAdding: .day, value: index - leading, to: month).map {
                ($0, index >= leading && index < leading + days.count)
            }
        }
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.shortStandaloneWeekdaySymbols.map { String($0.prefix(2)) }
        return (0..<7).map { symbols[($0 + calendar.firstWeekday - 1) % 7] }
    }

    var body: some View {
        let counts = counts
        let cells = cells
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                (Text(library.calendarMonth.formatted(.dateTime.month(.wide))).fontWeight(.bold)
                    + Text(" " + library.calendarMonth.formatted(.dateTime.year())).foregroundColor(Palette.tertiary))
                    .font(.system(size: 14))
                    .frame(maxWidth: .infinity, alignment: .leading)
                monthButton("chevron.left", label: "Previous month") { library.shiftMonth(by: -1) }
                Button("Today") { library.select(day: Date()) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .card(radius: 7)
                monthButton("chevron.right", label: "Next month") { library.shiftMonth(by: 1) }
            }
            .padding(.horizontal, 2)
            .padding(.bottom, 2)

            Grid(horizontalSpacing: 0, verticalSpacing: 1) {
                GridRow {
                    ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                        Text(symbol)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Palette.tertiary)
                            .frame(maxWidth: .infinity)
                    }
                }
                ForEach(0..<cells.count / 7, id: \.self) { week in
                    GridRow {
                        ForEach(0..<7, id: \.self) { weekday in
                            let cell = cells[week * 7 + weekday]
                            DayCell(day: cell.date, inMonth: cell.inMonth,
                                    count: cell.inMonth ? counts[cell.date] ?? 0 : 0,
                                    isToday: calendar.isDateInToday(cell.date),
                                    isFuture: cell.date > Date(),
                                    isSelected: cell.inMonth && library.listMode == .day
                                        && calendar.isDate(cell.date, inSameDayAs: library.selectedDay)) {
                                library.select(day: cell.date)
                            }
                        }
                    }
                }
            }
        }
    }

    private func monthButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.secondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }
}

private struct DayCell: View {
    let day: Date
    let inMonth: Bool
    let count: Int
    let isToday: Bool
    let isFuture: Bool
    let isSelected: Bool
    let action: () -> Void

    private var ink: Color {
        if isSelected { return Palette.onStrong }
        if !inMonth { return Palette.tertiary.opacity(0.45) }
        return isFuture ? Palette.tertiary.opacity(0.8) : Palette.ink
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(day.formatted(.dateTime.day()))
                    .font(.system(size: 13, weight: count > 0 ? .bold : .medium))
                    .monospacedDigit()
                    .foregroundStyle(ink)
                HStack(spacing: 2) {
                    ForEach(0..<min(count, 3), id: \.self) { _ in
                        Circle()
                            .fill(isSelected ? Palette.onStrong : Palette.accent)
                            .frame(width: 4, height: 4)
                    }
                }
                .frame(height: 4)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 9).fill(Palette.strong)
                } else if isToday {
                    RoundedRectangle(cornerRadius: 9).strokeBorder(Palette.accent, lineWidth: 1.5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!inMonth)
        .accessibilityLabel(day.formatted(.dateTime.day().month(.wide))
            + ", " + (count == 0 ? "no calls" : "\(count) call\(count == 1 ? "" : "s")"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
