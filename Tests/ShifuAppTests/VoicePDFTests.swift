import AppKit
import Foundation
import PDFKit
import ShifuCore
import Testing
@testable import ShifuApp

/// The PDF door (voice.md §2.2). Narrow on purpose: the fiddly half — turning
/// extracted lines back into prose — is pure and tested against fixed input in
/// `VoiceImportTextTests`. What can only be checked here is that PDFKit's real
/// extraction feeds it something it can work with, and that the two ways a PDF
/// can carry no writing are refused with the right reason.
@Suite struct VoicePDFTests {
    /// A real PDF with a real text layer, laid out by Core Text so the lines
    /// break where a typesetter would break them rather than where a fixture
    /// author decided they should.
    private func pdf(_ text: String, width: CGFloat = 300) throws -> URL {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: width, height: 500)
        let consumer = try #require(CGDataConsumer(data: data))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        let attributed = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: 11)])
        context.beginPDFPage(nil)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: box.insetBy(dx: 24, dy: 24), transform: nil)
        let frame = CTFramesetterCreateFrame(
            framesetter, CFRangeMake(0, 0), path, nil)
        CTFrameDraw(frame, context)
        context.endPDFPage()
        context.closePDF()

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-pdf-\(UUID().uuidString).pdf")
        try data.write(to: file)
        return file
    }

    /// A PDF with a page but no text on it at all — what a scan looks like to
    /// PDFKit.
    private func imageOnlyPDF() throws -> URL {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 300, height: 300)
        let consumer = try #require(CGDataConsumer(data: data))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(NSColor.gray.cgColor)
        context.fill(CGRect(x: 20, y: 20, width: 260, height: 260))
        context.endPDFPage()
        context.closePDF()
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-scan-\(UUID().uuidString).pdf")
        try data.write(to: file)
        return file
    }

    @Test func extractsTheTextLayerAsProseNotAsLineSoup() throws {
        // Narrow page, long sentences: Core Text wraps them many times, which
        // is exactly the input the reflow exists for.
        let sentence = "The migration ran clean on the copy, which does not tell us "
            + "much at all because the copy has forty thousand rows and production "
            + "has eleven million rows in the very same table."
        let file = try pdf(sentence)
        defer { try? FileManager.default.removeItem(at: file) }

        let prose = try VoicePDF.prose(at: file)
        // The sentence came back whole, with its wraps closed up.
        #expect(prose.contains("does not tell us much at all because the copy"))
        #expect(prose.contains("eleven million rows in the very same table."))
        // One sentence in, one sentence out — not one per visual line.
        #expect(VoiceMetrics.measure([prose]).sentences == 1)
    }

    @Test func aParagraphBreakSurvivesWhenItsLastLineFallsShortOfTheMargin() throws {
        // Measured: PDFKit's `page.string` gives **no** blank line for a
        // paragraph break and **no** leading indent either — both come back as
        // a plain "\n", indistinguishable from a wrap. So paragraph structure
        // in a PDF is recoverable only from line *length*, which is why the
        // reflow's short-line rule carries this alone.
        //
        // It works because a paragraph's final line almost always stops well
        // short of the margin: here "rows." is the whole of it.
        let file = try pdf(
            "The migration ran clean on the copy, which does not tell us much at "
                + "all because the copy has forty thousand rows and production has "
                + "eleven million rows.\n\nNobody has measured the index rebuild on "
                + "production yet, and until somebody does, Friday is a guess rather "
                + "than a plan.",
            width: 320)
        defer { try? FileManager.default.removeItem(at: file) }
        let prose = try VoicePDF.prose(at: file)
        #expect(prose.contains("\n\n"))
        #expect(VoiceMetrics.measure([prose]).paragraphs == 2)
    }

    @Test func aParagraphEndingAtTheMarginIsKnownToMergeIntoTheNext() throws {
        // The documented limit (voice.md §2.2), pinned rather than left to be
        // rediscovered. When a paragraph's last line happens to fill the
        // measure, nothing in PDFKit's output distinguishes it from a wrap —
        // no heuristic can recover it, and no reader could either.
        //
        // The cost is bounded: one reading (`medianParagraphSentences`) and one
        // prompt line drift toward longer paragraphs. Sentence length, the
        // punctuation habits and the vocabulary are untouched, because those
        // never depended on where a paragraph ended.
        let file = try pdf("First thought, stated plainly and then finished.\n\n"
            + "Second thought, which is a different paragraph entirely.")
        defer { try? FileManager.default.removeItem(at: file) }
        let prose = try VoicePDF.prose(at: file)
        #expect(!prose.contains("\n\n"))
        // Both sentences are still there, and still two sentences.
        #expect(VoiceMetrics.measure([prose]).sentences == 2)
    }

    @Test func aPDFWithNoTextLayerIsRefusedAsAScan() throws {
        let file = try imageOnlyPDF()
        defer { try? FileManager.default.removeItem(at: file) }
        var thrown: VoiceStore.IngestError?
        do {
            _ = try VoicePDF.prose(at: file)
        } catch let error as VoiceStore.IngestError {
            thrown = error
        }
        let error = try #require(thrown)
        guard case .noTextLayer = error else {
            Issue.record("expected .noTextLayer, got \(error)")
            return
        }
        // The reason has to say what to do with it, and say Shifu won't OCR.
        #expect(error.description.contains("scanned"))
    }

    @Test func aTextLayerOfNothingButFurnitureCountsAsNoTextLayer() throws {
        // Three pages carrying only page numbers: PDFKit finds a text layer,
        // the reflow correctly leaves nothing, and storing an empty sample
        // would be worse than refusing.
        let file = try pdf("1\n\n2\n\n3")
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(throws: VoiceStore.IngestError.self) {
            try VoicePDF.prose(at: file)
        }
    }

    @Test func anUnreadableFileIsRefusedRatherThanCrashing() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-a-pdf-\(UUID().uuidString).pdf")
        try "this is not a PDF at all".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(throws: VoiceStore.IngestError.self) {
            try VoicePDF.prose(at: file)
        }
    }

    @Test func anImportedPDFLandsInTheCorpusLikeAnyOtherSample() throws {
        // The end of the door: extraction, the word floor, and the file the
        // corpus keeps. Uses a scratch root, never ~/Shifu.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-pdf-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let body = (1...8).map { index in
            "Paragraph \(index) says something worth measuring, at a length that "
                + "clears the floor and wraps across several lines on a narrow page."
        }.joined(separator: "\n\n")
        let file = try pdf(body, width: 400)
        defer { try? FileManager.default.removeItem(at: file) }

        let store = VoiceStore(root: root)
        let sample = try store.add(
            title: file.deletingPathExtension().lastPathComponent,
            text: try VoicePDF.prose(at: file), source: .importedFile)
        #expect(sample.source == .importedFile)
        #expect(sample.wordCount >= VoiceStore.minimumSampleWords)
        #expect(store.samples().count == 1)
        #expect(store.samples().first?.text.contains("worth measuring") == true)
    }
}
