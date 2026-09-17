import Foundation

struct ClassificationResult: Codable {
    let category: String
    let confidence: Double
    let reason: String
    let needsReview: Bool

    enum CodingKeys: String, CodingKey {
        case category, confidence, reason
        case needsReview = "needs_review"
    }
}

enum ClassifierError: Error, CustomStringConvertible {
    case requestFailed(String)
    case invalidResponse
    case notValidJSON(String)

    var description: String {
        switch self {
        case .requestFailed(let m): return "Ollama request failed: \(m) - is Ollama running? (curl http://localhost:11434/api/tags)"
        case .invalidResponse: return "Ollama returned an unexpected response shape"
        case .notValidJSON(let raw): return "Model output was not valid JSON: \(raw)"
        }
    }
}

/// Talks to a local Ollama server only (http://localhost:11434). Sends the minimum
/// needed to classify one bookmark - title, URL, domain, and the category
/// definitions - never the whole bookmark library, and nothing leaves this Mac.
enum Classifier {
    static let model = "qwen3.5:4b"
    static let ollamaURL = URL(string: "http://localhost:11434/api/chat")!

    /// Same prompt content as the validated Python prototype (scripts/test_classify.py),
    /// built from the category config so it's never hard-coded.
    static func buildSystemPrompt(config: CategoryConfigFile) -> String {
        let enabled = config.categories.filter { $0.enabled }.sorted { $0.order < $1.order }
        let categoryLines = enabled.map { cat -> String in
            var line = "- \(cat.name): \(cat.description)"
            if !cat.examples.isEmpty {
                line += " Examples: \(cat.examples.joined(separator: ", "))."
            }
            if !cat.exclusions.isEmpty {
                line += " Exclusions: \(cat.exclusions.joined(separator: ", "))."
            }
            return line
        }.joined(separator: "\n")

        let rules = config.classifierRules
        let tieBreak = rules.tieBreakCategories.joined(separator: " vs ")

        return """
        You are classifying a web browser bookmark into exactly one category, based on the user's primary INTENT for the bookmark - what it is being used FOR - not the general subject matter of the website.

        Categories (choose exactly one, by name):
        \(categoryLines)

        Tie-break rule: if a bookmark could reasonably fit more than one category, especially \(tieBreak), default to "\(rules.tieBreakDefault)" and set needs_review to true.

        Respond with ONLY a JSON object matching this exact shape, no other text:
        {"category": "<one of the category names above, exactly>", "confidence": <float 0 to 1>, "reason": "<one short sentence>", "needs_review": <true or false>}
        """
    }

    private struct ChatMessage: Codable {
        let role: String
        let content: String
    }

    private struct ChatRequest: Codable {
        let model: String
        let messages: [ChatMessage]
        let format: String
        let stream: Bool
        let think: Bool
    }

    private struct ChatResponseMessage: Codable {
        let content: String
    }

    private struct ChatResponse: Codable {
        let message: ChatResponseMessage
    }

    /// Blocking on purpose: this is a small CLI/agent invoked briefly per new
    /// bookmark, not a UI app, so a synchronous network call is simpler than
    /// threading async/await through main.swift for no real benefit.
    static func classify(title: String, url: String, domain: String, config: CategoryConfigFile) throws -> ClassificationResult {
        let systemPrompt = buildSystemPrompt(config: config)
        let userPrompt = "Bookmark title: \"\(title)\"\nURL: \(url)\nDomain: \(domain)"

        let request = ChatRequest(
            model: model,
            messages: [
                ChatMessage(role: "system", content: systemPrompt),
                ChatMessage(role: "user", content: userPrompt),
            ],
            format: "json",
            stream: false,
            think: false
        )

        var urlRequest = URLRequest(url: ollamaURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(request)
        urlRequest.timeoutInterval = 180

        var resultData: Data?
        var requestError: Error?
        let semaphore = DispatchSemaphore(value: 0)

        let task = URLSession.shared.dataTask(with: urlRequest) { data, _, error in
            resultData = data
            requestError = error
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()

        if let requestError {
            throw ClassifierError.requestFailed(requestError.localizedDescription)
        }
        guard let resultData else {
            throw ClassifierError.invalidResponse
        }

        let chatResponse: ChatResponse
        do {
            chatResponse = try JSONDecoder().decode(ChatResponse.self, from: resultData)
        } catch {
            throw ClassifierError.invalidResponse
        }

        let raw = chatResponse.message.content
        guard let rawData = raw.data(using: .utf8) else {
            throw ClassifierError.notValidJSON(raw)
        }
        do {
            return try JSONDecoder().decode(ClassificationResult.self, from: rawData)
        } catch {
            throw ClassifierError.notValidJSON(raw)
        }
    }
    /// Quick reachability check against Ollama, used as a pre-flight before a batch
    /// of classifications so a fully-down Ollama fails fast with one clear message
    /// instead of a 180s timeout per bookmark.
    static func healthCheck(timeout: TimeInterval = 3) -> Bool {
        guard let url = URL(string: "http://localhost:11434/api/tags") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout

        var ok = false
        let semaphore = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { _, response, error in
            if error == nil, let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                ok = true
            }
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()
        return ok
    }
}
