import DigUpKit
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Answers a question (`Question`) with Apple's on-device model, which macOS 26 has with Apple Intelligence on. The
/// question and the passages stay on the Mac.
enum Answering {
    /// Why there's no answer to be had, or nil when the model is ready.
    static var unavailable: String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return nil
            case .unavailable(.appleIntelligenceNotEnabled):
                return "Answers come from Apple Intelligence: turn it on in System Settings to get them."
            case .unavailable(.deviceNotEligible): return "This Mac can't run Apple's on-device model, which answers."
            case .unavailable(.modelNotReady): return "Apple's on-device model is still getting ready; try again soon."
            case .unavailable: return "Apple's on-device model isn't available."
            }
        }
        #endif
        return "Answers need macOS 26 or later, with Apple Intelligence."
    }

    /// The answer as far as it's written, again each time it grows.
    static func answer(_ question: String, sources: [Question.Source]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                #if canImport(FoundationModels)
                if #available(macOS 26.0, *) {
                    do {
                        let session = LanguageModelSession(instructions: Question.instructions)
                        let prompt = Question.prompt(question, sources: sources)
                        for try await snapshot in session.streamResponse(to: prompt) {
                            continuation.yield(snapshot.content)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                    return
                }
                #endif
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Whether `description` fits a file, from its name and a part of its text (a query's "not …",
    /// `QueryFilter.excluded`). Nil when the model can't say.
    static func fits(_ description: String, name: String, text: String) async -> Bool? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), unavailable == nil {
            let session = LanguageModelSession(instructions: QueryFilter.fitInstructions)
            let prompt = QueryFilter.fitPrompt(description, name: name, text: text)
            return try? await session.respond(to: prompt, generating: Verdict.self).content.fits
        }
        #endif
        return nil
    }

    /// What went wrong, said plainly.
    static func problem(_ error: Error) -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation, .refusal: return "Apple's model wouldn't answer this one."
            case .unsupportedLanguageOrLocale: return "Apple's model doesn't answer in this language yet."
            case .exceededContextWindowSize: return "There was too much to read at once."
            default: break
            }
        }
        #endif
        return "Couldn't answer: \(error.localizedDescription)"
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
struct Verdict {
    @Guide(description: "Whether the description fits the file")
    var fits: Bool
}
#endif
