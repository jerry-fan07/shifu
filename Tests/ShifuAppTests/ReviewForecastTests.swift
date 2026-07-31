import Foundation
import ShifuCore
import Testing
@testable import ShifuApp

/// The Decks band's arithmetic (design.md §5.2). What it draws is a claim about
/// how behind the user is, so the bucketing is pinned here rather than eyeballed
/// on a chart: an off-by-one at the day boundary turns "due tonight" into
/// "overdue", which is the one thing this band must never say wrongly.
@Suite struct ReviewForecastTests {
    static let calendar = Calendar(identifier: .gregorian)
    /// A Tuesday, mid-morning — far enough from both midnights that a naive
    /// `due < now` comparison would show up.
    static let now = calendar.date(
        from: DateComponents(year: 2_026, month: 7, day: 28, hour: 10, minute: 30))!

    /// A card scheduled `days` from `now` at `hour`, having been reviewed once.
    static func card(dueIn days: Int, hour: Int = 10, reps: Int = 1) -> Note {
        let due = calendar.date(byAdding: .day, value: days, to: now)!
        let atHour = calendar.date(
            bySettingHour: hour, minute: 0, second: 0, of: due)!
        return Note(
            topic: "t",
            srs: FSRS.State(intervalDays: Double(days), due: atHour, reps: reps),
            body: "Q: q\nA: a")
    }

    static func build(_ cards: [Note], span: Int = 28) -> ReviewForecast {
        ReviewForecast.build(cards: cards, span: span, now: now, calendar: calendar)
    }

    @Test("Cards land on the local day they come due, today first")
    func bucketsByDay() {
        let forecast = Self.build([
            Self.card(dueIn: 0), Self.card(dueIn: 0),
            Self.card(dueIn: 1),
            Self.card(dueIn: 5)
        ])
        #expect(forecast.days[0].dueCount == 2)
        #expect(forecast.days[1].dueCount == 1)
        #expect(forecast.days[5].dueCount == 1)
        #expect(forecast.windowTotal == 4)
        #expect(forecast.backlog == 0)
    }

    @Test("Earlier today is still today, not backlog")
    func earlierTodayIsNotOverdue() {
        // 08:00 on the day of a 10:30 `now`: the card is due *now* by the
        // queue's clock, but it has not missed its day.
        let forecast = Self.build([Self.card(dueIn: 0, hour: 8)])
        #expect(forecast.backlog == 0)
        #expect(forecast.days[0].dueCount == 1)
    }

    @Test("Late tonight is still today, not tomorrow")
    func lateTonightIsToday() {
        let forecast = Self.build([Self.card(dueIn: 0, hour: 23)])
        #expect(forecast.days[0].dueCount == 1)
        #expect(forecast.days[1].dueCount == 0)
    }

    @Test("Everything past its day gathers into the backlog")
    func backlogGathersEveryPastDay() {
        let forecast = Self.build([
            Self.card(dueIn: -1), Self.card(dueIn: -40), Self.card(dueIn: -400)
        ])
        #expect(forecast.backlog == 3)
        #expect(forecast.windowTotal == 0)
        #expect(forecast.beyond == 0)
    }

    @Test("Past the window a card is counted, never dropped")
    func beyondTheWindow() {
        let forecast = Self.build([Self.card(dueIn: 27), Self.card(dueIn: 28)])
        #expect(forecast.days[27].dueCount == 1)
        #expect(forecast.beyond == 1)
        #expect(forecast.windowTotal == 1)
    }

    /// The rule the band exists to get right: a fresh hundred-card deck is a
    /// pool to start, not a hundred reviews of neglect.
    @Test("Never-reviewed cards are unstarted, not backlog")
    func newCardsAreNotBacklog() {
        let born = Note(
            topic: "t", srs: FSRS.State(due: Self.now, reps: 0), body: "Q: q\nA: a")
        let never = Note(topic: "t", srs: nil, body: "Q: q\nA: a")
        let forecast = Self.build([born, never, Self.card(dueIn: -3)])
        #expect(forecast.unstarted == 2)
        #expect(forecast.backlog == 1)
        #expect(forecast.windowTotal == 0)
    }

    @Test("Cumulative counts the backlog you carry into each day")
    func cumulativeCarriesTheBacklog() {
        let forecast = Self.build([
            Self.card(dueIn: -1), Self.card(dueIn: -2),
            Self.card(dueIn: 0),
            Self.card(dueIn: 2)
        ])
        #expect(forecast.days[0].cumulative == 3)
        #expect(forecast.days[1].cumulative == 3)
        #expect(forecast.days[2].cumulative == 4)
    }

    @Test("The window is fully populated, empty days included")
    func everyDayGetsAColumn() {
        let forecast = Self.build([Self.card(dueIn: 3)])
        #expect(forecast.days.count == 28)
        #expect(forecast.days[0].isToday)
        #expect(forecast.days.filter { $0.dueCount == 0 }.count == 27)
    }

    /// The backlog shares the columns' axis, so it has to share their peak too
    /// — otherwise the one column that says "you are buried" is drawn off the
    /// top of the band.
    @Test("The peak spans the backlog and the days alike")
    func peakSpansBoth() {
        let buried = Self.build(Array(repeating: Self.card(dueIn: -1), count: 9)
            + [Self.card(dueIn: 4)])
        #expect(buried.peak == 9)
        let busy = Self.build([Self.card(dueIn: -1)]
            + Array(repeating: Self.card(dueIn: 4), count: 6))
        #expect(busy.peak == 6)
    }

    /// The shelf rows draw the same forecast over a week (`ShelfMeasures
    /// .sparkDays`), so the short span gets its own boundary check — a row is
    /// where an off-by-one would be least visible.
    @Test("A week-long window ends after day 6")
    func weekWindow() {
        let forecast = Self.build(
            [Self.card(dueIn: 6), Self.card(dueIn: 7), Self.card(dueIn: 30)], span: 7)
        #expect(forecast.days.count == 7)
        #expect(forecast.days[6].dueCount == 1)
        #expect(forecast.beyond == 2)
    }

    @Test("Nothing scheduled means nothing to draw")
    func noScheduleNoBand() {
        let new = Note(topic: "t", srs: FSRS.State(due: Self.now, reps: 0), body: "Q: q\nA: a")
        #expect(!Self.build([new]).hasSchedule)
        #expect(!Self.build([]).hasSchedule)
        #expect(Self.build([Self.card(dueIn: 400)]).hasSchedule)
    }
}
