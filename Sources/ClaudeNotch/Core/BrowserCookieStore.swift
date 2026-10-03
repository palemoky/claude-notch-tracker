import Foundation
import Security
import CommonCrypto
import SQLite3

/// Reads cookies for a host out of the local browser stores, the way the browser wrote them:
/// Chromium-family stores are AES-encrypted with a Keychain-held "Safe Storage" key, while
/// Firefox/Zen keep them in plaintext. The database is copied first (main file plus its WAL/SHM
/// sidecars) so cookies a currently-running browser hasn't checkpointed yet are still visible.
///
/// Actor-isolated because the derived Safe Storage keys are cached for the process lifetime:
/// reading one can make macOS ask the user to authorize Keychain access, so a denial must be
/// remembered rather than re-asked on every refresh. Shared by Claude and opencode.
actor BrowserCookieReader {
    /// One per process so the derived Safe Storage keys (and denials) are shared: reading a key is
    /// what raises the macOS prompt, and Claude + opencode both read the same browser stores.
    static let shared = BrowserCookieReader()

    struct Source: Sendable {
        let name: String
        let path: URL
        let keychainService: String?   // nil => Firefox-style plaintext cookies.sqlite
    }

    /// nil value = the read failed (typically the user clicked Deny). Cached too, so a denial
    /// doesn't re-prompt on the next cycle; `clearDeniedKeys()` lets Refresh now retry.
    private var keyCache: [String: Data?] = [:]

    func clearDeniedKeys() { keyCache = keyCache.filter { $0.value != nil } }

    /// Candidate session stores, most-likely first. Only those actually present are returned.
    func sources() -> [Source] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let fm = FileManager.default
        func url(_ rel: String) -> URL { home.appendingPathComponent(rel) }
        var out: [Source] = []

        let chromium: [(String, String, String)] = [
            ("Claude Desktop", "Library/Application Support/Claude/Cookies", "Claude Safe Storage"),
            ("Chrome", "Library/Application Support/Google/Chrome/Default/Cookies", "Chrome Safe Storage"),
            ("Brave", "Library/Application Support/BraveSoftware/Brave-Browser/Default/Cookies", "Brave Safe Storage"),
            ("Edge", "Library/Application Support/Microsoft Edge/Default/Cookies", "Microsoft Edge Safe Storage"),
            ("Arc", "Library/Application Support/Arc/User Data/Default/Cookies", "Arc Safe Storage"),
        ]
        for (name, rel, svc) in chromium {
            let u = url(rel)
            if fm.fileExists(atPath: u.path) { out.append(Source(name: name, path: u, keychainService: svc)) }
        }

        for (name, base) in [("Firefox", "Library/Application Support/Firefox/Profiles"),
                             ("Zen", "Library/Application Support/zen/Profiles")] {
            let dir = url(base)
            if let profiles = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                for prof in profiles {
                    let ck = prof.appendingPathComponent("cookies.sqlite")
                    if fm.fileExists(atPath: ck.path) {
                        out.append(Source(name: name, path: ck, keychainService: nil))
                    }
                }
            }
        }
        return out
    }

    /// Cookies for `host` (and its `.host` domain variant), or nil if the store can't be read.
    func readCookies(from source: Source, host: String) -> [String: String]? {
        let fm = FileManager.default
        let suffixes = ["", "-wal", "-shm"]
        let base = fm.temporaryDirectory
            .appendingPathComponent("cn-\(abs(source.path.path.hashValue))-\(getpid()).sqlite")
        // Copy the main DB *and* its WAL/SHM sidecars, so cookies written by a currently-running
        // app/browser (which live in the -wal file until checkpoint) are included.
        var copiedMain = false
        for s in suffixes {
            let from = URL(fileURLWithPath: source.path.path + s)
            let to = URL(fileURLWithPath: base.path + s)
            try? fm.removeItem(at: to)
            if (try? fm.copyItem(at: from, to: to)) != nil {
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: to.path)
                if s.isEmpty { copiedMain = true }
            }
        }
        guard copiedMain else { return nil }
        defer { for s in suffixes { try? fm.removeItem(at: URL(fileURLWithPath: base.path + s)) } }

        // Read-WRITE open on the *copy* lets SQLite apply the WAL, so we see the latest cookies.
        var db: OpaquePointer?
        guard sqlite3_open(base.path, &db) == SQLITE_OK, let handle = db else {
            if db != nil { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(handle) }
        if let service = source.keychainService {
            return readChromium(handle, service: service, host: host)
        } else {
            return readFirefox(handle, host: host)
        }
    }

    private func readChromium(_ db: OpaquePointer, service: String, host: String) -> [String: String]? {
        guard let key = safeStorageKey(service: service) else { return nil }
        var stmt: OpaquePointer?
        let sql = "SELECT name, encrypted_value FROM cookies WHERE host_key IN (?, ?)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, host, -1, transient)
        sqlite3_bind_text(stmt, 2, "." + host, -1, transient)
        var out: [String: String] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cName = sqlite3_column_text(stmt, 0), let blob = sqlite3_column_blob(stmt, 1)
            else { continue }
            let name = String(cString: cName)
            let enc = Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 1)))
            if let val = decrypt(enc, key: key) { out[name] = val }
        }
        return out.isEmpty ? nil : out
    }

    private func readFirefox(_ db: OpaquePointer, host: String) -> [String: String]? {
        var stmt: OpaquePointer?
        let sql = "SELECT name, value FROM moz_cookies WHERE host IN (?, ?)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, host, -1, transient)
        sqlite3_bind_text(stmt, 2, "." + host, -1, transient)
        var out: [String: String] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cName = sqlite3_column_text(stmt, 0), let cVal = sqlite3_column_text(stmt, 1)
            else { continue }
            out[String(cString: cName)] = String(cString: cVal)   // Firefox stores plaintext
        }
        return out.isEmpty ? nil : out
    }

    /// AES key = PBKDF2(SHA1, "<App> Safe Storage" password, "saltysalt", 1003, 16).
    ///
    /// Cached per service for the process lifetime: this is the call that can raise the macOS
    /// "wants to use your confidential information stored in …" prompt, so it must not run on
    /// every refresh. A denial is also remembered (as a backoff on the owning source) so the
    /// user isn't asked again a minute later.
    private func safeStorageKey(service: String) -> Data? {
        if let cached = keyCache[service] { return cached }   // includes a cached denial (nil)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let pw = item as? Data else {
            keyCache[service] = Data?.none   // denied or missing: don't ask again this launch
            return nil
        }
        var key = Data(count: 16)
        let salt = Array("saltysalt".utf8)
        let ok = key.withUnsafeMutableBytes { kb in
            pw.withUnsafeBytes { pb in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                    pb.baseAddress!.assumingMemoryBound(to: Int8.self), pw.count,
                    salt, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                    kb.baseAddress!.assumingMemoryBound(to: UInt8.self), 16)
            }
        }
        guard ok == kCCSuccess else { keyCache[service] = Data?.none; return nil }
        keyCache[service] = key
        return key
    }

    /// Chromium "v10" AES-128-CBC (IV = 16 × 0x20). Newer builds prepend a 32-byte
    /// domain hash inside the plaintext; try with and without.
    private func decrypt(_ enc: Data, key: Data) -> String? {
        guard enc.count > 3, enc.prefix(3) == Data("v10".utf8) else {
            return String(data: enc, encoding: .utf8)
        }
        let ct = enc.dropFirst(3)
        let iv = Data(repeating: 0x20, count: 16)
        var out = Data(count: ct.count + kCCBlockSizeAES128)
        var moved = 0
        let status = out.withUnsafeMutableBytes { ob in
            ct.withUnsafeBytes { cb in key.withUnsafeBytes { kb in iv.withUnsafeBytes { ib in
                CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        kb.baseAddress, 16, ib.baseAddress,
                        cb.baseAddress, ct.count,
                        ob.baseAddress, ob.count, &moved)
            }}}
        }
        guard status == kCCSuccess else { return nil }
        let total = out.count
        out.removeSubrange(moved..<total)
        if let s = String(data: out, encoding: .utf8) { return s }
        if out.count > 32, let s = String(data: out.dropFirst(32), encoding: .utf8) { return s }
        return nil
    }
}
