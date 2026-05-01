import Foundation
import XCTest
@testable import SoundingKit

private let publicAdMarkerKeys: Set<String> = [
    "Type",
    "Classification",
    "Source",
    "Tag",
    "PTS",
    "Segment",
    "RawBase64",
    "Command",
    "Descriptors",
    "Tags",
    "Fields",
    "Timestamp"
]

private struct SemanticJSONFailure: Error, CustomStringConvertible {
    let description: String
}

func semanticJSONObject(
    from data: Data,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> [String: Any] {
    let value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    guard let object = value as? [String: Any] else {
        XCTFail("Expected top-level JSON object", file: file, line: line)
        return [:]
    }
    return object
}

func assertSemanticJSONEqual(
    _ actualData: Data,
    _ expectedObject: [String: Any],
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    let actualObject = try semanticJSONObject(from: actualData, file: file, line: line)
    XCTAssertTrue(
        NSDictionary(dictionary: actualObject).isEqual(to: expectedObject),
        "Expected semantic JSON objects to match.\nActual: \(actualObject)\nExpected: \(expectedObject)",
        file: file,
        line: line
    )
}

func assertJSONKeys(
    _ object: [String: Any],
    equal expectedKeys: Set<String>,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(Set(object.keys), expectedKeys, file: file, line: line)
}

func assertJSONKeyAbsent(
    _ key: String,
    in object: [String: Any],
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertNil(object[key], "Expected JSON key \(key) to be absent", file: file, line: line)
}

func assertJSONNull(
    _ key: String,
    in object: [String: Any],
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertTrue(object[key] is NSNull, "Expected JSON key \(key) to encode as null", file: file, line: line)
}

func markerNDJSON(
    from markers: [AdMarker],
    encoder: JSONEncoder = JSONEncoder(),
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> Data {
    let lines = try markers.map { marker in
        let data = try encoder.encode(marker)
        guard let line = String(data: data, encoding: .utf8) else {
            let message = "Encoded marker was not valid UTF-8"
            XCTFail(message, file: file, line: line)
            throw SemanticJSONFailure(description: message)
        }
        return line
    }
    return Data(lines.joined(separator: "\n").utf8)
}

func semanticJSONObjects(
    fromNDJSON data: Data,
    sourceClass: String,
    recordFailure: Bool = true,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> [[String: Any]] {
    guard let text = String(data: data, encoding: .utf8) else {
        let message = "\(sourceClass): NDJSON was not valid UTF-8"
        if recordFailure { XCTFail(message, file: file, line: line) }
        throw SemanticJSONFailure(description: message)
    }

    let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
    guard !lines.isEmpty else {
        let message = "\(sourceClass): expected at least one NDJSON line"
        if recordFailure { XCTFail(message, file: file, line: line) }
        throw SemanticJSONFailure(description: message)
    }

    return try lines.enumerated().map { index, lineText in
        let lineData = Data(lineText.utf8)
        do {
            let value = try JSONSerialization.jsonObject(with: lineData, options: [.fragmentsAllowed])
            guard let object = value as? [String: Any] else {
                let message = "\(sourceClass): NDJSON line \(index) was not a JSON object"
                if recordFailure { XCTFail(message, file: file, line: line) }
                throw SemanticJSONFailure(description: message)
            }
            return object
        } catch let error as SemanticJSONFailure {
            throw error
        } catch {
            let message = "\(sourceClass): malformed NDJSON line \(index): \(error)"
            if recordFailure { XCTFail(message, file: file, line: line) }
            throw SemanticJSONFailure(description: message)
        }
    }
}

func encodeAndParseMarkers(
    _ markers: [AdMarker],
    sourceClass: String,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> [[String: Any]] {
    let data = try markerNDJSON(from: markers, file: file, line: line)
    let objects = try semanticJSONObjects(fromNDJSON: data, sourceClass: sourceClass, file: file, line: line)
    for object in objects {
        try assertPublicMarkerKeySet(object, sourceClass: sourceClass, file: file, line: line)
    }
    return objects
}

func assertPublicMarkerKeySet(
    _ object: [String: Any],
    sourceClass: String,
    recordFailure: Bool = true,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    let actualKeys = Set(object.keys)
    guard actualKeys == publicAdMarkerKeys else {
        let missing = publicAdMarkerKeys.subtracting(actualKeys).sorted()
        let unexpected = actualKeys.subtracting(publicAdMarkerKeys).sorted()
        let message = "\(sourceClass): marker public key mismatch; missing=\(missing), unexpected=\(unexpected), actual=\(object)"
        if recordFailure { XCTFail(message, file: file, line: line) }
        throw SemanticJSONFailure(description: message)
    }
}

func assertSemanticMarker(
    _ objects: [[String: Any]],
    at index: Int,
    sourceClass: String,
    type: String,
    source: String,
    classification: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard objects.indices.contains(index) else {
        XCTFail("\(sourceClass): missing marker at index \(index); actual count=\(objects.count)", file: file, line: line)
        return
    }

    let object = objects[index]
    XCTAssertEqual(object["Type"] as? String, type, "\(sourceClass) marker[\(index)] Type mismatch: \(object)", file: file, line: line)
    XCTAssertEqual(object["Source"] as? String, source, "\(sourceClass) marker[\(index)] Source mismatch: \(object)", file: file, line: line)
    XCTAssertEqual(object["Classification"] as? String, classification, "\(sourceClass) marker[\(index)] Classification mismatch: \(object)", file: file, line: line)
}

func assertNoTopLevelBreakDurationKeys(
    _ objects: [[String: Any]],
    sourceClass: String,
    recordFailure: Bool = true,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    for (index, object) in objects.enumerated() {
        for key in ["BreakDuration", "breakDuration"] where object.keys.contains(key) {
            let message = "\(sourceClass): marker[\(index)] must not expose top-level \(key): \(object)"
            if recordFailure { XCTFail(message, file: file, line: line) }
            throw SemanticJSONFailure(description: message)
        }
    }
}

func value(at keyPath: String, in object: [String: Any]) -> Any? {
    keyPath.split(separator: ".").reduce(Optional<Any>(object)) { current, key in
        guard let dictionary = current as? [String: Any] else {
            return nil
        }
        return dictionary[String(key)]
    }
}
