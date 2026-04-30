import Foundation
import XCTest

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
