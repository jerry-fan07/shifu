import Foundation
import ShifuCore

/// The Load page's read (design.md §4.6). Not part of `refresh()`: eight
/// weeks of blocks is a ten-thousand-row query, and `refresh()` fires on
/// every menu open. The page reads once on appear and once per lens change,
/// the way Themes reads its sparklines.
@MainActor
extension LedgerStore {
    func workload(unit: Workload.Unit, now: Int64) -> Workload.Reading? {
        do {
            return try WorkloadStore.reading(database: try db(), unit: unit, now: now)
        } catch {
            report(error)
            return nil
        }
    }
}
