import Foundation
import Testing
@testable import DigUpKit

@Suite struct WorkerTests {
    /// A hung worker is stopped after its timeout, at start and on a request. (It sleeps for 20 s, then exits: without
    /// the timeout the calls would still throw, but only then.)
    @Test func aWorkerThatNeverAnswersIsStopped() throws {
        signal(SIGPIPE, SIG_IGN)   // as in the app and the CLI: `close` may write to a worker that just stopped
        var config = WorkerConfig(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["20"])
        config.startTimeout = 0.5
        var started = Date()
        #expect(throws: WorkerError.self) { try EmbeddingWorker(config, textOnly: false) }
        #expect(Date().timeIntervalSince(started) < 10)

        let ready = #"{"ready": true, "info": {"model": "m", "revision": "r", "runtime": "sh", "dtype": "q8", "#
            + #""dim": 4, "text_only": true}}"#
        config = WorkerConfig(executable: URL(fileURLWithPath: "/bin/sh"),
                              arguments: ["-c", "echo '\(ready)'; exec sleep 20"])
        config.replyTimeout = 0.5
        let worker = try EmbeddingWorker(config, textOnly: false)
        started = Date()
        #expect(throws: WorkerError.self) { try worker.embedTexts(["hello"]) }
        #expect(Date().timeIntervalSince(started) < 10)
    }
}
