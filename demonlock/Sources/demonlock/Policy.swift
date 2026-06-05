import Foundation

// MARK: - Three-valued (Kleene) logic

enum Tri: Equatable {
    case t, f, unknown
    var bool: Bool? { switch self { case .t: return true; case .f: return false; case .unknown: return nil } }
}
private func triAnd(_ xs: [Tri]) -> Tri { xs.contains(.f) ? .f : (xs.contains(.unknown) ? .unknown : .t) }
private func triOr(_ xs: [Tri]) -> Tri { xs.contains(.t) ? .t : (xs.contains(.unknown) ? .unknown : .f) }
private func triNot(_ x: Tri) -> Tri { switch x { case .t: return .f; case .f: return .t; case .unknown: return .unknown } }

// MARK: - AST

indirect enum Policy {
    case and([Policy])
    case or([Policy])
    case not(Policy)
    case locatedInAny([String])         // zone names
    case foundInNearbyBSSID([String])   // normalized lowercase MACs
    case timeIsAny([TimeWindow])
}

struct TimeWindow {
    var days: Set<Int>      // 1=Mon … 7=Sun
    var startMin: Int       // 0…1440
    var endMin: Int         // 0…1440, start < end
    var raw: String

    /// True iff `date` falls in any window; also returns a human "now" description.
    static func matches(_ windows: [TimeWindow], at date: Date) -> (Bool, String) {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        let c = cal.dateComponents([.weekday, .hour, .minute], from: date)
        let wd = c.weekday ?? 1                       // 1=Sun … 7=Sat
        let day = (wd == 1) ? 7 : (wd - 1)            // → 1=Mon … 7=Sun
        let nowMin = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        let names = ["", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        let nowDesc = String(format: "%@ %02d:%02d", names[day], c.hour ?? 0, c.minute ?? 0)
        for w in windows where w.days.contains(day) && nowMin >= w.startMin && nowMin < w.endMin {
            return (true, "\(nowDesc) ∈ \(w.raw)")
        }
        return (false, "\(nowDesc) ∉ any window")
    }
}

// MARK: - Inputs

struct PolicyInputs {
    var now: Date
    var fix: (lat: Double, lon: Double, accuracy: Double)?   // nil ⇒ unknown
    var bssids: Set<String>?                                 // nil ⇒ unknown (normalized lowercase)
    var zones: [Zone]
}

// MARK: - Errors

struct PolicyError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

// MARK: - Engine (parse / evaluate / validate)

enum PolicyEngine {

    static func parse(_ s: String) throws -> Policy {
        let p = Parser(try tokenize(s))
        return try p.parse()
    }

    /// Three-valued evaluation → (verdict, annotated tree).
    static func evaluate(_ p: Policy, _ inp: PolicyInputs) -> (Tri, EvalNode) {
        switch p {
        case .and(let subs):
            let kids = subs.map { evaluate($0, inp) }
            let r = triAnd(kids.map(\.0))
            return (r, EvalNode(kind: "AND", label: "AND", result: r.bool, children: kids.map(\.1)))
        case .or(let subs):
            let kids = subs.map { evaluate($0, inp) }
            let r = triOr(kids.map(\.0))
            return (r, EvalNode(kind: "OR", label: "OR", result: r.bool, children: kids.map(\.1)))
        case .not(let sub):
            let (cr, cn) = evaluate(sub, inp)
            let r = triNot(cr)
            return (r, EvalNode(kind: "NOT", label: "NOT", result: r.bool, children: [cn]))

        case .locatedInAny(let names):
            let label = "LOCATED_IN_ANY([\(names.map { "\"\($0)\"" }.joined(separator: ", "))])"
            guard let fix = inp.fix else {
                return (.unknown, EvalNode(kind: "LOCATED_IN_ANY", label: label, result: nil, detail: "no location fix"))
            }
            let inside = ZoneStore.containing(lat: fix.lat, lon: fix.lon, accuracy: fix.accuracy, zones: inp.zones)
            let match = names.first { inside.contains($0) }
            let r: Tri = match != nil ? .t : .f
            let detail = match.map { "inside \"\($0)\"" }
                ?? (inside.isEmpty ? "outside all zones" : "inside \(inside) (not in the listed set)")
            return (r, EvalNode(kind: "LOCATED_IN_ANY", label: label, result: r.bool, detail: detail))

        case .foundInNearbyBSSID(let macs):
            let label = "FOUND_IN_NEARBY_BSSID([\(macs.count) AP\(macs.count == 1 ? "" : "s")])"
            guard let seen = inp.bssids else {
                return (.unknown, EvalNode(kind: "FOUND_IN_NEARBY_BSSID", label: label, result: nil, detail: "no Wi-Fi scan"))
            }
            let hit = macs.first { seen.contains($0) }
            let r: Tri = hit != nil ? .t : .f
            let detail = hit.map { "saw \($0)" } ?? "none of \(macs.count) pinned AP(s) visible"
            return (r, EvalNode(kind: "FOUND_IN_NEARBY_BSSID", label: label, result: r.bool, detail: detail))

        case .timeIsAny(let windows):
            let label = "TIME_IS_ANY([\(windows.map(\.raw).joined(separator: ", "))])"
            let (match, nowDesc) = TimeWindow.matches(windows, at: inp.now)
            let r: Tri = match ? .t : .f
            return (r, EvalNode(kind: "TIME_IS_ANY", label: label, result: r.bool, detail: nowDesc))
        }
    }

    /// For `setpolicy`: parse and confirm every referenced zone exists. Throws PolicyError on any problem.
    @discardableResult
    static func validate(_ s: String, zones: [Zone]) throws -> Policy {
        let p = try parse(s)
        var missing: [String] = []
        func walk(_ p: Policy) {
            switch p {
            case .and(let a), .or(let a): a.forEach(walk)
            case .not(let n): walk(n)
            case .locatedInAny(let names):
                for n in names where !ZoneStore.hasZone(named: n, in: zones) { missing.append(n) }
            case .foundInNearbyBSSID, .timeIsAny: break
            }
        }
        walk(p)
        if !missing.isEmpty {
            let uniq = Set(missing).sorted().map { "\"\($0)\"" }.joined(separator: ", ")
            throw PolicyError(message: "policy references unknown zone(s): \(uniq). Create them with `demonlock edit-zones` first.")
        }
        return p
    }
}

