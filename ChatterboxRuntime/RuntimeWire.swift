import Foundation

struct RuntimeRequest: Codable {
    var version = 1
    var id: String = UUID().uuidString
    var operation: String
    var body: JSON = [:]
}
struct RuntimeReply: Codable {
    var id: String?
    var result: JSON?
    var error: String?
    var event: RuntimeEvent?
}
extension JSON {
    static func value<T: Encodable>(_ value: T) throws -> JSON {
        let e=JSONEncoder();e.dateEncodingStrategy = .iso8601
        return try JSON.parse(e.encode(value))
    }
    func decode<T: Decodable>(_ type:T.Type) throws -> T {
        let d=JSONDecoder();d.dateDecodingStrategy = .iso8601
        return try d.decode(type,from:encoded())
    }
}
