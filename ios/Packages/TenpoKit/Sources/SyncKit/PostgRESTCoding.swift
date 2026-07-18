import Foundation

/// JSON coders for talking to PostgREST. Foundation's default `Date` coding is
/// seconds-since-reference-date — a bare number Postgres would reject for
/// `timestamptz` — so sync traffic uses ISO-8601 instead. Decoding is tolerant of
/// fractional seconds because PostgREST emits them (`…T05:12:01.123456+00:00`)
/// while `withInternetDateTime` alone would not parse them.
public enum PostgRESTCoding {
    // ISO8601DateFormatter is documented thread-safe; it just isn't marked Sendable.
    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, into in
            var container = into.singleValueContainer()
            try container.encode(isoFractional.string(from: date))
        }
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { from in
            let container = try from.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = isoFractional.date(from: string) ?? isoPlain.date(from: string) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unrecognized timestamp: \(string)")
        }
        return decoder
    }
}
