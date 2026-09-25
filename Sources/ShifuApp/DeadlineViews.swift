import ShifuCore
import SwiftUI

// Deadlines on screen (design.md §4.5) — the band on the Tasks page, one row,
// and the sheet a promise is typed into.
//
// The band is the only place a deadline is *authored* in the app, and it sits
// with tasks because a deadline's progress is a task's logged time. There is no
// place of its own on the trail: a page you visit to find four lines would be a
// worse home than the list those four lines are about.

// MARK: - The band

/// Coming up, above the task list. Shows the pressing ones and hides the rest
/// behind a count, so the band's height is bounded however many promises exist.
struct ComingUpBand: View {
    @EnvironmentObject private var store: LedgerStore
    @State private var adding = false

    /// Beyond this the band stops being a glance. The remainder is named in the
    /// eyebrow rather than drawn, the same choice `ReviewForecastView` makes for
    /// cards scheduled past its window.
    private static let shown = 4

    var body: some View {
        let open = store.comingUp
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Eyebrow(eyebrow(open))
                Spacer(minLength: 0)
                InlineLink("Add a deadline") { adding = true }
            }
            .padding(.bottom, open.isEmpty ? 0 : 6)
            ForEach(open.prefix(Self.shown), id: \.deadline.id) { standing in
                DeadlineRow(standing: standing)
            }
            if open.isEmpty {
                Text("A date you give Shifu is the only thing it will interrupt "
                    + "you about — and with a time target, it can tell you how "
                    + "far in you are.")
                    .font(Instrument.sans(12))
                    .foregroundStyle(Instrument.ghost)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 520, alignment: .leading)
                    .padding(.top, 4)
            }
        }
        .sheet(isPresented: $adding) {
            DeadlineSheet(taskID: nil, taskName: nil)
                .environmentObject(store)
        }
    }

    private func eyebrow(_ open: [DeadlineHorizon.Standing]) -> String {
        guard !open.isEmpty else { return "Coming up" }
        let hidden = open.count - Self.shown
        return hidden > 0 ? "Coming up · \(hidden) further out" : "Coming up"
    }
}

// MARK: - One row

/// A deadline as a line: what it is, when, how far in, and the one verb that
/// closes it. Urgency reads twice — from the words and from the hue — because
/// the two smallest gaps in this palette are the overdue and alert marks
/// (Instrument.swift), and colour alone is not a signal.
struct DeadlineRow: View {
    @EnvironmentObject private var store: LedgerStore
    let standing: DeadlineHorizon.Standing
    /// The task page already names the task above every row on it.
    var showsTask = true

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(standing.deadline.title)
                .font(Instrument.sans(13))
                .foregroundStyle(Instrument.ink)
                .lineLimit(1)
            if showsTask, let task = standing.taskName {
                Tag(task)
            }
            Spacer(minLength: 12)
            if let percent = standing.progressPercent {
                Figure("\(percent)%", size: 11.5, color: Instrument.muted)
            }
            Figure(whenText, size: 11.5, color: whenColor)
            // Only on hover: a row that always wears its verb reads as a form,
            // and this list is mostly there to be glanced at.
            if hovering {
                InlineLink("Done") { store.markDeadlineDone(standing.deadline.id ?? 0) }
                InlineLink("Remove") { store.deleteDeadline(standing.deadline.id ?? 0) }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(DeadlineCopy.summary(standing, now: now))
    }

    private var now: Int64 { Int64(Date().timeIntervalSince1970 * 1_000) }

    private var daysLeft: Int {
        DeadlineHorizon.daysUntil(dueAt: standing.deadline.dueAt, now: now)
    }

    private var whenText: String {
        let days = daysLeft
        if days < 0 { return "\(-days)d over" }
        return DeadlineCopy.whenPhrase(daysLeft: days)
    }

    private var whenColor: Color {
        let days = daysLeft
        if days < 0 { return Instrument.overdue }
        return days <= 1 ? Instrument.alert : Instrument.muted
    }
}

// MARK: - The sheet

/// Typing a promise. Three fields and one of them optional, because the whole
/// value of the feature is that recording a date is faster than the thing you
/// would otherwise do about it.
struct DeadlineSheet: View {
    @EnvironmentObject private var store: LedgerStore
    @Environment(\.dismiss) private var dismiss
    /// Non-nil when opened from a task page — the link is then not a question.
    let taskID: Int64?
    let taskName: String?

    @State private var title = ""
    @State private var when = ""
    @State private var targetHours = ""
    @State private var refused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(taskName.map { "A deadline for \($0)" } ?? "A deadline")
                .font(Instrument.sans(17, .semibold))
                .foregroundStyle(Instrument.ink)

            field("What", text: $title, placeholder: "Thesis draft")
            field("When", text: $when, placeholder: "2026-08-30 · tomorrow · friday · +10d")
            field(
                "Time target", text: $targetHours,
                placeholder: taskID == nil
                    ? "20h — needs a task to measure against"
                    : "20h — optional, turns logged time into progress")

            if refused {
                Text("That date didn't read. Try 2026-08-30, 2026-08-30 17:00, "
                    + "today, friday, or +10d.")
                    .font(Instrument.sans(11.5))
                    .foregroundStyle(Instrument.overdue)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .font(Instrument.sans(12.5))
                    .foregroundStyle(Instrument.muted)
                Button("Record it") { record() }
                    .buttonStyle(.plain)
                    .font(Instrument.sans(12.5, .medium))
                    .foregroundStyle(canRecord ? Instrument.accentText : Instrument.ghost)
                    .disabled(!canRecord)
            }
            .padding(.top, 2)
        }
        .padding(22)
        .frame(width: 420)
        .background(Instrument.ground)
    }

    private var canRecord: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
            && !when.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func record() {
        let added = store.addDeadline(
            title: title, when: when, taskID: taskID, targetHours: targetHours)
        if added { dismiss() } else { refused = true }
    }

    private func field(
        _ label: String, text: Binding<String>, placeholder: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Eyebrow(label)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(Instrument.sans(13))
                .foregroundStyle(Instrument.ink)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(Instrument.well)
                .onSubmit { if canRecord { record() } }
        }
    }
}
