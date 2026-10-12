import Foundation

private final class ResultBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}

/// Runs async AVFoundation work from the synchronous indexer (one thread on purpose: simple and easy to reason about).
func runBlocking<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
    let box = ResultBox<T>()
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        do { box.result = .success(try await operation()) } catch { box.result = .failure(error) }
        done.signal()
    }
    done.wait()
    return try box.result!.get()
}

/// A stretch of audio as a WAV for the model, or a video frame as a JPEG.
struct MediaPiece: Sendable {
    let input: MediaInput
    let start: Double
    var end: Double
}

/// Where a job being prepared keeps its images and audio: in memory up to `budget` bytes, then in its scratch folder,
/// so a 10-hour recording doesn't sit in memory. Writing every piece to a file for the model to read back wrote ~13×
/// an audio file's size to disk, and a PNG of every screenshot.
final class MediaSink: @unchecked Sendable {
    let folder: URL
    let budget: Int
    private let lock = NSLock()
    private var held = 0   // under `lock`

    init(folder: URL, budget: Int = 128 << 20) {
        self.folder = folder
        self.budget = budget
    }

    func keep(_ data: Data, as format: String) throws -> MediaInput {
        let fits = lock.withLock {
            guard held + data.count <= budget else { return false }
            held += data.count
            return true
        }
        if fits { return .bytes(data) }
        let url = folder.appendingPathComponent(UUID().uuidString + "." + format)
        try data.write(to: url)
        return .file(url.path)
    }

    /// Where a piece made as a file goes (pictures ffmpeg writes, or encoded where there's no in-memory encoder).
    func file(_ format: String) -> URL { folder.appendingPathComponent(UUID().uuidString + "." + format) }
}

/// Audio for the model: 30 s windows of 16 kHz mono (`windows`: AVFoundation on macOS, ffmpeg elsewhere), written as WAV.
enum AudioExtractor {
    static let sampleRate = 16_000.0

    static func rms(_ samples: ArraySlice<Int16>) -> Double {
        guard !samples.isEmpty else { return 0 }
        var sum = 0.0
        for sample in samples { let value = Double(sample) / 32768; sum += value * value }
        return (sum / Double(samples.count)).squareRoot()
    }

    static func wav(_ samples: ArraySlice<Int16>) -> Data {
        var data = Data(capacity: 44 + samples.count * 2)
        func append(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let rate = UInt32(sampleRate)
        append("RIFF"); append32(UInt32(36 + samples.count * 2)); append("WAVE")
        append("fmt "); append32(16); append16(1); append16(1); append32(rate); append32(rate * 2); append16(2); append16(16)
        append("data"); append32(UInt32(samples.count * 2))
        samples.withUnsafeBytes { data.append(contentsOf: $0) }   // Int16 is little-endian on Apple silicon
        return data
    }
}

/// Video for the model: a keyframe per shot (`keyframes`: AVFoundation on macOS, ffmpeg elsewhere); the soundtrack goes
/// through `AudioExtractor`.
enum VideoExtractor {}

/// Durations from the files themselves (`duration`), for when the file system's metadata hasn't got them.
enum MediaInfo {}
