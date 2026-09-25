import PDFKit
import ShifuCore

/// Reading a PDF's text layer (voice.md §2.2). Most of what people have
/// actually written and kept — essays, letters, reports, papers — is a PDF, so
/// refusing the format refuses the corpus.
///
/// **PDFKit lives here, not in ShifuCore, and that is the point.** ShifuCore is
/// linked by `shifud`, and the capture daemon has no business carrying a
/// document-rendering framework in its link set — it runs for weeks and its
/// budget is 80 MB. `scripts/check-no-network.sh` would not catch this: it
/// greps shifud's undefined symbols for URL-loading machinery, and PDFKit
/// surfaces as `_OBJC_CLASS_$_PDFDocument`. So the split is a real boundary the
/// invariant script cannot enforce for us. The half worth testing — turning
/// extracted lines back into prose — is pure, and lives in ShifuCore as
/// `VoiceImportText`.
enum VoicePDF {
    /// The text layer, reflowed into prose. Throws rather than returning nil so
    /// the reason reaches the page: "it looks scanned" and "it's locked" send
    /// the user to different fixes.
    ///
    /// The caller must still hold the file's security-scoped access around this
    /// call — the read happens here, not before it.
    static func prose(at file: URL) throws -> String {
        let name = file.lastPathComponent
        guard let document = PDFDocument(url: file) else {
            throw VoiceStore.IngestError.unreadable(name: name)
        }
        // A locked document opens fine and then yields nothing, which would
        // otherwise be reported as a scan.
        guard !document.isLocked else {
            throw VoiceStore.IngestError.locked(name: name)
        }
        let pages = (0..<document.pageCount).map { index in
            document.page(at: index)?.string ?? ""
        }
        guard pages.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else {
            throw VoiceStore.IngestError.noTextLayer(name: name)
        }
        let prose = VoiceImportText.prose(pages: pages)
        // A text layer of nothing but page numbers and running heads leaves
        // nothing behind, and that is the same failure as having no layer.
        guard !prose.isEmpty else {
            throw VoiceStore.IngestError.noTextLayer(name: name)
        }
        return prose
    }
}
