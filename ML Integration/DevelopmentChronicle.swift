import Foundation
import Combine
import AppKit
import CoreGraphics

enum ChronicleEntryKind: String, Codable, CaseIterable, Identifiable {
    case stepCompleted
    case revision
    case note
    case system

    var id: String { rawValue }
}

enum ChronicleAuthorTag: String, Codable, CaseIterable, Identifiable {
    case ai = "AI"
    case developer = "Developer"
    case system = "System"

    var id: String { rawValue }
}

enum ChronicleChapter: String, Codable, CaseIterable, Identifiable {
    case kickoff = "Kickoff"
    case research = "Research"
    case architecture = "Architecture"
    case implementation = "Implementation"
    case revisions = "Revisions"
    case testing = "Testing"
    case release = "Release"

    var id: String { rawValue }
}

struct ScreenshotReference: Codable, Equatable, Identifiable {
    let id: UUID
    let pathOrURL: String
    let caption: String

    init(id: UUID = UUID(), pathOrURL: String, caption: String) {
        self.id = id
        self.pathOrURL = pathOrURL
        self.caption = caption
    }
}

struct ChronicleEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let timestamp: Date
    let kind: ChronicleEntryKind
    let author: ChronicleAuthorTag
    let chapter: ChronicleChapter
    let title: String
    let details: String
    let relatedStageID: String?
    let screenshotReferences: [ScreenshotReference]

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        kind: ChronicleEntryKind,
        author: ChronicleAuthorTag,
        chapter: ChronicleChapter,
        title: String,
        details: String,
        relatedStageID: String? = nil,
        screenshotReferences: [ScreenshotReference] = []
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.author = author
        self.chapter = chapter
        self.title = title
        self.details = details
        self.relatedStageID = relatedStageID
        self.screenshotReferences = screenshotReferences
    }

    enum CodingKeys: String, CodingKey {
        case id
        case timestamp
        case kind
        case author
        case chapter
        case title
        case details
        case relatedStageID
        case screenshotReferences
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        timestamp = try container.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date()
        kind = try container.decodeIfPresent(ChronicleEntryKind.self, forKey: .kind) ?? .note
        author = try container.decodeIfPresent(ChronicleAuthorTag.self, forKey: .author) ?? .system
        chapter = try container.decodeIfPresent(ChronicleChapter.self, forKey: .chapter) ?? .implementation
        title = try container.decode(String.self, forKey: .title)
        details = try container.decode(String.self, forKey: .details)
        relatedStageID = try container.decodeIfPresent(String.self, forKey: .relatedStageID)

        if let rich = try container.decodeIfPresent([ScreenshotReference].self, forKey: .screenshotReferences) {
            screenshotReferences = rich
        } else if let legacy = try container.decodeIfPresent([String].self, forKey: .screenshotReferences) {
            screenshotReferences = legacy.map { ScreenshotReference(pathOrURL: $0, caption: "") }
        } else {
            screenshotReferences = []
        }
    }
}

@MainActor
final class DevelopmentChronicleStore: ObservableObject {
    @Published private(set) var entries: [ChronicleEntry] = []
    @Published private(set) var bookEdition: String = "v1"

    private let fileURL: URL
    private let settingsURL: URL
    private let exportsDirectoryURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let directory = appSupport.appendingPathComponent("MLIntegration", isDirectory: true)

        self.fileURL = directory.appendingPathComponent("development-chronicle.json", isDirectory: false)
        self.settingsURL = directory.appendingPathComponent("chronicle-settings.json", isDirectory: false)
        self.exportsDirectoryURL = directory.appendingPathComponent("exports", isDirectory: true)
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()

        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601

