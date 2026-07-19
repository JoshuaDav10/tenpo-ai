import Testing
import Foundation
@testable import SpeechKit

struct WAVFileTests {
    @Test func headerFieldsAndPayloadRoundTrip() {
        let pcm = Data([1, 0, 2, 0, 3, 0, 4, 0]) // 4 samples
        let wav = WAV.encode(pcm16: pcm, sampleRate: 24000)

        #expect(wav.count == 44 + pcm.count)
        #expect(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: wav[8..<12], as: UTF8.self) == "WAVE")
        // Sample rate little-endian at offset 24.
        let rate = wav[24..<28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        #expect(UInt32(littleEndian: rate) == 24000)
        // data chunk size at offset 40, then the payload verbatim.
        let size = wav[40..<44].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        #expect(UInt32(littleEndian: size) == UInt32(pcm.count))
        #expect(wav.suffix(pcm.count) == pcm)
    }
}
