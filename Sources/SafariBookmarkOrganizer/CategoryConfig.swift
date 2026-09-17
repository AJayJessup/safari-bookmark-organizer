import Foundation

/// The category system as the user controls it. This file is the ONLY schema for
/// categories in the whole project - nothing is hard-coded elsewhere. The classifier
/// (not implemented yet) must load this at runtime and select only from `enabled`
/// categories; it must never invent a category that isn't listed here.
struct Category: Codable {
    var order: Int
    var name: String            // display name, and the classifier's label
    var safariFolder: String    // the ACTUAL Safari folder name this maps to -
                                 // may differ from `name` (e.g. "Relax" -> "Relax/Focus")
    var description: String
    var examples: [String]
    var exclusions: [String]
    var enabled: Bool
}

struct ClassifierRules: Codable {
    var tieBreakCategories: [String]
    var tieBreakDefault: String
    var flagTieBreakAsUncertain: Bool
}

struct CategoryConfigFile: Codable {
    var confidenceThreshold: Double
    var classifierRules: ClassifierRules
    var categories: [Category]
}

enum CategoryConfig {
    static func load(from url: URL) throws -> CategoryConfigFile {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(CategoryConfigFile.self, from: data)
    }

    /// Used by future category-management commands (add/edit/reorder/enable/disable).
    /// Not wired to a CLI command yet - editing is done by hand in the JSON file for now.
    static func save(_ config: CategoryConfigFile, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: url, options: .atomic)
    }
}
