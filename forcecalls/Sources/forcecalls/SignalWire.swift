import Foundation

/// Places one call through SignalWire's LaML (Twilio-compatible) REST API.
///
/// LEG ORDER: the destination is rung FIRST (`To` = them). Only when they answer does LaML `<Dial>`
/// your SIP endpoint, which baresip auto-answers. So on a night they don't pick up, your desk never
/// rings, and nobody is ever left listening to silence while the other side is still being found.
enum SignalWire {

    struct Result {
        var ok: Bool
        var detail: String   // call SID on success, else the error worth logging
    }

    static func placeCall(creds: Creds, destination: String) -> Result {
        let host = creds.space.hasPrefix("http") ? creds.space : "https://" + creds.space
        guard let url = URL(string: "\(host)/api/laml/2010-04-01/Accounts/\(creds.projectId)/Calls.json") else {
            return Result(ok: false, detail: "bad space URL: \(creds.space)")
        }

        // They answer -> we dial the SIP endpoint and bridge. `timeout` bounds how long baresip has
        // to pick up before we give up, rather than leaving them holding a dead line.
        let laml = "<Response><Dial timeout=\"20\"><Sip>\(xmlEscape(creds.endpoint))</Sip></Dial></Response>"
        let form = [("To", destination), ("From", creds.callerId), ("Twiml", laml)]
            .map { "\($0.0)=\(formEncode($0.1))" }
            .joined(separator: "&")

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        let auth = Data("\(creds.projectId):\(creds.apiToken)".utf8).base64EncodedString()
        req.setValue("Basic \(auth)", forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(form.utf8)

        var result = Result(ok: false, detail: "no response")
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            if let err { result = Result(ok: false, detail: "network: \(err.localizedDescription)"); return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            if (200...299).contains(code) {
                result = Result(ok: true, detail: field("sid", in: body) ?? "queued")
            } else {
                // Surface the API's own message — "not a verified caller id" and friends ARE the
                // diagnosis, and far more useful in the log than a bare status code.
                let msg = field("message", in: body) ?? String(body.prefix(200))
                result = Result(ok: false, detail: "HTTP \(code): \(msg)")
            }
        }.resume()
        _ = sem.wait(timeout: .now() + 35)
        return result
    }

    /// Pull one top-level string field out of a JSON body without modelling the whole response.
    private static func field(_ key: String, in json: String) -> String? {
        guard let d = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        if let s = obj[key] as? String { return s }
        if let n = obj[key] as? NSNumber { return n.stringValue }
        return nil
    }

    private static func formEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
