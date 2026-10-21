import Foundation
import GRDB

enum LegacyData {
    private static let doneKey = "copiedDirectDownloadData"
    private static let directService = "com.digisensus.recorder"
    private static let databaseFiles = ["recorder.sqlite", "recorder.sqlite-wal", "recorder.sqlite-shm"]
    private static let settingKeys = [
        "onboardingDone", "aiService", "autoRecord", "autoBalance", "removeCrosstalk", "autoTranscribe", "autoSummarize",
        "mic", "source", "showInDock", "digisensusEmail", "digisensusLastEmail", "meetingNamesWanted", "askedSystemAudio",
        "messagesRead", "messagesNotifiedThrough", "messagesCache",
        "transcriptionProvider", "transcriptionPreset", "transcriptionServer", "transcriptionModel", "transcriptionLanguage",
        "summaryProvider", "summaryPreset", "summaryServer", "summaryModel", "serverAddressesAreAPIRoots",
        "agentAccess", "agentReadArchive", "agentControlRecording",
    ]

    static func copyFromDirectDownloadIfNeeded() {
        #if APP_STORE
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        defaults.set(true, forKey: doneKey)
        guard let home = realHome() else { return }
        let support = home.appendingPathComponent("Library/Application Support/Digisensus Recorder")
        guard FileManager.default.fileExists(atPath: support.appendingPathComponent(databaseFiles[0]).path) else { return }
        Log.write("first launch: copying the library and settings of the direct download")
        let settings = copySettings(from: home.appendingPathComponent("Library/Preferences/\(directService).plist"))
        copyLibrary(from: support)
        copyKeys(signedIn: settings["digisensusEmail"] != nil,
                 presets: ["transcription", "summary"].compactMap { purpose in
                     (settings["\(purpose)Preset"] as? String).map { (purpose, $0) }
                 })
        #endif
    }

    private static func realHome() -> URL? {
        guard let entry = getpwuid(getuid()), let path = entry.pointee.pw_dir else { return nil }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }

    private static func copySettings(from plist: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: plist),
              let values = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else { return [:] }
        let defaults = UserDefaults.standard
        var copied: [String: Any] = [:]
        for key in settingKeys {
            guard let value = values[key] else { continue }
            defaults.set(value, forKey: key)
            copied[key] = value
        }
        Log.write("copied \(copied.count) setting(s)")
        return copied
    }

    private static func copyLibrary(from source: URL) {
        let files = FileManager.default
        let target = AppDatabase.folder
        guard !files.fileExists(atPath: target.appendingPathComponent(databaseFiles[0]).path) else { return }
        do {
            try files.createDirectory(at: target, withIntermediateDirectories: true)
            let destination = target.appendingPathComponent(databaseFiles[0])
            do {
                var readOnly = Configuration()
                readOnly.readonly = true
                let live = try DatabaseQueue(path: source.appendingPathComponent(databaseFiles[0]).path, configuration: readOnly)
                try live.backup(to: try DatabaseQueue(path: destination.path))
            } catch {
                Log.write("library snapshot failed, copying the files instead: \(error)")
                for name in databaseFiles { try? files.removeItem(at: target.appendingPathComponent(name)) }
                for name in databaseFiles where files.fileExists(atPath: source.appendingPathComponent(name).path) {
                    try files.copyItem(at: source.appendingPathComponent(name), to: target.appendingPathComponent(name))
                }
            }
            let check = try DatabaseQueue(path: destination.path)
            let verdict = try check.read { try String.fetchOne($0, sql: "PRAGMA quick_check") }
            let recordings = try check.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM recording") } ?? 0
            guard verdict == "ok" else { throw DatabaseError(message: "quick_check: \(verdict ?? "no answer")") }
            Log.write("copied the library: \(recordings) recording(s)")
        } catch {
            Log.write("library copy failed, starting empty: \(error)")
            for name in databaseFiles { try? files.removeItem(at: target.appendingPathComponent(name)) }
        }
    }

    private static func copyKeys(signedIn: Bool, presets: [(purpose: String, preset: String)]) {
        var accounts: [String] = []
        if signedIn { accounts.append("digisensus-device-token") }
        for purpose in ["transcription", "summary"] {
            if let preset = presets.first(where: { $0.purpose == purpose })?.preset {
                accounts.append("\(purpose)-api-key.\(preset)")
            }
            accounts.append("\(purpose)-api-key")
        }
        var copied = 0
        for account in accounts {
            guard let value = Keychain.loginKeychainString(account, service: directService) else { continue }
            Keychain.set(value, for: account)
            copied += 1
        }
        Log.write("copied \(copied) keychain item(s)")
    }
}
