import Foundation
import os
import SempereCaptureShared

private let tapLogger = Logger(subsystem: "io.github.anthonytw.sempere", category: "quick-capture")

extension VoiceNoteTapLog {
    /// Sends the tap log's lines to the unified log (subsystem `io.github.anthonytw.sempere`, category
    /// `quick-capture`, public: no field is personal). Called at launch by the app and the widget extension.
    static func installUnifiedLog() {
        logLine = { level, line in
            switch level {
            case .notice: tapLogger.notice("\(line, privacy: .public)")
            case .error: tapLogger.error("\(line, privacy: .public)")
            }
        }
    }
}
