import Foundation

/// Drives a NextDNS profile's denylist/allowlist via the API — ported from nextdns_discipline.c.
/// The API key is fed to `curl` through a stdin config (`-K -`), NEVER argv/env, so it can't appear in
/// `ps`. Callers must already be root (the daemon, or `sudo … domains add`): credentials are 0600 root.
struct NextDNSAPI {
    let apikey: String
    let profile: String

    static let apiBase = "https://api.nextdns.io/profiles/"
    static let curlBin = "/usr/bin/curl"

    /// Load + validate credentials (must be root:0600). Returns nil (with a logged reason) on any problem,
    /// so the daemon skips instead of crashing; CLI callers turn nil into a hard error.
    static func load() -> NextDNSAPI? {
        var st = stat()
        guard stat(Paths.credFile, &st) == 0 else { logLine("credentials: cannot read \(Paths.credFile) (run the installer)"); return nil }
        guard st.st_uid == 0 else { logLine("credentials: \(Paths.credFile) must be owned by root"); return nil }
        guard (st.st_mode & (S_IRWXG | S_IRWXO)) == 0 else { logLine("credentials: \(Paths.credFile) must be chmod 600"); return nil }
        guard let text = try? String(contentsOfFile: Paths.credFile, encoding: .utf8) else { logLine("credentials: cannot open \(Paths.credFile)"); return nil }

        var apikey = "", profile = ""
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let l = String(line)
            if l.hasPrefix("API_KEY=") { apikey = String(l.dropFirst(8)) }
            else if l.hasPrefix("PROFILE=") { profile = String(l.dropFirst(8)) }
        }
        guard !apikey.isEmpty, !profile.isEmpty else { logLine("credentials: missing API_KEY or PROFILE"); return nil }
        guard validProfile(profile) else { logLine("credentials: PROFILE is malformed"); return nil }
        // API key must be printable non-space (no control chars) — same check as the C tool.
        guard apikey.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value != 0x7f }) else { logLine("credentials: API_KEY is malformed"); return nil }
        return NextDNSAPI(apikey: apikey, profile: profile)
    }

    /// One curl call; returns HTTP status (0 on transport failure). Key goes via stdin `-K -`, never argv.
    private func curlCall(_ method: String, _ url: String, body: String?) -> Int {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: NextDNSAPI.curlBin)
        var args = ["-s", "-K", "-", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "20"]
        if method != "GET" { args += ["-X", method] }
        if let b = body { args += ["-d", b] }
        args.append(url)
        p.arguments = args

        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return 0 }

        let cfg = "header = \"X-Api-Key: \(apikey)\"\nheader = \"Content-Type: application/json\"\n"
        inPipe.fileHandleForWriting.write(Data(cfg.utf8))
        try? inPipe.fileHandleForWriting.close()
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Int(String(data: out, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
    }

    private func transient(_ c: Int) -> Bool { c == 0 || c == 429 || (500..<600).contains(c) }

    private func callRetry(_ method: String, _ url: String, body: String?) -> Int {
        var c = 0
        for attempt in 0..<4 {
            c = curlCall(method, url, body: body)
            if !transient(c) { break }
            Thread.sleep(forTimeInterval: Double(attempt + 1))   // 1s, 2s, 3s backoff
        }
        return c
    }

    private func okAdd(_ c: Int) -> Bool { (200..<300).contains(c) || c == 409 }   // 409 = already present

    struct Result { let ok: Bool; let add: Int; let rm: Int }

    /// block <d>: DELETE allowlist/<d> then POST denylist {"id":d,"active":true}. Only ever tightens.
    func block(_ d: String) -> Result {
        let body = "{\"id\":\"\(d)\",\"active\":true}"
        let rm  = callRetry("DELETE", "\(NextDNSAPI.apiBase)\(profile)/allowlist/\(d)", body: nil)
        let add = callRetry("POST",   "\(NextDNSAPI.apiBase)\(profile)/denylist",       body: body)
        return Result(ok: okAdd(add), add: add, rm: rm)
    }

    /// allow <d>: DELETE denylist/<d> then POST allowlist {"id":d,"active":true}. A loosening.
    func allow(_ d: String) -> Result {
        let body = "{\"id\":\"\(d)\",\"active\":true}"
        let rm  = callRetry("DELETE", "\(NextDNSAPI.apiBase)\(profile)/denylist/\(d)", body: nil)
        let add = callRetry("POST",   "\(NextDNSAPI.apiBase)\(profile)/allowlist",     body: body)
        return Result(ok: okAdd(add), add: add, rm: rm)
    }
}
