import XCTest
@testable import MacUtilsCore

final class JSONUsersTests: XCTestCase {
    var dir = ""
    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "ju-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(atPath: dir) }

    struct S: Codable { var a: Int; var b: String }
    struct Lenient: Codable {
        var a: Int; var b: String
        enum CodingKeys: String, CodingKey { case a, b }
        init(a: Int, b: String) { self.a = a; self.b = b }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            a = c.lenient(.a, default: 7); b = c.lenient(.b, default: "dflt")
        }
    }

    func testLenientDecode() throws {
        let missing = try JSONDecoder().decode(Lenient.self, from: Data("{}".utf8))
        XCTAssertEqual(missing.a, 7); XCTAssertEqual(missing.b, "dflt")
        let wrongType = try JSONDecoder().decode(Lenient.self, from: Data(#"{"a":"nope","b":3}"#.utf8))
        XCTAssertEqual(wrongType.a, 7); XCTAssertEqual(wrongType.b, "dflt")
        let good = try JSONDecoder().decode(Lenient.self, from: Data(#"{"a":1,"b":"x"}"#.utf8))
        XCTAssertEqual(good.a, 1); XCTAssertEqual(good.b, "x")
    }

    func testSaveJSONModesAndBytes() throws {
        let p = dir + "/s.json"
        XCTAssertTrue(saveJSON(S(a: 1, b: "x"), to: p))
        XCTAssertEqual(try String(contentsOfFile: p), #"{"a":1,"b":"x"}"#)            // sorted, compact
        XCTAssertTrue(saveJSON(S(a: 1, b: "x"), to: p, pretty: true))
        XCTAssertTrue(try String(contentsOfFile: p).contains("\n"))                     // pretty
        let sec = dir + "/secret.json"
        XCTAssertTrue(saveJSON(S(a: 2, b: "y"), to: sec, mode: 0o600))
        var st = stat(); stat(sec, &st)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)
        let back: S? = loadJSON(sec); XCTAssertEqual(back?.a, 2)
        let nothing: S? = loadJSON(dir + "/missing.json"); XCTAssertNil(nothing)
    }

    func testUsers() {
        XCTAssertEqual(resolveUID("0"), 0)
        XCTAssertEqual(resolveUID("root"), 0)
        XCTAssertEqual(resolveUID(" 0 "), 0)
        XCTAssertNil(resolveUID("")); XCTAssertNil(resolveUID("no-such-user-zz"))
        XCTAssertEqual(userName(for: 0), "root")
        XCTAssertEqual(userName(for: getuid()), NSUserName())
    }

    func testEpochFile() throws {
        let p = dir + "/snooze"
        try EpochFile.write(nil, to: p)
        XCTAssertEqual(try String(contentsOfFile: p), "null"); XCTAssertNil(EpochFile.read(p))
        let d = Date(timeIntervalSince1970: 1234.5)
        try EpochFile.write(d, to: p)
        XCTAssertEqual(EpochFile.read(p), d)
        XCTAssertNil(EpochFile.read(dir + "/none"))
    }
}
