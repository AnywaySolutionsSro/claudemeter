import Foundation

/// The structure of a JSON document — key paths and value types, never values — for
/// diagnosing an undocumented endpoint without leaking account data.
public enum JSONShape {
    public static func describe(_ data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return ["(not JSON)"]
        }
        var entries: Set<Entry> = []
        walk(root, path: "", into: &entries)
        return entries.sorted { ($0.path, $0.type) < ($1.path, $1.type) }
            .map { "\($0.path.isEmpty ? "$" : $0.path): \($0.type)" }
    }

    private struct Entry: Hashable {
        let path: String
        let type: String
    }

    private static func walk(_ value: Any, path: String, into entries: inout Set<Entry>) {
        if let object = value as? [String: Any] {
            if !path.isEmpty { entries.insert(Entry(path: path, type: "object")) }
            for (key, child) in object {
                walk(child, path: path.isEmpty ? key : "\(path).\(key)", into: &entries)
            }
        } else if let array = value as? [Any] {
            entries.insert(Entry(path: path, type: "array(\(array.count))"))
            for element in array {
                walk(element, path: "\(path)[]", into: &entries)
            }
        } else {
            entries.insert(Entry(path: path, type: typeName(value)))
        }
    }

    private static func typeName(_ value: Any) -> String {
        if value is NSNull { return "null" }
        if LenientJSON.bool(value) != nil { return "bool" }
        if value is NSNumber { return "number" }
        if value is String { return "string" }
        return "unknown"
    }
}
