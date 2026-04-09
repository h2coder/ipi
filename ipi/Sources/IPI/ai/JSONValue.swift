import Foundation

public typealias JSONObject = [String: JSONValue]

public enum JSONValue: Sendable, Equatable, Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object(JSONObject)
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
            return
        }

        if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
            return
        }

        if let int = try? container.decode(Int.self) {
            self = .number(Double(int))
            return
        }

        if let double = try? container.decode(Double.self) {
            self = .number(double)
            return
        }

        if let string = try? container.decode(String.self) {
            self = .string(string)
            return
        }

        if let object = try? container.decode(JSONObject.self) {
            self = .object(object)
            return
        }

        if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
            return
        }

        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Unsupported JSON value."
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    public var stringValue: String? {
        guard case .string(let value) = self else {
            return nil
        }

        return value
    }

    public var objectValue: JSONObject? {
        guard case .object(let value) = self else {
            return nil
        }

        return value
    }
}

extension JSONValue {
    var foundationValue: Any {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            return value
        case .bool(let value):
            return value
        case .object(let value):
            return value.mapValues(\.foundationValue)
        case .array(let value):
            return value.map(\.foundationValue)
        case .null:
            return NSNull()
        }
    }

    static func from(any value: Any) throws -> JSONValue {
        switch value {
        case let value as String:
            return .string(value)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return .bool(value.boolValue)
            }
            return .number(value.doubleValue)
        case let value as [String: Any]:
            return .object(try value.mapValues(JSONValue.from(any:)))
        case let value as [Any]:
            return .array(try value.map(JSONValue.from(any:)))
        case _ as NSNull:
            return .null
        default:
            throw NSError(
                domain: "IPI.JSONValue",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unsupported JSON value: \(type(of: value))"]
            )
        }
    }

    static func decodeObject(from jsonString: String) throws -> JSONObject {
        let data = Data(jsonString.utf8)
        let jsonObject = try JSONSerialization.jsonObject(with: data)
        let jsonValue = try JSONValue.from(any: jsonObject)

        guard case .object(let object) = jsonValue else {
            throw NSError(
                domain: "IPI.JSONValue",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Expected a JSON object."]
            )
        }

        return object
    }
}