        loadSettings()
        loadOrSeed()
        ensureDailySummaryEntry()
    }

    func updateBookEdition(_ edition: String) {
        let trimmed = edition.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        guard trimmed != bookEdition else {
            return
        }
        bookEdition = trimmed
        saveSettings()
    }

    func log(
        kind: ChronicleEntryKind,
        author: ChronicleAuthorTag,
        chapter: ChronicleChapter,
        title: String,
        details: String,
        relatedStageID: String? = nil,
        screenshotReferences: [ScreenshotReference] = [],
        timestamp: Date = Date()
    ) {
        ensureDailySummaryEntry(for: timestamp)

        let cleanRefs = screenshotReferences
            .map {
                ScreenshotReference(
                    pathOrURL: $0.pathOrURL.trimmingCharacters(in: .whitespacesAndNewlines),
                    caption: $0.caption.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            .filter { !$0.pathOrURL.isEmpty }

        let entry = ChronicleEntry(
            timestamp: timestamp,
            kind: kind,
            author: author,
            chapter: chapter,
            title: title,
            details: details,
            relatedStageID: relatedStageID,
            screenshotReferences: cleanRefs
        )

        entries.append(entry)
        save()
    }

    func exportMarkdown() -> String {
        let formatter = ISO8601DateFormatter()
        var output: [String] = []

        output.append("# ML Integration Development Chronicle")
        output.append("")
        output.append("Edition: \(bookEdition)")
        output.append("Generated: \(formatter.string(from: Date()))")
        output.append("")

        for chapter in ChronicleChapter.allCases {
            let chapterEntries = entries
                .filter { $0.chapter == chapter }
                .sorted(by: { $0.timestamp < $1.timestamp })

            guard !chapterEntries.isEmpty else {
                continue
            }

            output.append("## Chapter: \(chapter.rawValue)")
            output.append("")

            for entry in chapterEntries {
                let timestamp = formatter.string(from: entry.timestamp)
                output.append("### \(timestamp) | \(entry.kind.rawValue)")
                output.append("- Author: \(entry.author.rawValue)")
                output.append("- Title: \(entry.title)")
                output.append("- Details: \(entry.details)")
                if let stageID = entry.relatedStageID {
                    output.append("- Stage ID: \(stageID)")
                }
                if !entry.screenshotReferences.isEmpty {
                    output.append("- Screenshots:")
                    for ref in entry.screenshotReferences {
                        let caption = ref.caption.isEmpty ? "(no caption)" : ref.caption
                        output.append("  - Path: \(ref.pathOrURL)")
                        output.append("    Caption: \(caption)")
                    }
                }
                output.append("")
            }
        }

        return output.joined(separator: "\n")
    }

    func exportsDirectory() throws -> URL {
        try ensureExportDirectory()
        return exportsDirectoryURL
    }

    func writeMarkdownExport() throws -> URL {
        try ensureExportDirectory()
        let fileName = timestampedFileName(prefix: "chronicle", extension: "md")
        let url = exportsDirectoryURL.appendingPathComponent(fileName, isDirectory: false)
        let markdown = exportMarkdown()
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func writeDOCXExport() throws -> URL {
        try ensureExportDirectory()
        let fileName = timestampedFileName(prefix: "chronicle", extension: "docx")
        let url = exportsDirectoryURL.appendingPathComponent(fileName, isDirectory: false)

        let markdown = exportMarkdown()
        let attr = NSAttributedString(string: markdown)
        let range = NSRange(location: 0, length: attr.length)
        let data = try attr.data(
            from: range,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]
        )
        try data.write(to: url, options: [.atomic])
        return url
    }

    func writePDFExport() throws -> URL {
        try ensureExportDirectory()
        let fileName = timestampedFileName(prefix: "chronicle", extension: "pdf")
        let url = exportsDirectoryURL.appendingPathComponent(fileName, isDirectory: false)

        let markdown = exportMarkdown()
        try renderPDF(text: markdown, to: url)
        return url
    }

    private func ensureDailySummaryEntry(for date: Date = Date()) {
        let calendar = Calendar.current
        let hasSummaryForDay = entries.contains { entry in
            entry.kind == .system
                && entry.title == "Daily Summary"
                && calendar.isDate(entry.timestamp, inSameDayAs: date)
        }

        guard !hasSummaryForDay else {
            return
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .full
        dateFormatter.timeStyle = .none

        let summary = ChronicleEntry(
            timestamp: date,
            kind: .system,
            author: .system,
            chapter: .testing,
            title: "Daily Summary",
            details: "Automatic summary entry created for \(dateFormatter.string(from: date)). Append-only development logging is active.",
            screenshotReferences: []
        )

        entries.append(summary)
        save()
    }

    private func renderPDF(text: String, to destinationURL: URL) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(destinationURL as CFURL, mediaBox: &mediaBox, nil) else {
            throw ChronicleExportError.pdfContextCreationFailed
        }

        let margin: CGFloat = 40
        let textRect = CGRect(
            x: margin,
            y: margin,
            width: mediaBox.width - (margin * 2),
            height: mediaBox.height - (margin * 2)
        )

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        ]

        let textStorage = NSTextStorage(string: text, attributes: attributes)
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        var pageIndex = 0
        while true {
            let container = NSTextContainer(size: textRect.size)
            container.lineFragmentPadding = 0
            layoutManager.addTextContainer(container)

            let glyphRange = layoutManager.glyphRange(for: container)
            if glyphRange.length == 0 {
                layoutManager.removeTextContainer(at: pageIndex)
                break
            }

            context.beginPDFPage(nil)

            NSGraphicsContext.saveGraphicsState()
            let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.current = graphicsContext
            context.translateBy(x: textRect.minX, y: mediaBox.height - textRect.minY)
            context.scaleBy(x: 1, y: -1)
            layoutManager.drawBackground(forGlyphRange: glyphRange, at: .zero)
            layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: .zero)
            NSGraphicsContext.restoreGraphicsState()

            context.endPDFPage()
            pageIndex += 1
        }

        context.closePDF()
    }

    private func loadOrSeed() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? decoder.decode([ChronicleEntry].self, from: data) {
            entries = decoded.sorted(by: { $0.timestamp < $1.timestamp })
            return
        }

        entries = Self.seedEntries()
        save()
    }

    private func save() {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        guard let data = try? encoder.encode(entries) else {
            return
        }
        try? data.write(to: fileURL, options: [.atomic])
    }

    private func loadSettings() {
        struct Settings: Codable {
            let bookEdition: String
        }

        guard let data = try? Data(contentsOf: settingsURL),
              let settings = try? decoder.decode(Settings.self, from: data) else {
            return
        }

        let trimmed = settings.bookEdition.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            bookEdition = trimmed
        }
    }

    private func saveSettings() {
        struct Settings: Codable {
            let bookEdition: String
        }

        let directory = settingsURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let settings = Settings(bookEdition: bookEdition)
        guard let data = try? encoder.encode(settings) else {
            return
        }
        try? data.write(to: settingsURL, options: [.atomic])
    }

    private func ensureExportDirectory() throws {
        try FileManager.default.createDirectory(at: exportsDirectoryURL, withIntermediateDirectories: true)
    }

    private func timestampedFileName(prefix: String, extension ext: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return "\(prefix)_\(formatter.string(from: Date())).\(ext)"
    }

    private static func seedEntries() -> [ChronicleEntry] {
        let formatter = ISO8601DateFormatter()
        let base = formatter.date(from: "2026-04-17T09:00:00Z") ?? Date()

        return [
            ChronicleEntry(
                timestamp: base,
                kind: .system,
                author: .system,
                chapter: .kickoff,
                title: "Project initialization",
                details: "Created base SwiftUI app scaffold and initial project structure."
            ),
            ChronicleEntry(
                timestamp: base.addingTimeInterval(900),
                kind: .stepCompleted,
                author: .ai,
                chapter: .research,
                title: "Feasibility research completed",
                details: "Researched Linux integration constraints on macOS, virtualization options, and distribution compatibility."
            ),
            ChronicleEntry(
                timestamp: base.addingTimeInterval(1800),
                kind: .stepCompleted,
                author: .ai,
                chapter: .architecture,
                title: "Blueprint architecture scaffolded",
                details: "Added domain models, service protocols, planner milestones, and architecture dashboard UI."
            ),
            ChronicleEntry(
                timestamp: base.addingTimeInterval(2100),
                kind: .revision,
                author: .ai,
                chapter: .revisions,
                title: "Compile issue resolved",
                details: "Fixed planner observable imports and view object lifecycle handling for successful build."
            )
        ]
    }
}

enum ChronicleExportError: Error {
    case pdfContextCreationFailed
}