// MARK: - Tokenizer

private enum Tok: Equatable {
    case lparen, rparen, lbracket, rbracket, comma
    case str(String)    // quoted
    case word(String)   // bareword: keyword / function / MAC / window / unquoted name
}

private func tokenize(_ s: String) throws -> [Tok] {
    var toks: [Tok] = []
    let chars = Array(s)
    var i = 0
    func isPunct(_ c: Character) -> Bool { "()[],".contains(c) }
    while i < chars.count {
        let c = chars[i]
        if c.isWhitespace { i += 1; continue }
        switch c {
        case "(": toks.append(.lparen); i += 1
        case ")": toks.append(.rparen); i += 1
        case "[": toks.append(.lbracket); i += 1
        case "]": toks.append(.rbracket); i += 1
        case ",": toks.append(.comma); i += 1
        case "\"":
            i += 1
            var str = ""
            while i < chars.count, chars[i] != "\"" { str.append(chars[i]); i += 1 }
            guard i < chars.count else { throw PolicyError(message: "unterminated string literal") }
            i += 1
            toks.append(.str(str))
        default:
            var w = ""
            while i < chars.count, !chars[i].isWhitespace, !isPunct(chars[i]), chars[i] != "\"" {
                w.append(chars[i]); i += 1
            }
            toks.append(.word(w))
        }
    }
    return toks
}

// MARK: - Parser (recursive descent)

private final class Parser {
    private let toks: [Tok]
    private var i = 0
    init(_ toks: [Tok]) { self.toks = toks }

    private func peek() -> Tok? { i < toks.count ? toks[i] : nil }
    private func isWord(_ kw: String) -> Bool {
        if case .word(let w)? = peek(), w.uppercased() == kw { return true }; return false
    }
    private func expect(_ t: Tok, _ what: String) throws {
        guard peek() == t else { throw PolicyError(message: "expected \(what)") }
        i += 1
    }

    func parse() throws -> Policy {
        guard !toks.isEmpty else { throw PolicyError(message: "empty policy") }
        let e = try orExpr()
        guard i == toks.count else { throw PolicyError(message: "unexpected text after a complete expression") }
        return e
    }

