// Sources/SwiftStack/Census/FeatureCensus.swift
import Foundation

/// Feature census entry representing a counted Swift language feature or attribute.
public struct FeatureCensusEntry: Sendable {
    public let name: String
    public let category: String
    public var count: Int
    public let isSupported: Bool
    public let milestone: String

    public init(name: String, category: String, count: Int = 0, isSupported: Bool, milestone: String) {
        self.name = name
        self.category = category
        self.count = count
        self.isSupported = isSupported
        self.milestone = milestone
    }
}

/// Feature census scanner that counts attributes, features, and flags in Swift sources (02 §4.3.5, 09 §5 M0).
public final class FeatureCensus {
    private var entries: [String: FeatureCensusEntry] = [:]

    public init() {
        registerKnownFeatures()
    }

    private func registerKnownFeatures() {
        // Known Todhchai & Swift 6.x features from 02-semantic-analysis.md §4.3.5
        register(name: "@c", category: "Attribute", isSupported: true, milestone: "M4")
        register(name: "@_extern", category: "Attribute", isSupported: true, milestone: "M4")
        register(name: "@_silgen_name", category: "Attribute", isSupported: true, milestone: "M4")
        register(name: "unsafe", category: "Keyword/Expr", isSupported: true, milestone: "M4")
        register(name: "@unsafe", category: "Attribute", isSupported: true, milestone: "M4")
        register(name: "@safe", category: "Attribute", isSupported: true, milestone: "M4")
        register(name: "@_lifetime", category: "Attribute", isSupported: true, milestone: "M4")
        register(name: "~Escapable", category: "Generics/Types", isSupported: true, milestone: "M4")
        register(name: "~Copyable", category: "Generics/Types", isSupported: true, milestone: "M4")
        register(name: "Span", category: "Generics/Types", isSupported: true, milestone: "M4")
        register(name: "MutableSpan", category: "Generics/Types", isSupported: true, milestone: "M4")
        register(name: "RawSpan", category: "Generics/Types", isSupported: true, milestone: "M4")
        register(name: "MutableRawSpan", category: "Generics/Types", isSupported: true, milestone: "M4")
        register(name: "InlineArray", category: "Generics/Types", isSupported: true, milestone: "M4")
        register(name: "VolatileMappedRegister", category: "Types", isSupported: true, milestone: "M4")
        register(name: "@_noAllocation", category: "Attribute", isSupported: true, milestone: "M4")
        register(name: "@_noLocks", category: "Attribute", isSupported: true, milestone: "M4")
        register(name: "borrowing", category: "Ownership", isSupported: true, milestone: "M4")
        register(name: "consuming", category: "Ownership", isSupported: true, milestone: "M4")

        // Tier 1 features (M6 / M7)
        register(name: "any", category: "Existential", isSupported: false, milestone: "M6")
        register(name: "some", category: "Opaque", isSupported: false, milestone: "M6")
        register(name: "actor", category: "Concurrency", isSupported: false, milestone: "M7")
        register(name: "@MainActor", category: "Concurrency", isSupported: false, milestone: "M7")
        register(name: "async", category: "Concurrency", isSupported: false, milestone: "M7")
        register(name: "await", category: "Concurrency", isSupported: false, milestone: "M7")
        register(name: "@propertyWrapper", category: "Attribute", isSupported: false, milestone: "M6")
        register(name: "macro", category: "Macro", isSupported: true, milestone: "M4")
        register(name: "@attached", category: "Macro", isSupported: true, milestone: "M4")
        register(name: "@freestanding", category: "Macro", isSupported: true, milestone: "M4")

        // Build flags
        register(name: "-enable-experimental-feature Embedded", category: "Flag", isSupported: true, milestone: "M4")
        register(name: "-enable-experimental-feature Lifetimes", category: "Flag", isSupported: true, milestone: "M4")
        register(name: "-enable-experimental-feature Extern", category: "Flag", isSupported: true, milestone: "M4")
        register(name: "-enable-experimental-feature Volatile", category: "Flag", isSupported: true, milestone: "M4")
        register(name: "-strict-memory-safety", category: "Flag", isSupported: true, milestone: "M4")
        register(name: "-no-allocations", category: "Flag", isSupported: true, milestone: "M4")
        register(name: "-enforce-exclusivity=unchecked", category: "Flag", isSupported: true, milestone: "M4")
    }

    private func register(name: String, category: String, isSupported: Bool, milestone: String) {
        entries[name] = FeatureCensusEntry(name: name, category: category, isSupported: isSupported, milestone: milestone)
    }

    /// Scans a Swift file's text for registered features and attributes.
    public func scanFile(content: String) {
        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") { continue }

            for (name, _) in entries {
                if line.contains(name) {
                    entries[name]?.count += countOccurrences(of: name, in: line)
                }
            }
        }
    }

    private func countOccurrences(of needle: String, in haystack: String) -> Int {
        var count = 0
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let range = haystack.range(of: needle, options: [], range: searchRange) {
            count += 1
            searchRange = range.upperBound..<haystack.endIndex
        }
        return count
    }

    /// Recursively scans a directory for `.swift`, `CMakeLists.txt`, and `Package.swift` files.
    public func scanDirectory(at path: String) throws {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: path)
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return
        }

        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension
            let name = fileURL.lastPathComponent
            if ext == "swift" || name == "CMakeLists.txt" || name == "Package.swift" {
                if let data = try? Data(contentsOf: fileURL), let str = String(data: data, encoding: .utf8) {
                    scanFile(content: str)
                }
            }
        }
    }

    /// Returns sorted census entries, optionally filtering or ranking by count.
    public func results() -> [FeatureCensusEntry] {
        return entries.values.sorted {
            if $0.count != $1.count {
                return $0.count > $1.count
            }
            return $0.name < $1.name
        }
    }

    /// Ranks unsupported features by occurrence count.
    public func unsupportedRanked() -> [FeatureCensusEntry] {
        return results().filter { !$0.isSupported && $0.count > 0 }
    }

    /// Generates a Markdown report formatted for architecture documentation.
    public func generateMarkdownReport() -> String {
        var md = "# Swift Feature Census Report\n\n"
        md += "| Feature / Attribute / Flag | Category | Count | Supported? | Milestone |\n"
        md += "|---|---|---|---|---|\n"

        for entry in results() {
            let supp = entry.isSupported ? "Yes" : "**No**"
            md += "| `\(entry.name)` | \(entry.category) | \(entry.count) | \(supp) | \(entry.milestone) |\n"
        }

        let unsupported = unsupportedRanked()
        if !unsupported.isEmpty {
            md += "\n## Top Unsupported Features (Priority for M4/M6)\n\n"
            for (idx, entry) in unsupported.enumerated() {
                md += "\(idx + 1). `\(entry.name)` (\(entry.count) occurrences) -> Target: \(entry.milestone)\n"
            }
        }

        return md
    }
}
