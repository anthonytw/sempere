#if canImport(Speech)
import Foundation
import Speech
@testable import SempereSpeech
import XCTest

/// Transcription stays on the device (docs/security.md, the privacy policy): the request the recognizer runs requires
/// on-device recognition. The `supportsOnDeviceRecognition` guard before it needs the Speech runtime and a model, so it is
/// not reached here.
final class SpeechRequestTests: XCTestCase {
    func testTheRecognitionRequestRequiresOnDeviceRecognition() {
        let request = Recognizer.request(for: URL(fileURLWithPath: "/nonexistent/recording.m4a"))
        XCTAssertTrue(request.requiresOnDeviceRecognition)
        XCTAssertFalse(request.shouldReportPartialResults)
    }
}
#endif