    private func orExpr() throws -> Policy {
        var nodes = [try andExpr()]
        while isWord("OR") { i += 1; nodes.append(try andExpr()) }
        return nodes.count == 1 ? nodes[0] : .or(nodes)
    }
    private func andExpr() throws -> Policy {
        var nodes = [try notExpr()]
        while isWord("AND") { i += 1; nodes.append(try notExpr()) }
        return nodes.count == 1 ? nodes[0] : .and(nodes)
    }
    private func notExpr() throws -> Policy {
        if isWord("NOT") { i += 1; return .not(try notExpr()) }
        return try primary()
    }
    private func primary() throws -> Policy {
        guard let t = peek() else { throw PolicyError(message: "unexpected end of policy") }
        if t == .lparen {
            i += 1
            let e = try orExpr()
            try expect(.rparen, "')'")
            return e
        }
        guard case .word(let w) = t else { throw PolicyError(message: "expected a function call or '('") }
        i += 1
        try expect(.lparen, "'(' after \(w)")
        let items = try list()
        try expect(.rparen, "')'")
        switch w.uppercased() {
        case "LOCATED_IN_ANY":
            let names = try items.map { try asString($0) }
            guard !names.isEmpty else { throw PolicyError(message: "LOCATED_IN_ANY needs at least one zone name") }
            return .locatedInAny(names)
        case "FOUND_IN_NEARBY_BSSID":
            let macs = try items.map { try normMAC($0) }
            guard !macs.isEmpty else { throw PolicyError(message: "FOUND_IN_NEARBY_BSSID needs at least one BSSID") }
            return .foundInNearbyBSSID(macs)
        case "TIME_IS_ANY":
            let windows = try items.map { try parseWindow($0) }
            guard !windows.isEmpty else { throw PolicyError(message: "TIME_IS_ANY needs at least one window") }
            return .timeIsAny(windows)
        default:
            throw PolicyError(message: "unknown function '\(w)' — use LOCATED_IN_ANY, FOUND_IN_NEARBY_BSSID, or TIME_IS_ANY")
        }
    }
    private func list() throws -> [Tok] {
        try expect(.lbracket, "'['")
        var items: [Tok] = []
        if peek() == .rbracket { i += 1; return items }
        while true {
            guard let t = peek() else { throw PolicyError(message: "unterminated list (missing ']')") }
            switch t {
            case .str, .word: items.append(t); i += 1
            default: throw PolicyError(message: "expected a quoted name, BSSID, or time window inside [ ]")
            }
            if peek() == .comma { i += 1; continue }
            break
        }
        try expect(.rbracket, "']'")
        return items
    }

    private func asString(_ t: Tok) throws -> String {
        switch t { case .str(let s): return s; case .word(let w): return w
        default: throw PolicyError(message: "expected a name") }
    }
    private func normMAC(_ t: Tok) throws -> String {
        let original = try asString(t)
        let raw = original.lowercased().replacingOccurrences(of: "-", with: ":")
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6, parts.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isHexDigit) }) else {
            throw PolicyError(message: "invalid BSSID '\(original)' (expected aa:bb:cc:dd:ee:ff)")
        }
        return parts.joined(separator: ":")
    }
    private func parseWindow(_ t: Tok) throws -> TimeWindow {
        let raw = try asString(t).uppercased()
        let dayMap: [Character: Int] = ["M": 1, "T": 2, "W": 3, "R": 4, "F": 5, "S": 6, "U": 7]
        var idx = raw.startIndex
        var days = Set<Int>()
        if raw.first == "*" {
            days = Set(1...7); idx = raw.index(after: idx)
        } else {
            while idx < raw.endIndex, let d = dayMap[raw[idx]] { days.insert(d); idx = raw.index(after: idx) }
        }
        guard !days.isEmpty else {
            throw PolicyError(message: "time window '\(raw)' must start with day letters (M,T,W,R,F,S,U) or *")
        }
        let parts = raw[idx...].split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]) else {
            throw PolicyError(message: "time window '\(raw)' must be <days>HHMM-HHMM, e.g. M0900-1700")
        }
        let sm = try hhmmToMin(a, raw), em = try hhmmToMin(b, raw)
        guard sm < em else {
            throw PolicyError(message: "time window '\(raw)': start must be before end (no midnight wrap — split into two windows)")
        }
        return TimeWindow(days: days, startMin: sm, endMin: em, raw: raw)
    }
    private func hhmmToMin(_ v: Int, _ raw: String) throws -> Int {
        let h = v / 100, m = v % 100
        guard v >= 0, v <= 2400, m < 60, h <= 24, !(h == 24 && m != 0) else {
            throw PolicyError(message: "time window '\(raw)': \(String(format: "%04d", v)) is not a valid HHMM (0000–2400)")
        }
        return h * 60 + m
    }
}

// MARK: - Text rendering (for `status`)

extension EvalNode {
    func asText(indent: Int = 0) -> String {
        let mark = result == nil ? "·" : (result! ? "✓" : "✗")
        let pad = String(repeating: "  ", count: indent)
        var out = "\(pad)\(mark) \(label)"
        if let d = detail { out += "  — \(d)" }
        out += "\n"
        for c in children { out += c.asText(indent: indent + 1) }
        return out
    }
}
