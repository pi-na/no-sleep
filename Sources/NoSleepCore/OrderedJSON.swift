import Foundation

/// Minimal JSON model that preserves key order and number literals, so we can edit
/// users' `settings.json` / `hooks.json` without reshuffling their files.
public indirect enum JSONValue: Equatable, Sendable {
    case object([Member])
    case array([JSONValue])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    public struct Member: Equatable, Sendable {
        public var key: String
        public var value: JSONValue
        public init(_ key: String, _ value: JSONValue) {
            self.key = key
            self.value = value
        }
    }

    public subscript(key: String) -> JSONValue? {
        get {
            guard case .object(let members) = self else { return nil }
            return members.first { $0.key == key }?.value
        }
        set {
            guard case .object(var members) = self else { return }
            if let index = members.firstIndex(where: { $0.key == key }) {
                if let newValue { members[index].value = newValue } else { members.remove(at: index) }
            } else if let newValue {
                members.append(Member(key, newValue))
            }
            self = .object(members)
        }
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var isObject: Bool {
        if case .object = self { return true }
        return false
    }

    // MARK: Serialization

    public func serialized(indent: String = "  ") -> String {
        var output = ""
        write(into: &output, level: 0, indent: indent)
        return output
    }

    private func write(into output: inout String, level: Int, indent: String) {
        let pad = String(repeating: indent, count: level)
        let innerPad = String(repeating: indent, count: level + 1)
        switch self {
        case .null: output += "null"
        case .bool(let value): output += value ? "true" : "false"
        case .number(let literal): output += literal
        case .string(let value): output += Self.quote(value)
        case .array(let items):
            if items.isEmpty { output += "[]"; return }
            output += "[\n"
            for (index, item) in items.enumerated() {
                output += innerPad
                item.write(into: &output, level: level + 1, indent: indent)
                output += index == items.count - 1 ? "\n" : ",\n"
            }
            output += pad + "]"
        case .object(let members):
            if members.isEmpty { output += "{}"; return }
            output += "{\n"
            for (index, member) in members.enumerated() {
                output += innerPad + Self.quote(member.key) + ": "
                member.value.write(into: &output, level: level + 1, indent: indent)
                output += index == members.count - 1 ? "\n" : ",\n"
            }
            output += pad + "}"
        }
    }

    static func quote(_ string: String) -> String {
        var result = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case "\u{08}": result += "\\b"
            case "\u{0C}": result += "\\f"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }

    // MARK: Parsing

    public struct ParseError: Error, CustomStringConvertible {
        public let message: String
        public let offset: Int
        public var description: String { "Invalid JSON at byte \(offset): \(message)" }
    }

    public static func parse(_ text: String) throws -> JSONValue {
        var parser = Parser(bytes: Array(text.utf8))
        parser.skipWhitespace()
        let value = try parser.parseValue()
        parser.skipWhitespace()
        guard parser.isAtEnd else { throw parser.error("unexpected trailing content") }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        var isAtEnd: Bool { index >= bytes.count }

        func error(_ message: String) -> ParseError { ParseError(message: message, offset: index) }

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        mutating func expect(_ byte: UInt8) throws {
            guard index < bytes.count, bytes[index] == byte else {
                throw error("expected '\(Character(Unicode.Scalar(byte)))'")
            }
            index += 1
        }

        mutating func consume(literal: String) -> Bool {
            let literalBytes = Array(literal.utf8)
            guard index + literalBytes.count <= bytes.count,
                  Array(bytes[index..<index + literalBytes.count]) == literalBytes else { return false }
            index += literalBytes.count
            return true
        }

        mutating func parseValue() throws -> JSONValue {
            guard index < bytes.count else { throw error("unexpected end of input") }
            switch bytes[index] {
            case UInt8(ascii: "{"): return try parseObject()
            case UInt8(ascii: "["): return try parseArray()
            case UInt8(ascii: "\""): return .string(try parseString())
            case UInt8(ascii: "t"):
                if consume(literal: "true") { return .bool(true) }
            case UInt8(ascii: "f"):
                if consume(literal: "false") { return .bool(false) }
            case UInt8(ascii: "n"):
                if consume(literal: "null") { return .null }
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
                return try parseNumber()
            default: break
            }
            throw error("unexpected character")
        }

        mutating func parseObject() throws -> JSONValue {
            try expect(UInt8(ascii: "{"))
            var members: [Member] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(members) }
            while true {
                skipWhitespace()
                let key = try parseString()
                skipWhitespace()
                try expect(UInt8(ascii: ":"))
                skipWhitespace()
                members.append(Member(key, try parseValue()))
                skipWhitespace()
                guard index < bytes.count else { throw error("unterminated object") }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                try expect(UInt8(ascii: "}"))
                return .object(members)
            }
        }

        mutating func parseArray() throws -> JSONValue {
            try expect(UInt8(ascii: "["))
            var items: [JSONValue] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
            while true {
                skipWhitespace()
                items.append(try parseValue())
                skipWhitespace()
                guard index < bytes.count else { throw error("unterminated array") }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                try expect(UInt8(ascii: "]"))
                return .array(items)
            }
        }

        mutating func parseNumber() throws -> JSONValue {
            let start = index
            let numberBytes = Set("+-0123456789.eE".utf8)
            while index < bytes.count, numberBytes.contains(bytes[index]) { index += 1 }
            let literal = String(decoding: bytes[start..<index], as: UTF8.self)
            guard Double(literal) != nil else { index = start; throw error("invalid number") }
            return .number(literal)
        }

        mutating func parseHex4() throws -> UInt32 {
            guard index + 4 <= bytes.count,
                  let value = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16)
            else { throw error("invalid unicode escape") }
            index += 4
            return value
        }

        mutating func parseString() throws -> String {
            try expect(UInt8(ascii: "\""))
            var raw: [UInt8] = []
            while true {
                guard index < bytes.count else { throw error("unterminated string") }
                let byte = bytes[index]
                index += 1
                if byte == UInt8(ascii: "\"") { break }
                if byte != UInt8(ascii: "\\") { raw.append(byte); continue }
                guard index < bytes.count else { throw error("unterminated escape") }
                let escaped = bytes[index]
                index += 1
                switch escaped {
                case UInt8(ascii: "\""): raw.append(UInt8(ascii: "\""))
                case UInt8(ascii: "\\"): raw.append(UInt8(ascii: "\\"))
                case UInt8(ascii: "/"): raw.append(UInt8(ascii: "/"))
                case UInt8(ascii: "b"): raw.append(0x08)
                case UInt8(ascii: "f"): raw.append(0x0C)
                case UInt8(ascii: "n"): raw.append(0x0A)
                case UInt8(ascii: "r"): raw.append(0x0D)
                case UInt8(ascii: "t"): raw.append(0x09)
                case UInt8(ascii: "u"):
                    var code = try parseHex4()
                    if (0xD800...0xDBFF).contains(code),
                       index + 6 <= bytes.count,
                       bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                        index += 2
                        let low = try parseHex4()
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    }
                    let scalar = Unicode.Scalar(code) ?? "\u{FFFD}"
                    raw.append(contentsOf: Array(String(scalar).utf8))
                default: throw error("invalid escape")
                }
            }
            return String(decoding: raw, as: UTF8.self)
        }
    }
}
