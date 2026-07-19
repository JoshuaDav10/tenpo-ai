import Foundation

/// Minimal RIFF/WAVE container for mono PCM16 — pure and platform-free.
/// Exists because raw PCM bytes written to a ".wav" path are not a WAV file:
/// SFSpeech and server STT/pron endpoints need the 44-byte header.
public enum WAV {
    public static func encode(pcm16 data: Data, sampleRate: Int) -> Data {
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = UInt16(channels * (bitsPerSample / 8))

        var header = Data(capacity: 44)
        header.append(contentsOf: Array("RIFF".utf8))
        header.append(le32(UInt32(36 + data.count)))
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8))
        header.append(le32(16))                    // fmt chunk size
        header.append(le16(1))                     // PCM
        header.append(le16(channels))
        header.append(le32(UInt32(sampleRate)))
        header.append(le32(byteRate))
        header.append(le16(blockAlign))
        header.append(le16(bitsPerSample))
        header.append(contentsOf: Array("data".utf8))
        header.append(le32(UInt32(data.count)))
        return header + data
    }

    private static func le16(_ value: UInt16) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    private static func le32(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}
