import XCTest
@testable import EverywhereCore

final class NameQueryTests: XCTestCase {
    func testLiteralByteSearchAgreesWithFoundation() {
        let alphabet = Array("aABb01._-\r\n\u{0}".utf8)
        var seed: UInt64 = 42
        for length in 1...96 {
            var bytes: [UInt8] = []
            for _ in 0..<length {
                seed = seed &* 6364136223846793005 &+ 1
                bytes.append(alphabet[Int((seed >> 32) % UInt64(alphabet.count))])
            }
            let name = String(decoding: bytes, as: UTF8.self)
            var needles = ["", "a", "AB", "aaaa", "ABba01", "absent", name, name + "extra"]
            for start in stride(from: 0, to: length, by: 3) {
                needles.append(String(decoding: bytes[start..<min(length, start + 7)], as: UTF8.self))
            }
            for needle in needles {
                for matchCase in [false, true] {
                    for negated in [false, true] {
                        let parsed = ParsedQuery(groups: [ParsedGroup(terms: [ParsedTerm(text: needle, isNegated: negated)])])
                        let query = NameQuery(SearchRequest(matchCase: matchCase), parsed: parsed)
                        let source = matchCase ? name : name.lowercased()
                        let target = matchCase ? needle : needle.lowercased()
                        let found = target.isEmpty || (source as NSString).range(of: target).location != NSNotFound
                        XCTAssertEqual(query.matches(name), negated ? !found : found)
                    }
                }
            }
        }
    }

    func testLongAndOverlappingLiteralTerms() {
        for needle in ["aaaaab", "ababababac", String(repeating: "A", count: 300) + "b"] {
            let query = NameQuery(SearchRequest(text: needle))
            for name in [needle, "prefix" + needle.lowercased() + "suffix", String(repeating: "a", count: 1000),
                         String(repeating: "ab", count: 600), "prefix" + String(needle.dropLast()) + "c"] {
                XCTAssertEqual(query.matches(name), name.lowercased().contains(needle.lowercased()))
            }
        }
    }
}
