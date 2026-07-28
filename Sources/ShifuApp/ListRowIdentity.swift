import ShifuCore

/// A `List` diffs rows by their `id` across every `ForEach` it contains, not
/// per ForEach or per Section. The Vault task log and the merge-review queue
/// each mix row types whose ids are Int64 primary keys from *different*
/// tables (merge suggestion row 3 vs task row 3), so identities collide and
/// the List duplicates and misplaces rows. Every ForEach that shares a List
/// with another Int64-keyed ForEach must key on these namespaced ids instead.
extension TaskStore.DayLogEntry { var rowID: String { "log-\(id)" } }
extension TaskStore.Overview { var rowID: String { "task-\(id)" } }
extension TaskMerges.Pending { var rowID: String { "merge-\(id)" } }
extension TaskMerges.PendingTheme { var rowID: String { "filing-\(id)" } }
