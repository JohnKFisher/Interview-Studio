import Foundation

extension KeyedDecodingContainer {
    func decodeLossyString(forKey key: Key) throws -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return String(value)
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return value == floor(value) ? String(Int(value)) : String(value)
        }
        if let value = try? decodeIfPresent(Bool.self, forKey: key) {
            return value ? "true" : "false"
        }
        return nil
    }

    func decodeLossyInt64(forKey key: Key) throws -> Int64? {
        if let value = try? decodeIfPresent(Int64.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return Int64(value)
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return Int64(value.rounded())
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.isEmpty { return nil }
            if let intValue = Int64(cleaned) {
                return intValue
            }
            if let doubleValue = Double(cleaned) {
                return Int64(doubleValue.rounded())
            }
        }
        return nil
    }

    func decodeLossyInt(forKey key: Key) throws -> Int? {
        guard let value = try decodeLossyInt64(forKey: key) else { return nil }
        return Int(value)
    }

    func decodeLossyDouble(forKey key: Key) throws -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return Double(value)
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? nil : Double(cleaned)
        }
        return nil
    }

    func decodeLossyBool(forKey key: Key) throws -> Bool? {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1":
                return true
            case "false", "no", "0":
                return false
            default:
                return nil
            }
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value != 0
        }
        return nil
    }
}
