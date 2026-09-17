import Foundation

/// Same four real-bookmark test cases as scripts/test_classify.py, ported here so
/// we can confirm the Swift Classifier behaves the same as the validated Python
/// prototype. Hardcoded titles/URLs - never reads Bookmarks.plist.
struct ClassifierTestCase {
    let title: String
    let url: String
    let domain: String
    let expected: String
    let note: String
}

let classifierTestCases: [ClassifierTestCase] = [
    ClassifierTestCase(
        title: "Change Colors in a PNG – Online PNG Maker",
        url: "https://onlinepngtools.com/change-png-color",
        domain: "onlinepngtools.com",
        expected: "Solve",
        note: "a utility used to accomplish a task"
    ),
    ClassifierTestCase(
        title: "Watch Free Movies Online | 123movies",
        url: "https://ww20.0123movie.net/",
        domain: "0123movie.net",
        expected: "Consume",
        note: "unambiguous - watching content someone else made"
    ),
    ClassifierTestCase(
        title: "Register enterthesociety.eth on ENS",
        url: "https://app.ens.domains/enterthesociety.eth/register",
        domain: "app.ens.domains",
        expected: "Solve",
        note: "registration is a transactional act"
    ),
    ClassifierTestCase(
        title: "Ethereum Gas Fees Today ⛽ ETH Gas Chart & Heatmap",
        url: "https://milkroad.com/ethereum/gas/",
        domain: "milkroad.com",
        expected: "Solve",
        note: "a tracker/live dashboard"
    ),
]

func runClassifierTest(config: CategoryConfigFile) {
    var matches = 0
    for testCase in classifierTestCases {
        print("--- \(testCase.title) ---")
        print("    expected: \(testCase.expected)  (\(testCase.note))")
        do {
            let start = Date()
            let result = try Classifier.classify(title: testCase.title, url: testCase.url, domain: testCase.domain, config: config)
            let elapsed = Date().timeIntervalSince(start)
            let status = result.category == testCase.expected ? "MATCH" : "MISMATCH"
            if status == "MATCH" { matches += 1 }
            print("    got: \(result.category)  (confidence \(result.confidence), needs_review \(result.needsReview))  [\(String(format: "%.1f", elapsed))s]  -> \(status)")
            print("    reason: \(result.reason)")
        } catch {
            print("    ERROR: \(error)")
        }
        print("")
    }
    print("=== \(matches)/\(classifierTestCases.count) matched ===")
}
