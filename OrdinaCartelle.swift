import SwiftUI
import ImageIO
import AppKit
import UniformTypeIdentifiers
import QuickLookUI
import QuickLookThumbnailing
import CryptoKit
import AVFoundation

// MARK: - Modello

struct PlannedMove: Identifiable {
    let id = UUID()
    let source: URL
    let dest: URL
    /// Se il file è un doppione esatto, l'originale che resta al suo posto.
    var duplicateOf: URL? = nil
}

struct UndoLog: Codable {
    let root: String
    let pairs: [[String]]  // [origine, destinazione]
}

// MARK: - Impostazioni

enum Part: String, CaseIterable, Identifiable {
    case year, quarter, month, yearMonth, day, ext, type
    var id: String { rawValue }
    var title: String {
        switch self {
        case .year: return "Anno"
        case .quarter: return "Trimestre"
        case .month: return "Mese"
        case .yearMonth: return "Anno e mese"
        case .day: return "Giorno"
        case .ext: return "Estensione"
        case .type: return "Tipo"
        }
    }
    /// Come appare il nome della cartella, per aiutare la scelta.
    var example: String {
        switch self {
        case .year: return "2026"
        case .quarter: return "4° trimestre"
        case .month: return "10-Ottobre"
        case .yearMonth: return "2026-10"
        case .day: return "27"
        case .ext: return "JPG"
        case .type: return "Immagini"
        }
    }
}

enum Layout: String, CaseIterable, Identifiable {
    case yearMonthType, typeYearMonth, yearType, yearMonth, yearMonthDay, yearMonthDayType, year, type
    var id: String { rawValue }
    var parts: [Part] {
        switch self {
        case .yearMonthType: return [.year, .month, .type]
        case .typeYearMonth: return [.type, .year, .month]
        case .yearType: return [.year, .type]
        case .yearMonth: return [.year, .month]
        case .yearMonthDay: return [.year, .month, .day]
        case .yearMonthDayType: return [.year, .month, .day, .type]
        case .year: return [.year]
        case .type: return [.type]
        }
    }
    var title: String {
        Prefs.title(of: parts)
    }
}

enum DateSource: String, CaseIterable, Identifiable {
    case exifThenCreation, creation, modification
    var id: String { rawValue }
    var title: String {
        switch self {
        case .exifThenCreation: return "Data di scatto per le foto, altrimenti creazione"
        case .creation: return "Data di creazione"
        case .modification: return "Data di ultima modifica"
        }
    }
}

enum MonthStyle: String, CaseIterable, Identifiable {
    case numberName, number, name
    var id: String { rawValue }
    var title: String {
        switch self { case .numberName: return "10-Ottobre"; case .number: return "10"; case .name: return "Ottobre" }
    }
}

struct Prefs: Equatable {
    var parts: [Part] = Layout.yearMonthType.parts
    var dateSource: DateSource = .exifThenCreation
    var monthStyle: MonthStyle = .numberName
    var leaveUnknownInPlace = false
    var excludedExts: Set<String> = []
    var minAgeDays = 0
    var moveDuplicates = true

    static var current: Prefs {
        let d = UserDefaults.standard
        var s = Prefs()
        s.parts = resolveParts(layoutParts: d.string(forKey: "layoutParts") ?? "", legacy: d.string(forKey: "layout") ?? "")
        s.dateSource = DateSource(rawValue: d.string(forKey: "dateSource") ?? "") ?? .exifThenCreation
        s.monthStyle = MonthStyle(rawValue: d.string(forKey: "monthStyle") ?? "") ?? .numberName
        s.leaveUnknownInPlace = d.bool(forKey: "leaveUnknownInPlace")
        s.minAgeDays = d.integer(forKey: "minAgeDays")
        s.moveDuplicates = d.object(forKey: "moveDuplicates") as? Bool ?? true
        s.excludedExts = Set((d.string(forKey: "excludedExts") ?? "").lowercased()
            .split(whereSeparator: { $0 == "," || $0 == " " })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { !$0.isEmpty })
        return s
    }

    /// La struttura è salvata come elenco ("year,month,type"); le versioni precedenti usavano un modello fisso ("layout").
    static func parseParts(_ s: String) -> [Part]? {
        let p = s.split(separator: ",").compactMap { Part(rawValue: String($0)) }
        return p.isEmpty ? nil : p
    }

    static func resolveParts(layoutParts: String, legacy: String) -> [Part] {
        parseParts(layoutParts) ?? Layout(rawValue: legacy)?.parts ?? Layout.yearMonthType.parts
    }

    static func title(of parts: [Part]) -> String { parts.map(\.title).joined(separator: " / ") }

    func folderComponents(year: Int, month: Int, day: Int, type: String, ext: String) -> [String] {
        parts.map { part in
            switch part {
            case .year: return String(year)
            case .day: return String(format: "%02d", day)
            case .type: return type
            case .quarter: return "\((month - 1) / 3 + 1)° trimestre"
            case .yearMonth: return String(format: "%d-%02d", year, month)
            case .ext: return ext.isEmpty ? "Senza estensione" : ext.uppercased()
            case .month:
                let name = Organizer.months[month - 1]
                switch monthStyle {
                case .numberName: return String(format: "%02d-%@", month, name)
                case .number: return String(format: "%02d", month)
                case .name: return name
                }
            }
        }
    }

    var examplePath: String {
        (folderComponents(year: 2026, month: 10, day: 27, type: "Immagini", ext: "jpg") + ["foto.jpg"]).joined(separator: "/")
    }
}

// MARK: - Doppioni

/// Riconosce i file davvero identici. Un file è un doppione solo se passa tutti i controlli:
/// stessa dimensione → stessa impronta di inizio e fine → stessa impronta SHA-256 dell'intero contenuto
/// → confronto finale byte per byte. Un file vuoto o lo stesso file (collegamento fisico) non conta mai.
enum Duplicates {
    private static let chunk = 1 << 20

    /// Gruppi di file con contenuto identico (almeno due per gruppo).
    static func groups(_ files: [(url: URL, size: Int64)], isCancelled: () -> Bool = { false },
                       progress: (_ done: Int, _ total: Int) -> Void = { _, _ in }) -> [[URL]] {
        var result: [[URL]] = []
        let candidates = Dictionary(grouping: files.filter { $0.size > 0 }, by: \.size).filter { $0.value.count > 1 }
        var done = 0
        for (_, sameSize) in candidates {
            if isCancelled() { break }
            done += 1
            progress(done, candidates.count)
            let distinct = withoutLinks(sameSize.map(\.url))
            guard distinct.count > 1 else { continue }
            let size = sameSize[0].size
            for (_, quick) in Dictionary(grouping: distinct, by: { quickHash($0, size: size) }) where quick.count > 1 {
                for (_, full) in Dictionary(grouping: quick, by: { fullHash($0) }) where full.count > 1 {
                    // Conferma finale: nessun dubbio possibile sull'identità dei contenuti.
                    var clusters: [[URL]] = []
                    for u in full {
                        if let i = clusters.firstIndex(where: { sameBytes($0[0], u) }) { clusters[i].append(u) }
                        else { clusters.append([u]) }
                    }
                    result += clusters.filter { $0.count > 1 }
                }
            }
        }
        return result
    }

    /// Scarta i percorsi che puntano allo stesso file sul disco (collegamenti fisici).
    private static func withoutLinks(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { u in
            var st = stat()
            guard stat(u.path, &st) == 0 else { return false }
            return seen.insert("\(st.st_dev)-\(st.st_ino)").inserted
        }
    }

    private static func quickHash(_ url: URL, size: Int64) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var sha = SHA256()
        let edge = 64 * 1024
        guard let head = try? h.read(upToCount: edge) else { return nil }
        sha.update(data: head)
        if size > Int64(edge * 2) {
            try? h.seek(toOffset: UInt64(size) - UInt64(edge))
            if let tail = try? h.read(upToCount: edge) { sha.update(data: tail) }
        }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func fullHash(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var sha = SHA256()
        while true {
            let done: Bool = autoreleasepool {
                guard let d = try? h.read(upToCount: chunk), !d.isEmpty else { return true }
                sha.update(data: d)
                return false
            }
            if done { break }
        }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func sameBytes(_ a: URL, _ b: URL) -> Bool {
        guard let x = try? FileHandle(forReadingFrom: a), let y = try? FileHandle(forReadingFrom: b) else { return false }
        defer { try? x.close(); try? y.close() }
        while true {
            let step: Bool? = autoreleasepool {
                let dx = (try? x.read(upToCount: chunk)) ?? Data()
                let dy = (try? y.read(upToCount: chunk)) ?? Data()
                if dx != dy { return false }
                return dx.isEmpty ? true : nil
            }
            if let r = step { return r }
        }
    }
}

// MARK: - Logica di ordinamento

enum Organizer {
    static let months = ["Gennaio", "Febbraio", "Marzo", "Aprile", "Maggio", "Giugno",
                         "Luglio", "Agosto", "Settembre", "Ottobre", "Novembre", "Dicembre"]

    static let categories: [(name: String, exts: Set<String>)] = [
        ("Immagini", ["jpg", "jpeg", "png", "gif", "heic", "heif", "tiff", "tif", "bmp", "webp",
                      "raw", "cr2", "cr3", "nef", "arw", "dng", "svg"]),
        ("Design", ["psd", "ai", "sketch", "fig", "xd", "indd", "afdesign", "afphoto"]),
        ("Font", ["ttf", "otf", "woff", "woff2"]),
        ("3D", ["stl", "obj", "fbx", "blend", "3mf", "usdz"]),
        ("Ebook", ["epub", "mobi", "azw3"]),
        ("Video", ["mp4", "mov", "m4v", "avi", "mkv", "wmv", "webm", "mpg", "mpeg"]),
        ("Audio", ["mp3", "wav", "aac", "m4a", "flac", "aiff", "aif", "ogg", "wma"]),
        ("Documenti", ["pdf", "doc", "docx", "txt", "rtf", "pages", "odt", "md"]),
        ("Fogli e Presentazioni", ["xls", "xlsx", "numbers", "csv", "ods", "ppt", "pptx", "key", "odp"]),
        ("Archivi", ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "dmg", "iso", "pkg"]),
        ("Codice", ["py", "js", "ts", "tsx", "jsx", "html", "css", "json", "swift", "java", "c", "cpp",
                    "h", "sh", "rb", "go", "rs", "php", "sql", "xml", "yml", "yaml"]),
    ]

    static let photoExts: Set<String> = ["jpg", "jpeg", "heic", "heif", "tiff", "tif", "dng",
                                         "cr2", "cr3", "nef", "arw"]

    /// Download non completati: non vengono mai toccati.
    static let partialExts: Set<String> = ["crdownload", "download", "part", "partial", "tmp", "opdownload"]

    static func category(for url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        return categories.first { $0.exts.contains(ext) }?.name
    }

    static func date(for url: URL, source: DateSource) -> Date {
        let v = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        let created = v?.creationDate, modified = v?.contentModificationDate
        switch source {
        case .exifThenCreation:
            if photoExts.contains(url.pathExtension.lowercased()), let d = exifDate(url) { return d }
            return created ?? modified ?? Date()
        case .creation: return created ?? modified ?? Date()
        case .modification: return modified ?? created ?? Date()
        }
    }

    static func exifDate(_ url: URL) -> Date? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f.date(from: s)
    }

    /// Cartella (dentro quella da ordinare) dove vanno i doppioni esatti.
    static let duplicatesFolder = "Duplicati"

    static func plan(root: URL, recursive: Bool, settings: Prefs) -> [PlannedMove] {
        let fm = FileManager.default
        var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        if !recursive { options.insert(.skipsSubdirectoryDescendants) }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isPackageKey, .contentModificationDateKey, .fileSizeKey]
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: options) else { return [] }
        let cal = Calendar.current

        struct Entry { let url: URL; let dir: URL; let size: Int64; let modified: Date }
        var entries: [Entry] = []

        for case let url as URL in en {
            let v = try? url.resourceValues(forKeys: Set(keys))
            guard v?.isRegularFile == true, v?.isPackage != true else { continue }

            let ext = url.pathExtension.lowercased()
            if partialExts.contains(ext) || settings.excludedExts.contains(ext) { continue }
            if settings.minAgeDays > 0, let m = v?.contentModificationDate,
               Date().timeIntervalSince(m) < Double(settings.minAgeDays) * 86400 { continue }
            let cat = category(for: url)
            if cat == nil && settings.leaveUnknownInPlace { continue }

            let d = date(for: url, source: settings.dateSource)
            let comps = settings.folderComponents(year: cal.component(.year, from: d),
                                                  month: cal.component(.month, from: d),
                                                  day: cal.component(.day, from: d),
                                                  type: cat ?? "Altro",
                                                  ext: ext)
            let dir = comps.reduce(root) { $0.appendingPathComponent($1) }
            entries.append(Entry(url: url, dir: dir, size: Int64(v?.fileSize ?? 0),
                                 modified: v?.contentModificationDate ?? .distantFuture))
        }

        // Doppioni esatti: di ogni gruppo resta un originale, gli altri vanno in "Duplicati".
        let dupDir = root.appendingPathComponent(duplicatesFolder).standardizedFileURL
        var originalOf: [String: URL] = [:]
        if settings.moveDuplicates {
            let byPath = Dictionary(entries.map { ($0.url.path, $0) }, uniquingKeysWith: { a, _ in a })
            for group in Duplicates.groups(entries.map { ($0.url, $0.size) }) {
                let ranked = group.compactMap { byPath[$0.path] }.sorted { a, b in
                    func key(_ e: Entry) -> (Int, Int, Date, Int, String) {
                        let inDup = e.url.deletingLastPathComponent().standardizedFileURL == dupDir
                        let inPlace = e.url.deletingLastPathComponent().standardizedFileURL == e.dir.standardizedFileURL
                        return (inDup ? 1 : 0, inPlace ? 0 : 1, e.modified, e.url.path.count, e.url.path)
                    }
                    let x = key(a), y = key(b)
                    if x.0 != y.0 { return x.0 < y.0 }
                    if x.1 != y.1 { return x.1 < y.1 }
                    if x.2 != y.2 { return x.2 < y.2 }
                    if x.3 != y.3 { return x.3 < y.3 }
                    return x.4 < y.4
                }
                guard let keep = ranked.first else { continue }
                for e in ranked.dropFirst() { originalOf[e.url.path] = keep.url }
            }
        }

        var used = Set<String>()
        var moves: [PlannedMove] = []
        for e in entries {
            let original = originalOf[e.url.path]
            let dir = original == nil ? e.dir : dupDir
            if e.url.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL { continue }
            let dest = uniqueDestination(dir: dir, name: e.url.lastPathComponent, used: &used)
            moves.append(PlannedMove(source: e.url, dest: dest, duplicateOf: original))
        }
        return moves.sorted { $0.dest.path.localizedStandardCompare($1.dest.path) == .orderedAscending }
    }

    static func uniqueDestination(dir: URL, name: String, used: inout Set<String>) -> URL {
        let fm = FileManager.default
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = dir.appendingPathComponent(name)
        var n = 1
        while used.contains(candidate.path) || fm.fileExists(atPath: candidate.path) {
            let newName = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            candidate = dir.appendingPathComponent(newName)
            n += 1
        }
        used.insert(candidate.path)
        return candidate
    }

    // MARK: Applica / annulla

    static var logURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OrdinaCartelle")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ultima-operazione.json")
    }

    static func loadLog() -> UndoLog? {
        guard let data = try? Data(contentsOf: logURL) else { return nil }
        return try? JSONDecoder().decode(UndoLog.self, from: data)
    }

    static func apply(_ moves: [PlannedMove], root: URL) -> (done: Int, failed: Int) {
        let fm = FileManager.default
        var pairs: [[String]] = []
        var failed = 0
        for m in moves {
            do {
                try fm.createDirectory(at: m.dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: m.source, to: m.dest)
                pairs.append([m.source.path, m.dest.path])
            } catch {
                failed += 1
            }
        }
        let log = UndoLog(root: root.path, pairs: pairs)
        if let data = try? JSONEncoder().encode(log) { try? data.write(to: logURL) }
        return (pairs.count, failed)
    }

    static func undo(_ log: UndoLog) -> (restored: Int, failed: Int) {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: log.root).standardizedFileURL
        var restored = 0, failed = 0
        for pair in log.pairs.reversed() {
            let src = URL(fileURLWithPath: pair[0]), dest = URL(fileURLWithPath: pair[1])
            guard fm.fileExists(atPath: dest.path), !fm.fileExists(atPath: src.path) else { failed += 1; continue }
            do {
                try fm.createDirectory(at: src.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: dest, to: src)
                restored += 1
            } catch { failed += 1 }
        }
        // Rimuove le cartelle rimaste vuote (solo quelle create dall'ordinamento).
        for pair in log.pairs {
            var dir = URL(fileURLWithPath: pair[1]).deletingLastPathComponent().standardizedFileURL
            while dir.path.hasPrefix(root.path + "/") {
                let items = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? ["x"]
                guard items.filter({ $0 != ".DS_Store" }).isEmpty else { break }
                try? fm.removeItem(at: dir)
                dir = dir.deletingLastPathComponent()
            }
        }
        if failed == 0 { try? fm.removeItem(at: logURL) }
        return (restored, failed)
    }
}

// MARK: - Aggiornamenti

enum Updater {
    static let repo = "rokaproduzioni1/ordina-cartelle"

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    struct Release { let version: String; let url: URL; let zip: URL? }

    /// Usa `gh` (già autenticato sul Mac, funziona anche con repo privato); in alternativa l'API pubblica.
    static func latest() async -> Release? {
        await Task.detached { () -> Release? in
            guard let data = viaGH() ?? viaHTTP(),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
            let zip = (json["assets"] as? [[String: Any]])?
                .compactMap { $0["browser_download_url"] as? String }
                .first { $0.hasSuffix(".zip") }
                .flatMap(URL.init(string:))
            return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, url: page, zip: zip)
        }.value
    }

    private static func ghPath() -> String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func run(_ exe: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    private static func viaGH() -> Data? {
        guard let gh = ghPath() else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: gh)
        p.arguments = ["api", "repos/\(repo)/releases/latest"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? data : nil
    }

    private static func viaHTTP() -> Data? {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let sem = DispatchSemaphore(value: 0)
        var result: Data?
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            if (resp as? HTTPURLResponse)?.statusCode == 200 { result = data }
            sem.signal()
        }.resume()
        sem.wait()
        return result
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    static var autoInstallEnabled: Bool {
        UserDefaults.standard.object(forKey: "autoInstall") as? Bool ?? true
    }

    /// Scarica lo zip con HTTPS (repo pubblico); se non riesce prova con `gh`.
    private static func download(_ r: Release, to dir: URL) -> Bool {
        if let u = r.zip, let data = fetch(u, timeout: 120) {
            return (try? data.write(to: dir.appendingPathComponent("Genuzzu.zip"))) != nil
        }
        guard let gh = ghPath() else { return false }
        return run(gh, ["release", "download", "v\(r.version)", "-R", repo, "-p", "*.zip", "-D", dir.path]) == 0
    }

    private static func fetch(_ url: URL, timeout: TimeInterval) -> Data? {
        let sem = DispatchSemaphore(value: 0)
        var result: Data?
        URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: timeout)) { data, resp, _ in
            if (resp as? HTTPURLResponse)?.statusCode == 200 { result = data }
            sem.signal()
        }.resume()
        sem.wait()
        return result
    }

    /// Scarica lo zip della release, lo estrae e sostituisce l'app in esecuzione.
    static func install(_ r: Release) async -> Bool {
        await Task.detached { () -> Bool in
            let fm = FileManager.default
            let tmp = fm.temporaryDirectory.appendingPathComponent("ordina-update-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: tmp) }
            let out = tmp.appendingPathComponent("x")
            guard Bundle.main.bundleURL.pathExtension == "app",
                  (try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)) != nil,
                  download(r, to: tmp),
                  let zip = (try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil))?.first(where: { $0.pathExtension == "zip" }),
                  run("/usr/bin/ditto", ["-x", "-k", zip.path, out.path]) == 0 else { return false }
            guard let newApp = (try? fm.contentsOfDirectory(at: out, includingPropertiesForKeys: nil))?.first(where: { $0.pathExtension == "app" }) else { return false }
            _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])
            return (try? fm.replaceItemAt(Bundle.main.bundleURL, withItemAt: newApp)) != nil
        }.value
    }

    static func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; open \"$0\"", Bundle.main.bundleURL.path]
        try? p.run()
        NSApp.terminate(nil)
    }

    @MainActor
    static func check(silent: Bool) async {
        guard let r = await latest() else {
            if !silent { alert("Impossibile controllare gli aggiornamenti", "Verifica la connessione e che GitHub sia raggiungibile.") }
            return
        }
        guard isNewer(r.version, than: currentVersion) else {
            if !silent { alert("Sei aggiornato", "Stai usando l'ultima versione (\(currentVersion)).") }
            return
        }
        if !autoInstallEnabled {
            let a = NSAlert()
            a.messageText = "È disponibile la versione \(r.version)"
            a.informativeText = "Stai usando la \(currentVersion). Vuoi installarla ora?"
            a.addButton(withTitle: "Installa ora")
            a.addButton(withTitle: "Apri pagina")
            a.addButton(withTitle: "Più tardi")
            switch a.runModal() {
            case .alertFirstButtonReturn: break
            case .alertSecondButtonReturn: NSWorkspace.shared.open(r.url); return
            default: return
            }
        }
        guard await install(r) else {
            let a = NSAlert()
            a.messageText = "Installazione automatica non riuscita"
            a.informativeText = "Puoi scaricare la versione \(r.version) dalla pagina della release."
            a.addButton(withTitle: "Apri pagina")
            a.addButton(withTitle: "Chiudi")
            if a.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(r.url) }
            return
        }
        let a = NSAlert()
        a.messageText = "Versione \(r.version) installata"
        a.informativeText = "Riavvia l'app per usare la nuova versione."
        a.addButton(withTitle: "Riavvia ora")
        a.addButton(withTitle: "Più tardi")
        if a.runModal() == .alertFirstButtonReturn { relaunch() }
    }

    @MainActor
    private static func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}

// MARK: - ViewModel

@MainActor
final class ViewModel: ObservableObject {
    @Published var folder: URL?
    @Published var moves: [PlannedMove] = []
    @Published var recursive = false { didSet { scan() } }
    @Published var busy = false
    @Published var status = "Scegli una cartella da ordinare."
    @Published var canUndo = Organizer.loadLog() != nil
    enum Phase { case idle, preview, ordered, done }
    @Published var phase = Phase.idle
    private var lastSettings = Prefs.current

    init() {
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.settingsChanged() }
        }
    }

    private func settingsChanged() {
        let s = Prefs.current
        guard s != lastSettings else { return }
        lastSettings = s
        if folder != nil && !busy { scan() }
    }

    func goHome() {
        folder = nil
        moves = []
        phase = .idle
        status = "Scegli una cartella da ordinare."
    }

    func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.prompt = "Scegli"
        p.message = "Scegli la cartella da ordinare"
        guard p.runModal() == .OK, let url = p.url else { return }
        setFolder(url)
    }

    func setFolder(_ url: URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            status = "Trascina una cartella, non un file."
            return
        }
        folder = url.standardizedFileURL
        scan()
    }

    func scan() {
        guard let root = folder else { return }
        busy = true
        status = "Analisi in corso…"
        let rec = recursive
        let settings = Prefs.current
        Task.detached {
            let result = Organizer.plan(root: root, recursive: rec, settings: settings)
            let dups = result.filter { $0.duplicateOf != nil }.count
            await MainActor.run {
                self.moves = result
                self.busy = false
                self.phase = result.isEmpty ? .ordered : .preview
                self.status = result.isEmpty
                    ? "Niente da spostare: la cartella è già in ordine."
                    : "\(result.count) file verranno spostati in \(Set(result.map { $0.dest.deletingLastPathComponent() }).count) cartelle"
                    + (dups > 0 ? ", di cui \(dups) doppioni esatti in “\(Organizer.duplicatesFolder)”" : "")
                    + ". Nessun file è stato ancora toccato: controlla l'anteprima, poi premi “Ordina”."
            }
        }
    }

    func organize() {
        guard let root = folder, !moves.isEmpty else { return }
        let plan = moves
        busy = true
        status = "Spostamento in corso…"
        Task.detached {
            let r = Organizer.apply(plan, root: root)
            await MainActor.run {
                self.busy = false
                self.canUndo = Organizer.loadLog() != nil
                self.moves = []
                self.phase = .done
                self.status = "Fatto: \(r.done) file spostati" + (r.failed > 0 ? ", \(r.failed) non spostati." : ".")
            }
        }
    }

    func undo() {
        guard let log = Organizer.loadLog() else { return }
        busy = true
        status = "Ripristino in corso…"
        Task.detached {
            let r = Organizer.undo(log)
            await MainActor.run {
                self.busy = false
                self.canUndo = Organizer.loadLog() != nil
                self.status = "Annullato: \(r.restored) file ripristinati" + (r.failed > 0 ? ", \(r.failed) non ripristinati." : ".")
                self.scan()
            }
        }
    }

    var groups: [(folder: String, moves: [PlannedMove])] {
        Dictionary(grouping: moves) { relative($0.dest.deletingLastPathComponent()) }
            .map { (folder: $0.key, moves: $0.value) }
            .sorted { $0.folder.localizedStandardCompare($1.folder) == .orderedAscending }
    }

    func relative(_ url: URL) -> String {
        guard let root = folder else { return url.path }
        let p = url.standardizedFileURL.path
        return p.hasPrefix(root.path + "/") ? String(p.dropFirst(root.path.count + 1)) : p
    }
}

// MARK: - Interfaccia

/// Maniglia trascinabile tra due aree: il mouse ne cambia la dimensione, il doppio clic ripristina quella automatica.
struct PaneDivider: View {
    /// Dimensione salvata dell'area ridimensionata (0 = automatica).
    @Binding var stored: Double
    /// Dimensione che l'area ha adesso, da cui parte il trascinamento.
    let current: CGFloat
    let range: ClosedRange<CGFloat>
    /// Maniglia orizzontale che regola un'altezza (aree una sopra l'altra).
    var vertical = false
    /// L'area regolata sta sotto/a destra della maniglia: trascinare verso l'alto/sinistra la ingrandisce.
    var inverted = false
    @State private var start: CGFloat?
    @State private var hovering = false

    var body: some View {
        let lit = hovering || start != nil
        Group {
            if vertical {
                Capsule().fill(Color.secondary.opacity(lit ? 0.6 : 0.25)).frame(width: 44, height: 4)
                    .frame(height: 16).frame(maxWidth: .infinity)
            } else {
                Capsule().fill(Color.secondary.opacity(lit ? 0.6 : 0.25)).frame(width: 4, height: 44)
                    .frame(width: 16).frame(maxHeight: .infinity)
            }
        }
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            if inside { (vertical ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).push() } else { NSCursor.pop() }
        }
        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { g in
                if start == nil { start = current }
                let delta = vertical ? g.translation.height : g.translation.width
                stored = Double(min(max((start ?? current) + (inverted ? -delta : delta), range.lowerBound), range.upperBound))
            }
            .onEnded { _ in start = nil })
        .onTapGesture(count: 2) { stored = 0 }
        .help("Trascina per ridimensionare, doppio clic per ripristinare")
    }
}

struct ContentView: View {
    @StateObject private var vm = ViewModel()
    @Environment(\.openWindow) private var openWindow
    @AppStorage("autoUpdateCheck") private var autoUpdateCheck = true
    @AppStorage("layoutParts") private var layoutParts = ""
    @AppStorage("layout") private var legacyLayout = ""
    @AppStorage("sortPaneWidth") private var sortPaneWidth = 0.0
    @AppStorage("sortPaneHeight") private var sortPaneHeight = 0.0
    @State private var confirm = false
    @State private var dropTargeted = false
    @State private var section = 0
    @State private var showDuplicates = false
    @AppStorage("mascotVisible") private var mascotVisible = true
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @StateObject private var search = SearchModel()

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(vm: vm)
                .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 260)
        } detail: {
            VStack(spacing: 0) {
                Picker("Sezione", selection: $section) {
                    Text("Metti in ordine").tag(0)
                    Text("Cerca file").tag(1)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 300)
                .padding([.top, .horizontal])
                if section == 0 && mascotVisible && vm.phase == .idle && !vm.busy {
                    GenuzzuTitleBar(title: "Questa è la sezione Metti in ordine", text: "Trascina qui una cartella o sceglila: ti mostro in anteprima come la dispongo in sottocartelle per data e tipo, e non tocco nulla finché non confermi.")
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if section == 0 { sortView } else { SearchView(m: search) { url in
                    vm.setFolder(url)
                    section = 0
                } }
                GenuzzuFooter(context: mascotContext)
            }
            .background(AmbientBackground())
            .animation(.easeInOut(duration: 0.25), value: vm.phase == .idle)
            .task { if autoUpdateCheck { await Updater.check(silent: true) } }
        }
        // L'elenco cartelle serve solo a scegliere cosa riordinare: nella ricerca si nasconde.
        .onChange(of: section) { columnVisibility = $0 == 0 ? .all : .detailOnly }
    }

    private var mascotContext: GenuzzuContext {
        if section == 1 { return .search }
        if vm.busy { return .busy }
        switch vm.phase {
        case .idle: return .idle
        case .preview: return .preview
        case .ordered: return .ordered
        case .done: return .done
        }
    }

    private var sortView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { vm.goHome() } label: { Label("Home", systemImage: "house") }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                    .disabled(vm.folder == nil || vm.busy)
                Button("Scegli cartella…") { vm.chooseFolder() }
                    .keyboardShortcut("o")
                Text(vm.folder?.path ?? "Nessuna cartella selezionata")
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button { openWindow(id: "settings") } label: { Label("Impostazioni", systemImage: "gearshape") }
                    .keyboardShortcut(",")
            }

            HStack {
                Toggle("Includi anche le sottocartelle", isOn: $vm.recursive)
                    .disabled(vm.busy)
                Spacer()
                Text("Struttura: " + Prefs.title(of: Prefs.resolveParts(layoutParts: layoutParts, legacy: legacyLayout)))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }

            GeometryReader { geo in
                let right = Group {
                    if vm.moves.isEmpty {
                        SortAnimationView()
                    } else {
                        PreviewTreeView(vm: vm)
                    }
                }
                .transition(.opacity)

                if !vm.moves.isEmpty {
                    // Riordino proposto: l'area di drop non serve più, tutto lo spazio va all'anteprima.
                    VStack(alignment: .leading, spacing: 8) {
                        Text(vm.status).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        right
                    }
                } else if geo.size.width >= 600 {
                    let maxLeft = max(geo.size.width - 260, 200)
                    let left = min(max(sortPaneWidth > 0 ? CGFloat(sortPaneWidth) : 300, 180), maxLeft)
                    HStack(spacing: 0) {
                        DropZoneView(vm: vm, targeted: dropTargeted)
                            .frame(width: left)
                        PaneDivider(stored: $sortPaneWidth, current: left, range: 180...maxLeft)
                        right
                    }
                } else {
                    // Finestra stretta: area di drop sopra, animazione/anteprima sotto.
                    let maxTop = max(geo.size.height - 170, 110)
                    let top = min(max(sortPaneHeight > 0 ? CGFloat(sortPaneHeight) : 165, 110), maxTop)
                    VStack(spacing: 0) {
                        DropZoneView(vm: vm, targeted: dropTargeted)
                            .frame(height: top)
                        PaneDivider(stored: $sortPaneHeight, current: top, range: 110...maxTop, vertical: true)
                        right.frame(minHeight: 160)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.25), value: vm.moves.isEmpty)

            HStack {
                if vm.busy { ProgressView().controlSize(.small) }
                Button { showDuplicates = true } label: { Label("Cerca duplicati", systemImage: "square.on.square") }
                    .disabled(vm.folder == nil || vm.busy)
                    .help("Trova i file con contenuto identico nella cartella scelta")
                Spacer()
                Button("Annulla ultimo ordinamento") { vm.undo() }
                    .disabled(!vm.canUndo || vm.busy)
                Button("Ordina") { confirm = true }
                    .prominentGlass()
                    .disabled(vm.moves.isEmpty || vm.busy)
            }
        }
        .padding()
        .frame(minWidth: 520, minHeight: 480)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            vm.setFolder(url)
            return true
        } isTargeted: { dropTargeted = $0 }
        .sheet(isPresented: $showDuplicates, onDismiss: {
            vm.canUndo = Organizer.loadLog() != nil
            vm.scan()
        }) { DuplicatesView(vm: vm) }
        .alert("Spostare \(vm.moves.count) file?", isPresented: $confirm) {
            Button("Ordina") { vm.organize() }
            Button("Cancella", role: .cancel) {}
        } message: {
            Text("I file saranno organizzati secondo la struttura scelta nelle impostazioni dentro la cartella scelta. Potrai annullare l'operazione.")
        }
    }
}

// MARK: - Ricerca file

struct Hit: Identifiable {
    let url: URL
    let size: Int64?
    let date: Date?
    var id: String { url.path }
    var name: String { url.lastPathComponent }
}

enum SearchDateField: String, CaseIterable, Identifiable {
    case modified, created
    var id: String { rawValue }
    var title: String { self == .modified ? "modificati" : "creati" }
}

enum DatePreset: String, CaseIterable, Identifiable {
    case today, week, month, thisYear, lastYear
    var id: String { rawValue }
    var title: String {
        switch self {
        case .today: return "Oggi"
        case .week: return "Ultimi 7 giorni"
        case .month: return "Ultimi 30 giorni"
        case .thisYear: return "Quest'anno"
        case .lastYear: return "Anno scorso"
        }
    }
}

/// Filtro generico per tipo di file, basato sui tipi di contenuto del sistema.
enum FileKind: String, CaseIterable, Identifiable {
    case all, images, video, audio, documents, archives
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "Tutti i tipi"
        case .images: return "Immagini"
        case .video: return "Video"
        case .audio: return "Audio"
        case .documents: return "Documenti"
        case .archives: return "Archivi"
        }
    }
    var symbol: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .images: return "photo"
        case .video: return "film"
        case .audio: return "music.note"
        case .documents: return "doc.text"
        case .archives: return "archivebox"
        }
    }
    private var types: [String] {
        switch self {
        case .all: return []
        case .images: return ["public.image"]
        case .video: return ["public.movie"]
        case .audio: return ["public.audio"]
        case .documents: return ["com.adobe.pdf", "public.text", "public.presentation", "public.spreadsheet",
                                 "org.openxmlformats.wordprocessingml.document", "com.microsoft.word.doc"]
        case .archives: return ["public.archive", "public.disk-image"]
        }
    }
    /// Tipi di contenuto che corrispondono a questa categoria.
    var utTypes: [UTType] { types.compactMap { UTType($0) } }
}

/// Icona di un file nei risultati: miniatura vera per le immagini, icona di sistema per gli altri.
struct FileThumbnail: View {
    let url: URL
    @State private var image: NSImage?
    private static let cache = NSCache<NSURL, NSImage>()

    private var isImage: Bool { UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 36, height: 36)
                    .frame(width: 40, height: 40)
            }
        }
        .task(id: url) {
            guard isImage else { return }
            if let c = Self.cache.object(forKey: url as NSURL) { image = c; return }
            let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 40, height: 40),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2,
                                                   representationTypes: .thumbnail)
            if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) {
                Self.cache.setObject(rep.nsImage, forKey: url as NSURL)
                image = rep.nsImage
            }
        }
    }
}

/// Anteprima rapida di sistema (quella del Finder con la barra spaziatrice).
final class QuickLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLook()
    private var urls: [URL] = []

    func toggle(_ urls: [URL], index: Int) {
        guard let panel = QLPreviewPanel.shared(), !urls.isEmpty else { return }
        if panel.isVisible { panel.orderOut(nil); return }
        self.urls = urls
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = min(max(index, 0), urls.count - 1)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Se l'anteprima è aperta, mostra un altro file (cambiando la selezione nell'elenco).
    func follow(_ index: Int) {
        guard let panel = QLPreviewPanel.shared(), panel.isVisible, index >= 0, index < urls.count else { return }
        panel.currentPreviewItemIndex = index
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { urls[index] as NSURL }
}

@MainActor
final class SearchModel: ObservableObject {
    /// Criteri di ricerca: ognuno si accende da solo e, se ce n'è più di uno, valgono tutti insieme.
    @Published var useName = false
    @Published var text = ""
    @Published var useDate = false
    @Published var useKind = false
    @Published var kind = FileKind.images
    @Published var dateField = SearchDateField.modified
    @Published var from = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
    @Published var to = Date()
    @Published var all: [Hit] = []
    @Published var selection = Set<String>()
    @Published var searching = false
    @Published var includeSystem = false
    @Published var destination: URL?
    /// La destinazione è facoltativa: finché è spenta l'app si limita a cercare.
    @Published var useDestination = false {
        // Con la destinazione i file si scelgono per spostarli: di partenza sono tutti scelti.
        didSet { if useDestination && selection.isEmpty { selection = Set(hits.map(\.id)) } }
    }
    /// Dove cercare: ogni posto si accende da solo e si possono combinare.
    @Published var searchComputer = true
    @Published var searchExternal = false
    @Published var searchNetwork = false
    /// Cartelle aggiunte a mano.
    @Published var folders: [URL] = []
    @Published var busy = false
    /// Cartella in cui proporre il riordino dopo una copia/spostamento riusciti.
    @Published var offerSort: URL?
    @Published var status = "Scrivi una parte del nome dei file e premi Invio."
    @Published var lastMoved: [(from: URL, to: URL)] = []
    /// Dischi esterni e di rete collegati in questo momento.
    @Published var volumes: [Volume] = []
    @Published var scanned = 0
    private var deepTask: Task<Void, Never>?
    private static let maxHits = 5000
    /// Chiamata appena c'è il primo risultato (o a ricerca finita se non ce n'è): la usa la barra dei menu per aprire i risultati.
    var onResults: (() -> Void)?
    private var announced = false

    private func announceResults() {
        guard !announced else { return }
        announced = true
        onResults?()
    }

    struct Volume: Identifiable {
        let url: URL
        let name: String
        let network: Bool
        var id: String { url.path }
    }

    init() {
        refreshVolumes()
        for n in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshVolumes() }
            }
        }
    }

    func refreshVolumes() {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsLocalKey, .volumeIsInternalKey, .volumeIsRootFileSystemKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        volumes = urls.compactMap { u in
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.volumeIsRootFileSystem != true else { return nil }
            let network = v.volumeIsLocal == false
            guard network || v.volumeIsInternal == false else { return nil }
            return Volume(url: u, name: v.volumeName ?? u.lastPathComponent, network: network)
        }
    }

    /// Le radici da leggere: disco del Mac, dischi esterni, dischi di rete e cartelle scelte a mano.
    var searchRoots: [URL] {
        var roots: [URL] = []
        if searchComputer { roots.append(URL(fileURLWithPath: "/")) }
        if searchExternal { roots += volumes.filter { !$0.network }.map(\.url) }
        if searchNetwork { roots += volumes.filter { $0.network }.map(\.url) }
        // Una cartella già compresa in un'altra radice non si legge due volte.
        let base = roots
        for f in folders {
            let covered = base.contains { r in
                r.path == "/" ? !f.path.hasPrefix("/Volumes") : f.path == r.path || f.path.hasPrefix(r.path + "/")
            }
            if !covered { roots.append(f) }
        }
        return roots
    }

    /// I posti scelti in una frase, per esempio “Tutto il computer · Dischi esterni · Rete”.
    var placesSummary: String {
        var bits: [String] = []
        if searchComputer { bits.append("Tutto il computer") }
        if searchExternal { bits.append("Dischi esterni") }
        if searchNetwork { bits.append("Rete") }
        bits += folders.map(\.lastPathComponent)
        return bits.isEmpty ? "Nessun posto scelto" : bits.joined(separator: " · ")
    }

    func addFolder(_ url: URL) {
        let u = url.standardizedFileURL
        if !folders.contains(u) { folders.append(u) }
    }

    /// Esclude Libreria, pacchetti .app e cartelle nascoste, a meno che si chieda di includerli.
    /// Dischi esterni, di rete e cartelle scelte a mano non vengono mai filtrati.
    var hits: [Hit] {
        if includeSystem { return all }
        let own = folders.map(\.path)
        return all.filter { h in
            let p = h.url.path
            if p.hasPrefix("/Volumes/") || own.contains(where: { p.hasPrefix($0 + "/") }) { return true }
            return !(p.contains("/Library/") || p.contains(".app/") || p.contains("/.") || p.hasPrefix("/System")
                     || p.hasPrefix("/usr") || p.hasPrefix("/private") || p.hasPrefix("/opt"))
        }
    }

    var selectedHits: [Hit] { hits.filter { selection.contains($0.id) } }

    func search() {
        let words = useName ? text.split(separator: " ").map(String.init).filter { !$0.isEmpty } : []
        guard canSearch else {
            status = "Scegli almeno un criterio: nome, data o tipo di file."
            return
        }
        guard words.isEmpty || text.trimmingCharacters(in: .whitespaces).count >= 2 else {
            status = "Scrivi almeno due caratteri."
            return
        }
        deepTask?.cancel()
        all = []
        selection = []
        searching = true
        announced = false
        scanned = 0
        status = "Ricerca in corso…"
        searchDeep(words: words)
    }

    /// Interrompe la ricerca in corso e tiene i risultati già trovati.
    func stop() { deepTask?.cancel() }

    private func searchDeep(words: [String]) {
        let roots = searchRoots
        let cal = Calendar.current
        let lo = cal.startOfDay(for: min(from, to))
        let hi = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: max(from, to))) ?? max(from, to)
        let dateRange = useDate ? (created: dateField == .created, lo: lo, hi: hi) : nil
        let types = useKind ? kind.utTypes : []
        let skipLibrary = !includeSystem && searchComputer
        let includeSystem = self.includeSystem
        // Dalla radice del Mac: i dischi collegati si leggono a parte e /System/Volumes duplicherebbe tutto.
        var skipTop: Set<String> = ["/Volumes", "/dev", "/cores", "/Network", "/System/Volumes"]
        if !includeSystem { skipTop.formUnion(["/System", "/private", "/usr", "/bin", "/sbin", "/opt", "/Library"]) }
        let skipTopLevel = skipTop
        deepTask = Task.detached(priority: .userInitiated) { [weak self] in
            var batch: [Hit] = []
            var count = 0
            var lastReport = Date()
            let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
                                          .creationDateKey, .contentTypeKey]
            func flush(_ folder: String) async {
                let out = batch, n = count
                batch = []
                lastReport = Date()
                await MainActor.run { self?.deepProgress(out, scanned: n, folder: folder) }
            }
            outer: for root in roots {
                guard let en = FileManager.default.enumerator(
                    at: root, includingPropertiesForKeys: keys,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants],
                    errorHandler: { _, _ in true }) else { continue }
                while let url = en.nextObject() as? URL {
                    if Task.isCancelled { break outer }
                    let v = try? url.resourceValues(forKeys: Set(keys))
                    if v?.isDirectory == true {
                        if (root.path == "/" && skipTopLevel.contains(url.path))
                            || (skipLibrary && url.lastPathComponent == "Library") { en.skipDescendants() }
                        continue
                    }
                    count += 1
                    var date = v?.contentModificationDate
                    if !words.allSatisfy({ url.lastPathComponent.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }) {
                        // Nome non corrispondente
                    } else if let d = dateRange, !({
                        date = d.created ? v?.creationDate : v?.contentModificationDate
                        guard let x = date else { return false }
                        return x >= d.lo && x < d.hi
                    }()) {
                        // Data fuori dal periodo
                    } else if !types.isEmpty, !(v?.contentType.map { t in types.contains { t.conforms(to: $0) } } ?? false) {
                        // Tipo diverso
                    } else {
                        batch.append(Hit(url: url, size: v?.fileSize.map(Int64.init), date: date))
                    }
                    if batch.count >= 200 || Date().timeIntervalSince(lastReport) > 0.4 {
                        await flush(url.deletingLastPathComponent().lastPathComponent)
                    }
                }
            }
            await flush("")
            await MainActor.run { self?.deepFinish() }
        }
    }

    private func deepProgress(_ hits: [Hit], scanned n: Int, folder: String) {
        guard searching else { return }
        all.append(contentsOf: hits.prefix(max(Self.maxHits - all.count, 0)))
        scanned = n
        if !self.hits.isEmpty { announceResults() }
        status = "Ricerca approfondita: \(n) file controllati, \(all.count) trovati" + (folder.isEmpty ? "" : " · ora in “\(folder)”")
    }

    private func deepFinish() {
        guard searching else { return }
        var seen = Set<String>()
        all = all.filter { seen.insert($0.id).inserted }
        all.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        selection = useDestination ? Set(hits.map(\.id)) : []
        searching = false
        let n = hits.count
        status = n == 0 ? "Nessun file trovato (controllati \(scanned))." : "\(n) file trovati su \(scanned) controllati."
        announceResults()
    }

    func clear() {
        deepTask?.cancel()
        text = ""
        useName = false
        useDate = false
        useKind = false
        kind = .images
        all = []
        selection = []
        lastMoved = []
        searching = false
        status = "Scrivi una parte del nome dei file e premi Invio."
    }

    /// C'è almeno un criterio attivo e valido?
    var canSearch: Bool {
        !searchRoots.isEmpty && ((useName && !text.trimmingCharacters(in: .whitespaces).isEmpty) || useDate || useKind)
    }

    /// Riassunto a parole di cosa verrà cercato, mostrato sotto il pulsante Cerca.
    /// I criteri attivi in una riga, per esempio “nome con “cliente” · tipo: immagini”.
    var criteriaBits: String {
        var bits: [String] = []
        if useName, !text.trimmingCharacters(in: .whitespaces).isEmpty { bits.append("nome con “\(text.trimmingCharacters(in: .whitespaces))”") }
        if useDate { bits.append("\(dateField.title) \(rangeDescription)") }
        if useKind { bits.append("tipo: \(kind.title.lowercased())") }
        return bits.joined(separator: " · ")
    }
    var summary: String {
        guard canSearch else { return "Scegli almeno un criterio di ricerca, poi premi Cerca." }
        return "Cercherò file con " + criteriaBits + " — in " + placesSummary.lowercased()
    }

    /// Imposta il periodo e attiva il filtro per data.
    func select(_ p: DatePreset) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let year = cal.component(.year, from: Date())
        useDate = true
        switch p {
        case .today: from = today; to = today
        case .week: from = cal.date(byAdding: .day, value: -7, to: today) ?? today; to = today
        case .month: from = cal.date(byAdding: .day, value: -30, to: today) ?? today; to = today
        case .thisYear: from = cal.date(from: DateComponents(year: year, month: 1, day: 1)) ?? today; to = today
        case .lastYear:
            from = cal.date(from: DateComponents(year: year - 1, month: 1, day: 1)) ?? today
            to = cal.date(from: DateComponents(year: year - 1, month: 12, day: 31)) ?? today
        }
    }

    var rangeDescription: String {
        let lo = min(from, to), hi = max(from, to)
        let f = { (d: Date) in d.formatted(date: .abbreviated, time: .omitted) }
        return Calendar.current.isDate(lo, inSameDayAs: hi) ? "il \(f(lo))" : "dal \(f(lo)) al \(f(hi))"
    }

    func chooseScope() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.prompt = "Cerca qui"
        p.message = "Scegli la cartella in cui cercare"
        if p.runModal() == .OK, let url = p.url { addFolder(url) }
    }

    func chooseDestination() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.prompt = "Scegli"
        p.message = "Scegli la cartella in cui copiare o spostare i file"
        if p.runModal() == .OK, let url = p.url { destination = url.standardizedFileURL }
    }

    /// Copia o sposta i file selezionati nella cartella di destinazione, senza mai sovrascrivere.
    func transfer(move: Bool) {
        guard useDestination, let dest = destination else { return }
        let items = selectedHits.map(\.url).filter { $0.deletingLastPathComponent().standardizedFileURL != dest }
        guard !items.isEmpty else { status = "Niente da fare: i file selezionati sono già in quella cartella."; return }
        busy = true
        status = move ? "Spostamento in corso…" : "Copia in corso…"
        Task.detached {
            let fm = FileManager.default
            var used = Set<String>()
            var done: [(from: URL, to: URL)] = []
            var failed = 0
            for src in items {
                let target = Organizer.uniqueDestination(dir: dest, name: src.lastPathComponent, used: &used)
                do {
                    if move { try fm.moveItem(at: src, to: target) } else { try fm.copyItem(at: src, to: target) }
                    done.append((src, target))
                } catch { failed += 1 }
            }
            let result = done, bad = failed
            await MainActor.run {
                self.busy = false
                self.lastMoved = move ? result : []
                if move {
                    let gone = Set(result.map { $0.from.path })
                    self.all.removeAll { gone.contains($0.id) }
                    self.selection.subtract(gone)
                }
                if !result.isEmpty { self.offerSort = dest }
                self.status = (move ? "Spostati " : "Copiati ") + "\(result.count) file in “\(dest.lastPathComponent)”"
                    + (bad > 0 ? ", \(bad) non riusciti." : ".")
            }
        }
    }

    func undoMove() {
        let pairs = lastMoved
        busy = true
        Task.detached {
            let fm = FileManager.default
            var restored: [Hit] = []
            var failed = 0
            for (from, to) in pairs.reversed() {
                guard fm.fileExists(atPath: to.path), !fm.fileExists(atPath: from.path) else { failed += 1; continue }
                do { try fm.moveItem(at: to, to: from); restored.append(Hit(url: from, size: nil, date: nil)) }
                catch { failed += 1 }
            }
            let back = restored, bad = failed
            await MainActor.run {
                self.busy = false
                self.lastMoved = []
                self.all.append(contentsOf: back)
                self.all.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                self.status = "Ripristinati \(back.count) file" + (bad > 0 ? ", \(bad) non ripristinati." : ".")
            }
        }
    }
}

/// Scheda che identifica una cartella con il suo ruolo (origine o destinazione).
/// Pulsante a tutta larghezza per i comandi di una posizione (Scegli cartella…, Cambia…, Rimuovi).
struct PlaceButtonStyle: ButtonStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(color.opacity(configuration.isPressed ? 0.3 : 0.16)))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

struct PlaceCard<Actions: View>: View {
    let role: String
    let symbol: String
    let color: Color
    let path: String?
    let placeholder: String
    var missing = false
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Circle().fill(color.gradient))
            VStack(alignment: .leading, spacing: 2) {
                Text(role).font(.caption.weight(.heavy)).foregroundStyle(color)
                Text(path.map { $0.replacingOccurrences(of: NSHomeDirectory(), with: "~") } ?? placeholder)
                    .font(.callout.weight(path == nil ? .regular : .semibold))
                    .foregroundStyle(path == nil ? (missing ? Color.orange : .secondary) : .primary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            // I comandi stanno a destra, in colonna e tutti della stessa larghezza.
            VStack(spacing: 6) { actions }
                .buttonStyle(PlaceButtonStyle(color: color))
                .frame(width: 128)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(RoundedRectangle(cornerRadius: 14, style: .continuous), tint: color.opacity(0.28))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(missing ? Color.orange : color.opacity(0.45),
                              style: StrokeStyle(lineWidth: missing ? 1.5 : 1, dash: missing ? [5, 4] : []))
        )
    }
}

/// Calendario mensile con selezione di un intervallo: primo clic = inizio, secondo clic = fine.
struct RangeCalendarView: View {
    @Binding var from: Date
    @Binding var to: Date
    @State private var month = Date()
    @State private var pickingEnd = false

    private var cal: Calendar { var c = Calendar.current; c.firstWeekday = 2; return c }
    private struct Cell: Identifiable { let id: Int; let date: Date? }

    private func startOfMonth(_ d: Date) -> Date { cal.date(from: cal.dateComponents([.year, .month], from: d)) ?? d }

    private var cells: [Cell] {
        let first = startOfMonth(month)
        let lead = (cal.component(.weekday, from: first) - cal.firstWeekday + 7) % 7
        let n = cal.range(of: .day, in: .month, for: first)?.count ?? 30
        return (0..<(lead + n)).map { i in
            Cell(id: i, date: i < lead ? nil : cal.date(byAdding: .day, value: i - lead, to: first))
        }
    }

    private func shift(_ delta: Int) { month = cal.date(byAdding: .month, value: delta, to: month) ?? month }

    private func tap(_ d: Date) {
        let day = cal.startOfDay(for: d)
        if !pickingEnd {
            from = day; to = day; pickingEnd = true
        } else {
            if day < cal.startOfDay(for: from) { to = from; from = day } else { to = day }
            pickingEnd = false
        }
    }

    var body: some View {
        let lo = cal.startOfDay(for: min(from, to)), hi = cal.startOfDay(for: max(from, to))
        VStack(spacing: 6) {
            HStack {
                Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                Spacer()
                Text(month.formatted(.dateTime.month(.wide).year()).capitalized).font(.system(size: 14, weight: .semibold))
                Spacer()
                Button { shift(1) } label: { Image(systemName: "chevron.right") }
            }
            .buttonStyle(.borderless)

            HStack(spacing: 0) {
                ForEach(Array(["L", "M", "M", "G", "V", "S", "D"].enumerated()), id: \.offset) { _, d in
                    Text(d).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 3) {
                ForEach(cells) { c in
                    if let d = c.date {
                        let day = cal.startOfDay(for: d)
                        let isEnd = day == lo || day == hi
                        let inRange = day >= lo && day <= hi
                        Button { tap(d) } label: {
                            Text("\(cal.component(.day, from: d))")
                                .font(.callout.weight(isEnd ? .bold : .regular).monospacedDigit())
                                .foregroundStyle(isEnd ? Color.white : .primary)
                                .frame(maxWidth: .infinity, minHeight: 30)
                                .background {
                                    ZStack {
                                        if inRange {
                                            // Fascia del periodo: arrotondata a inizio, fine e a capo riga.
                                            let col = (cal.component(.weekday, from: d) - cal.firstWeekday + 7) % 7
                                            let capL = day == lo || col == 0 || cal.component(.day, from: d) == 1
                                            let capR = day == hi || col == 6
                                                || cal.date(byAdding: .day, value: 1, to: d).map { !cal.isDate($0, equalTo: d, toGranularity: .month) } == true
                                            UnevenRoundedRectangle(topLeadingRadius: capL ? 15 : 0, bottomLeadingRadius: capL ? 15 : 0,
                                                                   bottomTrailingRadius: capR ? 15 : 0, topTrailingRadius: capR ? 15 : 0,
                                                                   style: .continuous)
                                                .fill(Color.accentColor.opacity(0.2))
                                        }
                                        if isEnd { Circle().fill(Color.accentColor).frame(width: 30, height: 30) }
                                    }
                                }
                                .overlay {
                                    if cal.isDateInToday(d) && !isEnd {
                                        Circle().strokeBorder(Color.accentColor, lineWidth: 1)
                                    }
                                }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    } else {
                        Color.clear.frame(height: 30)
                    }
                }
            }
        }
        .onAppear { month = startOfMonth(to) }
        .onChange(of: to) { month = startOfMonth($0) }
    }
}

struct SearchView: View {
    @ObservedObject var m: SearchModel
    /// Chiamata quando l'utente accetta di riordinare la cartella di destinazione.
    var onSort: (URL) -> Void
    @State private var confirmMove = false
    /// Dopo una ricerca si vede solo l'elenco dei risultati; con "Modifica ricerca" tornano i comandi.
    @State private var editing = false
    @FocusState private var listFocused: Bool
    @AppStorage("mascotVisible") private var mascotVisible = true
    @AppStorage("searchPaneWidth") private var searchPaneWidth = 0.0
    @AppStorage("searchPaneHeight") private var searchPaneHeight = 0.0

    // Soglie di larghezza (area utile della vista) oltre le quali si passa dal layout stretto a quello largo.
    private let mediumWidth: CGFloat = 600
    private let wideWidth: CGFloat = 720
    /// Sopra questa larghezza la ricerca sta a sinistra e animazione/risultati a destra.
    private let twoColumnWidth: CGFloat = 800

    /// Un singolo passo, senza riquadro proprio: i riquadri sono `cardBox`.
    private func stepCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) { content() }
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// Il rettangolo che racchiude uno o più passi.
    private func cardBox<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) { content() }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .glass(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// I tre passi della ricerca (1, 2, 3) nello stesso rettangolo.
    private func stepsCard(medium: Bool, wide: Bool) -> some View {
        cardBox {
            criteriaCard(medium: medium)
            Divider()
            if wide {
                HStack(alignment: .top, spacing: 12) { whereCard; afterCard }
            } else {
                whereCard
                Divider()
                afterCard
            }
        }
    }

    /// Cerca e Pulisci tutto in un rettangolo a parte.
    private var actionsCard: some View { cardBox { searchButton } }

    private func stepHeader(_ n: Int, _ title: String, _ subtitle: String? = nil) -> some View {
        HStack(spacing: 8) {
            Text("\(n)").font(.caption.weight(.bold)).foregroundStyle(.white)
                .frame(width: 22, height: 22).background(Circle().fill(Color.accentColor))
            Text(title).font(.system(size: 16, weight: .bold))
            if let subtitle { Text(subtitle).font(.system(size: 11, weight: .regular)).foregroundStyle(.secondary).lineLimit(1) }
        }
    }

    private func criterionTile(_ title: String, _ symbol: String, _ subtitle: String, isOn: Binding<Bool>) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: isOn.wrappedValue ? "checkmark.circle.fill" : symbol)
                    .font(.system(size: 18))
                    .foregroundStyle(isOn.wrappedValue ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(subtitle).font(.system(size: 11, weight: .regular)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isOn.wrappedValue ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isOn.wrappedValue ? Color.accentColor : Color.secondary.opacity(0.3),
                              lineWidth: isOn.wrappedValue ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func dateOptions(centered: Bool) -> some View {
        let edge: HorizontalAlignment = centered ? .center : .leading
        let explanation = m.dateField == .modified
            ? "L'ultima volta che il file è stato cambiato e salvato. Se riapri un vecchio documento e lo salvi oggi, conta come di oggi."
            : "Il giorno in cui il file è nato sul computer: scaricato, fotografato o salvato per la prima volta. Non cambia se poi lo modifichi."
        return VStack(alignment: edge, spacing: 10) {
            Text("Quale data deve contare?").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            Picker("", selection: $m.dateField) {
                Text("Ultima modifica").tag(SearchDateField.modified)
                Text("Creazione").tag(SearchDateField.created)
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 260)
            Label {
                Text(explanation)
                    .font(.system(size: 12, weight: .regular))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "info.circle.fill").foregroundStyle(Color.accentColor)
            }
            .padding(.vertical, 8).padding(.horizontal, 10)
            .frame(maxWidth: 360, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.10)))
            Text("File \(m.dateField.title) \(m.rangeDescription)")
                .font(.system(size: 15, weight: .semibold))
                .multilineTextAlignment(centered ? .center : .leading)
                .fixedSize(horizontal: false, vertical: true)
            Menu("Scorciatoie…") {
                ForEach(DatePreset.allCases) { p in Button(p.title) { m.select(p) } }
            }
            .fixedSize()
            Text("Clicca due giorni sul calendario per scegliere il periodo.")
                .font(.system(size: 11, weight: .regular)).foregroundStyle(.secondary)
                .multilineTextAlignment(centered ? .center : .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Passo 1: cosa cercare. Nome, data e tipo si accendono a piacere e si combinano.
    private func criteriaCard(medium: Bool) -> some View {
        stepCard {
            stepHeader(1, "Cosa cerchi", "scegli uno o più criteri: valgono tutti insieme")
            HStack(spacing: 8) {
                criterionTile("Nome", "textformat", "parte del nome", isOn: $m.useName)
                criterionTile("Data", "calendar", "quando", isOn: $m.useDate)
                criterionTile("Tipo", "square.grid.2x2", "immagini, video…", isOn: $m.useKind)
            }
            if m.useName {
                panel {
                    Label("Nome contiene", systemImage: "textformat").font(.subheadline.weight(.semibold))
                    TextField("Scrivi una parte del nome del file…", text: $m.text)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                        .onSubmit { if m.canSearch { m.search() } }
                    Text("Più parole = tutte devono comparire nel nome").font(.caption).foregroundStyle(.tertiary)
                }
            }
            if m.useDate {
                panel {
                    Label("Data", systemImage: "calendar").font(.subheadline.weight(.semibold))
                    if medium {
                        HStack(alignment: .top, spacing: 22) {
                            RangeCalendarView(from: $m.from, to: $m.to).frame(width: 240)
                            dateOptions(centered: false)
                            Spacer(minLength: 0)
                        }
                    } else {
                        RangeCalendarView(from: $m.from, to: $m.to)
                            .frame(maxWidth: 320)
                            .frame(maxWidth: .infinity)
                        dateOptions(centered: true)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            if m.useKind {
                panel {
                    Label("Tipo di file", systemImage: "square.grid.2x2").font(.subheadline.weight(.semibold))
                    let kinds = FileKind.allCases.filter { $0 != .all }
                    if medium {
                        Picker("", selection: $m.kind) {
                            ForEach(kinds) { Label($0.title, systemImage: $0.symbol).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden()
                    } else {
                        Picker("", selection: $m.kind) {
                            ForEach(kinds) { Label($0.title, systemImage: $0.symbol).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: m.useName)
        .animation(.easeOut(duration: 0.15), value: m.useDate)
        .animation(.easeOut(duration: 0.15), value: m.useKind)
    }

    /// Passo 2: dove cercare.
    private var whereCard: some View {
        stepCard {
            stepHeader(2, "Dove cerchi")
            originCard
            placeChips
            modePicker
            Toggle("Includi file di sistema e della Libreria", isOn: $m.includeSystem)
                .disabled(!m.searchComputer)
                .lineLimit(1)
                .font(.callout)
        }
    }

    // MARK: Dove e come cercare

    private func placeChip(_ title: String, _ symbol: String, selected: Bool) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 17))
                .foregroundStyle(selected ? Color.accentColor : .secondary)
            Text(title).font(.system(size: 11, weight: selected ? .semibold : .medium))
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 52)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(selected ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: selected ? 2 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// Dove cercare: ogni posto si accende e si spegne da solo, quindi si possono scegliere più posti insieme.
    private var placeChips: some View {
        let hasExternal = m.volumes.contains { !$0.network }
        let hasNetwork = m.volumes.contains { $0.network }
        func chip(_ title: String, _ symbol: String, _ isOn: Binding<Bool>, available: Bool = true, empty: String = "") -> some View {
            Button { isOn.wrappedValue.toggle() } label: {
                placeChip(title, symbol, selected: isOn.wrappedValue && available)
            }
            .buttonStyle(.plain)
            .disabled(!available)
            .opacity(available ? 1 : 0.45)
            .help(available ? "Clicca per includere o escludere" : empty)
        }
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
            chip("Tutto il computer", "desktopcomputer", $m.searchComputer)
            chip("Dischi esterni", "externaldrive", $m.searchExternal, available: hasExternal,
                 empty: "Nessun disco esterno collegato")
            chip("Rete", "network", $m.searchNetwork, available: hasNetwork,
                 empty: "Nessun disco di rete collegato: collegalo dal Finder con Vai › Connetti al server")
        }
    }

    /// La ricerca legge ogni cartella: trova tutto, anche su dischi esterni e di rete, ma richiede un po' di tempo.
    private var modePicker: some View {
        Label {
            Text("Leggo ogni cartella dei posti scelti, anche dischi esterni e di rete: da alcuni secondi a diversi minuti. Puoi interrompere quando vuoi e tieni quello già trovato.")
                .font(.system(size: 11, weight: .regular)).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
        }
        .foregroundStyle(.secondary)
    }

    /// Passo 3: facoltativo, cosa fare dei file trovati.
    private var afterCard: some View {
        stepCard {
            stepHeader(3, "Dopo la ricerca", "facoltativo")
            destinationSlot
        }
    }

    /// Il pulsante principale della sezione: grande, pieno, sempre il più visibile.
    private var searchButton: some View {
        let enabled = (m.canSearch || m.searching) && !m.busy
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Button { if m.searching { m.stop() } else { m.search() } } label: {
                    HStack(spacing: 6) {
                        if m.searching { ProgressView().controlSize(.small) }
                        else { Image(systemName: "magnifyingglass") }
                        Text(m.searching ? "Interrompi" : "Cerca")
                    }
                    .font(.headline)
                    .foregroundStyle(enabled ? Color.black : Color.secondary)
                    .frame(minWidth: 110)
                }
                .prominentGlass(tint: .yellow)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!enabled)
                Spacer(minLength: 8)
                Button { m.clear() } label: { Label("Pulisci tutto", systemImage: "xmark.circle") }
                    .buttonStyle(.borderless).font(.caption)
                    .disabled(m.busy || (m.text.isEmpty && !m.useDate && !m.useKind && m.all.isEmpty && !m.searching))
            }
            if m.searching { SearchProgressBar().padding(.vertical, 2) }
            Text(m.summary).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var originCard: some View {
        PlaceCard(role: "ORIGINE", symbol: "magnifyingglass", color: .blue,
                  path: m.searchRoots.isEmpty ? nil : m.placesSummary, placeholder: "Scegli almeno un posto",
                  missing: m.searchRoots.isEmpty) {
            Button("Aggiungi cartella…") { m.chooseScope() }
            if !m.folders.isEmpty { Button("Togli cartelle") { m.folders = [] } }
        }
    }

    private var destinationCard: some View {
        PlaceCard(role: "DESTINAZIONE", symbol: "folder.fill", color: .teal,
                  path: m.destination?.path, placeholder: "Scegli la cartella di destinazione",
                  missing: m.destination == nil) {
            Button(m.destination == nil ? "Scegli cartella…" : "Cambia…") { m.chooseDestination() }
            Button("Rimuovi") { m.useDestination = false }
        }
    }

    private var addDestinationCard: some View {
        Button { m.useDestination = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.teal)
                    .frame(width: 40, height: 40)
                    .background(Circle().strokeBorder(Color.teal.opacity(0.6), lineWidth: 1.5))
                VStack(alignment: .leading, spacing: 2) {
                    Text("DESTINAZIONE · facoltativa").font(.caption.weight(.heavy)).foregroundStyle(Color.teal)
                    Text("Copia o sposta i file trovati in una cartella")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.teal.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var destinationSlot: some View {
        Group { if m.useDestination { destinationCard } else { addDestinationCard } }
    }

    /// Il nome con le parole cercate evidenziate.
    private func highlighted(_ name: String) -> AttributedString {
        var out = AttributedString(name)
        guard m.useName else { return out }
        for w in m.text.split(separator: " ").map(String.init) where !w.isEmpty {
            var from = name.startIndex
            while let r = name.range(of: w, options: [.caseInsensitive, .diacriticInsensitive], range: from..<name.endIndex) {
                if let lo = AttributedString.Index(r.lowerBound, within: out), let hi = AttributedString.Index(r.upperBound, within: out) {
                    out[lo..<hi].backgroundColor = Color.yellow.opacity(0.35)
                }
                from = r.upperBound
            }
        }
        return out
    }

    /// Dove si trova il file: disco (Mac, esterno o di rete) e percorso a briciole, con la cartella che lo contiene in evidenza.
    private func location(of url: URL) -> (badge: String, symbol: String, color: Color, crumbs: String, parent: String) {
        var path = url.deletingLastPathComponent().path
        var badge = "Questo Mac", symbol = "desktopcomputer", color = Color.blue
        if path.hasPrefix("/Volumes/") {
            let parts = path.dropFirst("/Volumes/".count).split(separator: "/", omittingEmptySubsequences: true)
            let name = parts.first.map(String.init) ?? "Disco"
            let network = m.volumes.first { $0.url.lastPathComponent == name }?.network ?? false
            badge = name
            symbol = network ? "network" : "externaldrive"
            color = network ? .purple : .teal
            path = "/" + parts.dropFirst().joined(separator: "/")
        } else if path.hasPrefix(NSHomeDirectory()) {
            path = "Home" + path.dropFirst(NSHomeDirectory().count)
        }
        var comps = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let parent = comps.popLast() ?? (path == "/" ? "Radice del disco" : "")
        // Le cartelle intermedie troppo lunghe si accorciano: restano le ultime tre.
        var prefix = comps.suffix(3).joined(separator: " › ")
        if comps.count > 3 { prefix = "… › " + prefix }
        return (badge, symbol, color, prefix.isEmpty ? "" : prefix + " › ", parent)
    }

    /// Anteprima di tutti i risultati, partendo dal file selezionato (o dal primo).
    private func previewIndex() -> Int {
        m.hits.firstIndex { m.selection.contains($0.id) } ?? 0
    }

    private func preview() { QuickLook.shared.toggle(m.hits.map(\.url), index: previewIndex()) }

    private var resultsList: some View {
        List(m.hits, selection: $m.selection) { h in
            HStack(spacing: 12) {
                FileThumbnail(url: h.url)
                VStack(alignment: .leading, spacing: 2) {
                    Text(highlighted(h.name))
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle)
                    let loc = location(of: h.url)
                    HStack(spacing: 6) {
                        Label(loc.badge, systemImage: loc.symbol)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(loc.color)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(loc.color.opacity(0.16)))
                            .lineLimit(1)
                        (Text(loc.crumbs).foregroundStyle(.secondary)
                         + Text(loc.parent).fontWeight(.semibold).foregroundStyle(.primary))
                            .font(.system(size: 12))
                            .lineLimit(1).truncationMode(.head)
                    }
                    .help(h.url.deletingLastPathComponent().path)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    if let s = h.size {
                        Text(ByteCountFormatter.string(fromByteCount: s, countStyle: .file))
                            .font(.system(size: 12, weight: .medium))
                    }
                    if let d = h.date {
                        Text(d.formatted(date: .abbreviated, time: .omitted))
                            .font(.system(size: 11, weight: .regular)).foregroundStyle(.secondary)
                    }
                }
                .monospacedDigit()
                .fixedSize()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([h.url])
                } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless)
                    .help("Mostra nel Finder")
            }
            .padding(.vertical, 5)
            .tag(h.id)
        }
        .scrollContentBackground(.hidden)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .glass(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contextMenu(forSelectionType: String.self) { ids in
            Button("Anteprima") { preview() }
            Button("Mostra nel Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(ids.map { URL(fileURLWithPath: $0) })
            }
        } primaryAction: { _ in preview() }
        .focused($listFocused)
        .onAppear { listFocused = true }
        .onKeyPress(.space) { preview(); return .handled }
        .onChange(of: m.selection) { _ in
            listFocused = true   // la barra spaziatrice non deve finire nel campo di testo
            QuickLook.shared.follow(previewIndex())
        }
        .frame(minHeight: 180, idealHeight: 280, maxHeight: .infinity)
    }

    private func actionBar(medium: Bool) -> some View {
        let note = Group {
            if m.destination == nil && !m.hits.isEmpty {
                Label("Scegli prima la cartella di destinazione", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.callout)
            } else if !m.hits.isEmpty {
                Text(m.status).foregroundStyle(.secondary).font(.callout).lineLimit(2)
            }
            if m.busy { ProgressView().controlSize(.small) }
        }
        let buttons = HStack {
            if !m.lastMoved.isEmpty {
                Button("Annulla ultimo spostamento") { m.undoMove() }.disabled(m.busy)
            }
            Button("Sposta \(m.selectedHits.count) file…") { confirmMove = true }
                .disabled(m.destination == nil || m.selection.isEmpty || m.busy)
            Button("Copia \(m.selectedHits.count) file") { m.transfer(move: false) }
                .prominentGlass()
                .disabled(m.destination == nil || m.selection.isEmpty || m.busy)
        }
        return Group {
            if medium {
                HStack { note; Spacer(); buttons }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack { note }
                    HStack { Spacer(); buttons }
                }
            }
        }
    }

    /// Animazione (finché non ci sono risultati) oppure elenco dei file trovati con le relative azioni.
    private func resultsArea(medium: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if m.hits.isEmpty {
                VStack(spacing: 8) {
                    SearchCoachView(name: m.useName, date: m.useDate, kind: m.useKind ? m.kind : nil,
                                    copy: m.useDestination, sideBySide: medium,
                                    toggles: [$m.useName, $m.useDate, $m.useKind])
                    Text(m.status).foregroundStyle(.secondary).font(.callout)
                        .multilineTextAlignment(.center)
                    if m.searching { SearchProgressBar().frame(maxWidth: 280) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                resultsList
                HStack {
                    Text(m.useDestination ? "\(m.hits.count) trovati · \(m.selectedHits.count) selezionati"
                                          : "\(m.hits.count) file trovati")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button { preview() } label: { Label("Anteprima · Spazio", systemImage: "eye") }
                        .help("Seleziona un file e premi la barra spaziatrice, come nel Finder")
                    if m.useDestination {
                        Button("Seleziona tutto") { m.selection = Set(m.hits.map(\.id)) }
                        Button("Deseleziona") { m.selection = [] }
                    }
                }
                .font(.callout)
            }

            if m.useDestination {
                Divider()
                actionBar(medium: medium)
            }
        }
    }

    private var resultsOnly: Bool { !m.hits.isEmpty && !editing }

    /// Dopo la ricerca: solo i risultati, con una barra per tornare ai comandi o ricominciare.
    private var resultsOnlyView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button { editing = true } label: { Label("Modifica ricerca", systemImage: "slider.horizontal.3") }
                Text(m.criteriaBits)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                if m.searching {
                    ProgressView().controlSize(.small)
                    Button("Interrompi") { m.stop() }
                }
                if !m.useDestination {
                    Button { m.useDestination = true } label: { Label("Copia o sposta…", systemImage: "folder.badge.plus") }
                }
                Button { m.clear() } label: { Label("Nuova ricerca", systemImage: "xmark.circle") }
            }
            .font(.system(size: 12, weight: .medium))
            if m.searching {
                SearchProgressBar()
                Text(m.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if m.useDestination { destinationCard }
            resultsArea(medium: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding()
    }

    /// Finestra stretta: tutto in colonna, comandi sopra e risultati sotto.
    private func stacked(medium: Bool, wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            stepsCard(medium: medium, wide: wide)
            actionsCard
            PaneDivider(stored: $searchPaneHeight, current: searchPaneHeight > 0 ? CGFloat(searchPaneHeight) : 260,
                        range: 160...900, vertical: true, inverted: true)
            resultsArea(medium: medium)
                .frame(minHeight: searchPaneHeight > 0 ? CGFloat(searchPaneHeight) : nil)
        }
    }

    /// Finestra larga: comandi a sinistra (con Cerca sempre visibile), animazione o risultati a destra.
    private func twoColumns(width: CGFloat) -> some View {
        let maxLeft = max(width - 32 - 16 - 300, 320)
        let left = searchPaneWidth > 0 ? min(max(CGFloat(searchPaneWidth), 320), maxLeft)
                                       : min(max(width * 0.52, 440), 600)
        let rightWidth = width - left - 16 - 32
        return HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                ScrollView(.vertical) {
                    stepsCard(medium: false, wide: false)
                        .padding(.trailing, 6)
                }
                actionsCard
            }
            .frame(width: left)
            PaneDivider(stored: $searchPaneWidth, current: left, range: 320...maxLeft)
            resultsArea(medium: rightWidth >= 560)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding()
    }

    /// Finché non si sceglie nessun criterio, Genuzzu apre la sezione come un titolo.
    private var welcomeVisible: Bool { mascotVisible && !m.useName && !m.useDate && !m.useKind }

    private var welcomeHeader: some View {
        GenuzzuTitleBar(title: "Questa è la sezione di ricerca file", text: "Vuoi cercare un file per nome, per data, per tipo? Puoi anche scegliere più filtri contemporaneamente.")
    }

    var body: some View {
        // Se la finestra è bassa il contenuto scorre; se è alta l'elenco dei risultati occupa lo spazio in più.
        VStack(spacing: 0) {
            if welcomeVisible { welcomeHeader.transition(.move(edge: .top).combined(with: .opacity)) }
            if resultsOnly {
                resultsOnlyView
            } else {
            GeometryReader { geo in
                if geo.size.width >= twoColumnWidth {
                    twoColumns(width: geo.size.width)
                } else {
                    ScrollView(.vertical) {
                        stacked(medium: geo.size.width >= mediumWidth, wide: geo.size.width >= wideWidth)
                            .padding()
                            .frame(minHeight: geo.size.height)
                    }
                }
            }
            }
        }
        .onChange(of: m.searching) { if $0 { editing = false } }
        .onChange(of: m.hits.isEmpty) { if $0 { editing = false } }
        .animation(.easeInOut(duration: 0.25), value: welcomeVisible)
        .frame(minWidth: 500, minHeight: 420)
        .background {
            Color.clear.alert("Vuoi riordinare i file in “\(m.offerSort?.lastPathComponent ?? "")”?",
                              isPresented: Binding(get: { m.offerSort != nil },
                                                   set: { if !$0 { m.offerSort = nil } })) {
                Button("Riordina") {
                    if let url = m.offerSort { m.offerSort = nil; onSort(url) }
                }
                Button("No, grazie", role: .cancel) {}
            } message: {
                Text("Li dispone in sottocartelle per data e tipo, come la sezione Metti in ordine. Vedrai prima l'anteprima e non verrà toccato nulla finché non confermi. Verrà considerata l'intera cartella, compresi i file che c'erano già.")
            }
        }
        .alert("Spostare \(m.selectedHits.count) file?", isPresented: $confirmMove) {
            Button("Sposta") { m.transfer(move: true) }
            Button("Cancella", role: .cancel) {}
        } message: {
            Text("I file originali verranno tolti dalla loro posizione e messi in “\(m.destination?.lastPathComponent ?? "")”. Potrai annullare subito dopo.")
        }
    }
}

/// Riga ricorsiva della barra laterale: si espande per mostrare le sottocartelle e si può trascinare nell'area di drop.
struct FolderRow: View {
    let name: String
    let symbol: String
    let url: URL
    /// Le posizioni di primo livello non vengono lette finché non si aprono (evita richieste di permesso all'avvio).
    var probe = true
    @ObservedObject var vm: ViewModel

    @State private var expanded = false
    @State private var children: [URL]?

    private static func subfolders(of url: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: [.skipsHiddenFiles])) ?? []
        return urls.filter {
            let v = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            return v?.isDirectory == true && v?.isPackage != true
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func load() { if children == nil { children = Self.subfolders(of: url) } }

    private var label: some View {
        Label(name, systemImage: symbol)
            .tag(url.standardizedFileURL.path)
            .draggable(url)
            .contextMenu { Button("Ordina questa cartella") { vm.setFolder(url) } }
    }

    var body: some View {
        Group {
            if children?.isEmpty == true {
                label
            } else {
                DisclosureGroup(isExpanded: $expanded) {
                    ForEach(children ?? [], id: \.path) { child in
                        FolderRow(name: child.lastPathComponent, symbol: "folder", url: child, vm: vm)
                    }
                } label: { label }
            }
        }
        .task { if probe { load() } }
        .onChange(of: expanded) { if $0 { load() } }
    }
}

/// Barra laterale in stile Finder: si naviga tra le cartelle e si trascina quella da ordinare nell'area di drop.
struct SidebarView: View {
    @ObservedObject var vm: ViewModel
    @State private var selection: String?

    private struct Place: Identifiable {
        let name: String
        let symbol: String
        let url: URL
        var id: String { url.standardizedFileURL.path }
    }

    private static func places() -> [Place] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let candidates: [(String, String, URL)] = [
            ("Scrivania", "menubar.dock.rectangle", home.appendingPathComponent("Desktop")),
            ("Documenti", "doc", home.appendingPathComponent("Documents")),
            ("Download", "arrow.down.circle", home.appendingPathComponent("Downloads")),
            ("Immagini", "photo", home.appendingPathComponent("Pictures")),
            ("Filmati", "film", home.appendingPathComponent("Movies")),
            ("Musica", "music.note", home.appendingPathComponent("Music")),
            (NSUserName(), "house", home),
            ("iCloud Drive", "icloud",
             home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")),
        ]
        return candidates.filter { fm.fileExists(atPath: $0.2.path) }
            .map { Place(name: $0.0, symbol: $0.1, url: $0.2) }
    }

    private static func volumes() -> [Place] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsLocalKey, .volumeIsRootFileSystemKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap {
            guard $0.path.hasPrefix("/Volumes/"),
                  let v = try? $0.resourceValues(forKeys: Set(keys)), v.volumeIsRootFileSystem != true else { return nil }
            return Place(name: v.volumeName ?? $0.lastPathComponent,
                         symbol: v.volumeIsLocal == false ? "server.rack" : "externaldrive", url: $0)
        }
    }

    /// I dischi si montano e smontano mentre l'app è aperta (NAS compreso): l'elenco va riletto.
    @State private var volumes: [Place] = SidebarView.volumes()

    var body: some View {
        List(selection: $selection) {
            Section("Preferiti") {
                ForEach(Self.places()) { p in
                    FolderRow(name: p.name, symbol: p.symbol, url: p.url, probe: false, vm: vm)
                }
            }
            if !volumes.isEmpty {
                Section("Posizioni") {
                    ForEach(volumes) { p in
                        FolderRow(name: p.name, symbol: p.symbol, url: p.url, probe: false, vm: vm)
                    }
                }
            }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            volumes = Self.volumes()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            volumes = Self.volumes()
        }
        .listStyle(.sidebar)
    }
}

/// Area di rilascio delle cartelle (mostrata quando non c'è un'anteprima).
struct DropZoneView: View {
    @ObservedObject var vm: ViewModel
    let targeted: Bool

    var body: some View {
        VStack(spacing: 10) {
            if vm.busy {
                ProgressView()
                Text(vm.status).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else if let folder = vm.folder {
                Image(systemName: "checkmark.circle").font(.system(size: 40)).foregroundStyle(.secondary)
                Text(folder.lastPathComponent).font(.headline).lineLimit(1).truncationMode(.middle)
                Text(vm.status).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Text("Trascina qui un'altra cartella per cambiarla")
                    .font(.caption).foregroundStyle(.tertiary)
            } else {
                Image(systemName: targeted ? "folder.fill.badge.plus" : "folder.badge.plus")
                    .font(.system(size: 52))
                    .foregroundStyle(targeted ? Color.accentColor : .secondary)
                    .scaleEffect(targeted ? 1.12 : 1)
                Text("Trascina qui la cartella da riordinare").font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                Text("dall'elenco a sinistra, da Finder oppure").font(.caption).foregroundStyle(.tertiary)
                Button("Scegli cartella…") { vm.chooseFolder() }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glass(RoundedRectangle(cornerRadius: 20, style: .continuous), tint: targeted ? Color.accentColor.opacity(0.5) : nil)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.5),
                              style: StrokeStyle(lineWidth: targeted ? 3 : 2, dash: [9, 6]))
        )
        .animation(.easeOut(duration: 0.15), value: targeted)
    }
}

/// Anteprima ad albero di come apparirà la cartella dopo il riordino.
struct PreviewTreeView: View {
    @ObservedObject var vm: ViewModel
    @State private var mode = 0
    @State private var collapsed = Set<String>()

    private final class Node {
        var folders: [String: Node] = [:]
        var files: [PlannedMove] = []
        var count = 0
    }

    private struct Row: Identifiable {
        let id: String
        let depth: Int
        let name: String
        let isFolder: Bool
        let count: Int
        let note: String?
    }

    private func rows(before: Bool = false) -> [Row] {
        let root = Node()
        for m in vm.moves {
            let comps = vm.relative(before ? m.source : m.dest).split(separator: "/").map(String.init)
            var node = root
            node.count += 1
            for c in comps.dropLast() {
                if node.folders[c] == nil { node.folders[c] = Node() }
                node = node.folders[c]!
                node.count += 1
            }
            node.files.append(m)
        }
        var out: [Row] = [Row(id: "/", depth: 0, name: vm.folder?.lastPathComponent ?? "", isFolder: true,
                              count: root.count, note: nil)]
        func walk(_ node: Node, path: String, depth: Int) {
            for name in node.folders.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
                let child = node.folders[name]!
                let id = path + "/" + name
                out.append(Row(id: id, depth: depth, name: name, isFolder: true, count: child.count, note: nil))
                if !collapsed.contains(id) { walk(child, path: id, depth: depth + 1) }
            }
            let fileName = { (m: PlannedMove) in before ? m.source.lastPathComponent : m.dest.lastPathComponent }
            for m in node.files.sorted(by: { fileName($0).localizedStandardCompare(fileName($1)) == .orderedAscending }) {
                let name = fileName(m)
                let renamed = m.dest.lastPathComponent != m.source.lastPathComponent
                out.append(Row(id: m.id.uuidString, depth: depth, name: name, isFolder: false,
                               count: 0, note: before ? nil : m.duplicateOf.map { "doppione di \($0.lastPathComponent)" }
                                   ?? (renamed ? "da \(m.source.lastPathComponent)" : nil)))
            }
        }
        if !collapsed.contains("/") { walk(root, path: "", depth: 1) }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(mode == 0 ? "Prima e dopo il riordino" : "Dopo il riordino la tua cartella apparirà così")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Vista", selection: $mode) {
                Text("Prima e dopo").tag(0)
                Text("Struttura").tag(2)
                Text("Elenco spostamenti").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 380)

            if mode == 0 {
                HStack(alignment: .top, spacing: 10) {
                    treePane("Prima", symbol: "tray.full", rows: rows(before: true))
                    Image(systemName: "arrow.right").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(maxHeight: .infinity)
                    treePane("Dopo", symbol: "checkmark.seal", rows: rows())
                }
            } else if mode == 2 {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows()) { row in rowView(row) }
                    }
                    .padding(.vertical, 4)
                }
            } else {
                List(vm.moves) { m in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(vm.relative(m.source)).font(.body)
                        Text("→ " + vm.relative(m.dest)).font(.caption).foregroundStyle(.secondary)
                        if let o = m.duplicateOf {
                            Text("Identico a " + vm.relative(o)).font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glass(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func treePane(_ title: String, symbol: String, rows: [Row]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in rowView(row) }
                }
                .padding(.vertical, 4)
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.secondary.opacity(0.07)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        HStack(spacing: 6) {
            if row.isFolder {
                Image(systemName: collapsed.contains(row.id) ? "chevron.right" : "chevron.down")
                    .font(.caption2.weight(.bold)).foregroundStyle(.secondary).frame(width: 12)
                Image(systemName: "folder.fill").foregroundStyle(Color.accentColor)
                Text(row.name).fontWeight(row.depth <= 1 ? .semibold : .regular).lineLimit(1)
                Spacer(minLength: 8)
                Text("\(row.count)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            } else {
                Image(systemName: "doc").foregroundStyle(.secondary).frame(width: 12)
                Text(row.name).lineLimit(1).truncationMode(.middle)
                if let note = row.note { Text(note).font(.caption).foregroundStyle(.tertiary).lineLimit(1) }
                Spacer(minLength: 0)
            }
        }
        .padding(.leading, CGFloat(row.depth) * 18)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture {
            guard row.isFolder else { return }
            if collapsed.contains(row.id) { collapsed.remove(row.id) } else { collapsed.insert(row.id) }
        }
    }
}

/// Animazione in loop per la sezione "Cerca file": mostra i criteri scelti, l'app che trova i file e,
/// se la destinazione è attiva, la copia nella cartella.
struct SearchAnimationView: View {
    let name: Bool
    let date: Bool
    let kind: FileKind?
    let copy: Bool

    private struct Style {
        let symbol: String
        let color: Color
        let names: [String]
        let exts: [String]
    }

    private static func style(_ k: FileKind) -> Style {
        switch k {
        case .images: return Style(symbol: "photo", color: .blue, names: ["Vacanze", "Logo", "Scatto", "Foto"], exts: ["JPG", "PNG", "HEIC", "JPG"])
        case .video: return Style(symbol: "film", color: .purple, names: ["Intervista", "Clip", "Riprese", "Evento"], exts: ["MOV", "MP4", "MOV", "AVI"])
        case .audio: return Style(symbol: "music.note", color: .pink, names: ["Musica", "Voce", "Jingle", "Podcast"], exts: ["MP3", "WAV", "M4A", "MP3"])
        case .archives: return Style(symbol: "archivebox", color: .brown, names: ["Backup", "Progetto", "Materiali", "Archivio"], exts: ["ZIP", "ZIP", "DMG", "RAR"])
        case .documents, .all: return Style(symbol: "doc.text", color: .orange, names: ["Preventivo", "Fattura", "Note", "Ricevuta"], exts: ["PDF", "XLSX", "TXT", "DOCX"])
        }
    }

    private struct Item {
        let name: String, ext: String, symbol: String
        let color: Color
        let hit: Bool
        let date: String?
    }

    private static let defaultKinds: [FileKind] = [.documents, .images, .images, .documents, .video, .audio, .documents, .documents]
    private static let hitSlots = [0, 2, 5, 7]
    private static let missSlots = [1, 3, 4, 6]
    private static let inDates = ["12 ott", "15 ott", "19 ott", "24 ott"]
    private static let outDates = ["03 mar", "21 giu", "08 ago", "30 set"]
    private static let sample = "cliente"

    /// Senza nessun criterio attivo si mostra la ricerca per nome.
    private var showName: Bool { name || (!date && kind == nil) }
    private var criteriaCount: Int { (showName ? 1 : 0) + (date ? 1 : 0) + (kind != nil ? 1 : 0) }

    /// I file "trovati" rispettano tutti i criteri attivi; gli altri ne violano almeno uno.
    private var items: [Item] {
        (0..<8).map { i in
            let hit = Self.hitSlots.contains(i)
            var k = Self.defaultKinds[i]
            if let want = kind {
                if hit { k = want }
                else if k == want { k = [.documents, .images, .video, .audio].first { $0 != want } ?? .documents }
            }
            let st = Self.style(k)
            let base = st.names[i % 4]
            let label = showName && hit ? base + " " + Self.sample : base
            var when: String?
            if date {
                when = hit ? Self.inDates[Self.hitSlots.firstIndex(of: i) ?? 0]
                           : Self.outDates[Self.missSlots.firstIndex(of: i) ?? 0]
            }
            return Item(name: label, ext: st.exts[i % 4], symbol: st.symbol, color: st.color, hit: hit, date: when)
        }
    }

    // Tempi (secondi): i criteri compaiono uno alla volta, poi passa la lente, poi il risultato.
    private let typeStep = 0.12
    private let sweepLen = 2.0
    private let copyGap = 0.5, flight = 0.8
    private func appear(_ k: Int) -> Double { 0.4 + 0.8 * Double(k) }
    private var sweepStart: Double { 0.4 + 0.8 * Double(criteriaCount) + 0.8 }
    private var resultStart: Double { sweepStart + sweepLen + 0.9 }
    private var cycle: Double { resultStart + (copy ? copyGap * 3 + flight : 0.8) + 1.8 }

    private func ease(_ p: Double) -> Double { p * p * (3 - 2 * p) }
    private func passTime(_ col: Int) -> Double { sweepStart + sweepLen * (Double(col) + 0.5) / 4 }

    struct Narration { let text: String; let mood: GenuzzuMood }

    /// I passi che Genuzzu racconta, per ciascuna combinazione di criteri. Si scorrono a mano.
    var script: [Narration] {
        let d = date, k = kind != nil
        let n = showName
        let intro: String, how: String, find: String
        switch (n, d, k) {
        case (true, false, false):
            intro = "Ecco come cercare per nome: scrivi una parte del nome del file, anche una sola parola, poi premi Invio."
            how = "Più parole vuol dire che devono esserci tutte nel nome. Poi premi Cerca."
            find = "Controllo il nome di ogni file, nelle cartelle che hai scelto: restano accesi solo quelli che lo contengono."
        case (false, true, false):
            intro = "Ecco come cercare per data: clicca due giorni sul calendario per scegliere il periodo."
            how = "Con Modificati o Creati decidi quale data guardare. Poi premi Cerca."
            find = "Controllo la data di ogni file: restano accesi solo quelli dentro al periodo che hai scelto."
        case (false, false, true):
            intro = "Ecco come cercare per tipo: scegli se ti servono immagini, video, audio, documenti o archivi."
            how = "Hai già scelto? Allora premi Cerca."
            find = "Controllo il tipo di ogni file: restano accesi solo quelli del tipo che hai scelto."
        case (true, true, false):
            intro = "Ecco come cercare per nome e data: scrivi una parte del nome e scegli il periodo sul calendario."
            how = "I due criteri valgono insieme. Poi premi Cerca."
            find = "Un file passa solo se ha il nome giusto e anche la data giusta. Gli altri si spengono."
        case (true, false, true):
            intro = "Ecco come cercare per nome e tipo: scrivi una parte del nome e scegli che tipo di file ti serve."
            how = "I due criteri valgono insieme. Poi premi Cerca."
            find = "Un file passa solo se ha il nome giusto ed è del tipo giusto. Gli altri si spengono."
        case (false, true, true):
            intro = "Ecco come cercare per data e tipo: scegli il periodo sul calendario e il tipo di file."
            how = "I due criteri valgono insieme. Poi premi Cerca."
            find = "Un file passa solo se è del tipo giusto e nel periodo giusto. Gli altri si spengono."
        default:
            intro = "Ecco come usare nome, data e tipo insieme: accendili tutti e tre e compila ciascuno."
            how = "Più criteri accendi, più la ricerca è precisa. Poi premi Cerca."
            find = "Un file passa solo se rispetta nome, data e tipo tutti insieme. Gli altri si spengono."
        }
        let done = copy ? "Trovati! Ora puoi copiarli o spostarli nella cartella di destinazione che hai scelto."
                        : "Trovati! Sono quelli col bordo giallo. Nell'elenco li apri nel Finder col tasto destro."
        return [Narration(text: intro, mood: .happy), Narration(text: how, mood: .happy),
                Narration(text: find, mood: .happy), Narration(text: done, mood: .wink)]
    }

    private func caption(_ t: Double) -> String {
        if t < sweepStart - 0.2 {
            switch (showName, date, kind != nil) {
            case (true, false, false): return "1  Scrivi una parte del nome del file"
            case (false, true, false): return "1  Scegli il periodo sul calendario"
            case (false, false, true): return "1  Scegli il tipo di file"
            default: return "1  Imposta i criteri: devono valere tutti insieme"
            }
        }
        if t < resultStart - 0.2 {
            return criteriaCount > 1 ? "2  L'app trova i file che rispettano tutti i criteri"
                                     : "2  L'app trova i file che rispettano il criterio"
        }
        return copy ? "3  Se vuoi, copiali o spostali nella cartella scelta" : "3  Ecco i file trovati"
    }

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle)
            GeometryReader { geo in
                scene(t: t, w: geo.size.width, h: geo.size.height)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .glass(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func scene(t: Double, w: CGFloat, h: CGFloat) -> some View {
        let list = items
        let hits = list.indices.filter { list[$0].hit }
        // Griglia dei file + colonna del risultato, centrate insieme nello spazio disponibile.
        let chipW: CGFloat = 62, resultW: CGFloat = 110
        let step = min(max((w - resultW - chipW - 16) / 3, 40), 72)
        let gridW = 3 * step + chipW
        let left = max((w - gridW - resultW) / 2, 0)
        let cx = left + gridW / 2
        let point = { (i: Int) -> CGPoint in
            CGPoint(x: cx + (CGFloat(i % 4) - 1.5) * step, y: h * (i < 4 ? 0.42 : 0.70))
        }
        let target = CGPoint(x: left + gridW + resultW / 2, y: h * 0.56)
        let global = min(t / 0.4, 1, (cycle - t) / 0.4)

        ZStack {
            criteriaPill(t: t).position(x: w / 2, y: h * 0.12)
            ForEach(list.indices, id: \.self) { i in
                fileChip(list[i], col: i % 4, t: t).position(point(i))
            }
            magnifier(t: t, cx: cx, step: step, h: h)
            if copy {
                folder(t: t, count: hits.count).position(target)
                ForEach(hits.indices, id: \.self) { k in
                    flyingCopy(list[hits[k]], k: k, t: t, from: point(hits[k]), to: target)
                }
            } else {
                resultBadge(t: t, count: hits.count).position(target)
            }
            Text(caption(t))
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.7)
                .position(x: w / 2, y: h * 0.92)
        }
        .opacity(max(global, 0))
    }

    // MARK: Criteri in alto

    private func criteriaPill(t: Double) -> some View {
        var chips: [AnyView] = []
        var k = 0
        func add<V: View>(_ v: V) {
            let a = appear(k)
            let p = min(max((t - a) / 0.25, 0), 1)
            chips.append(AnyView(v.opacity(p).scaleEffect(0.85 + 0.15 * ease(p))))
            k += 1
        }
        if showName {
            let a = appear(k)
            let n = min(max(Int((t - a) / typeStep), 0), Self.sample.count)
            let caret = Int(t * 2) % 2 == 0 && t < sweepStart
            add(chip(symbol: "magnifyingglass", text: String(Self.sample.prefix(n)) + (caret ? "|" : ""),
                     mono: true, minWidth: 104))
        }
        if date { add(chip(symbol: "calendar", text: "Ottobre", mono: false, minWidth: 0)) }
        if let kd = kind { add(chip(symbol: Self.style(kd).symbol, text: kd.title, mono: false, minWidth: 0)) }
        return HStack(spacing: 8) { ForEach(chips.indices, id: \.self) { chips[$0] } }
    }

    private func chip(symbol: String, text: String, mono: Bool, minWidth: CGFloat) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(Color.accentColor)
            Text(text).font(mono ? .system(.body, design: .monospaced) : .body)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(minWidth: minWidth, alignment: .leading)
        .background(Capsule().fill(Color(nsColor: .textBackgroundColor)))
        .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.5)))
    }

    // MARK: File

    private func fileChip(_ f: Item, col: Int, t: Double) -> some View {
        let passed = t >= passTime(col)
        let hit = passed && f.hit
        let dim = passed && !f.hit
        return VStack(spacing: 3) {
            VStack(spacing: 2) {
                Image(systemName: f.symbol).font(.system(size: 17))
                Text(f.ext).font(.system(size: 8, weight: .bold, design: .rounded))
            }
            .foregroundStyle(.white)
            .frame(width: 42, height: 46)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(f.color.gradient))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.yellow, lineWidth: hit ? 3 : 0))
            Text(f.name).font(.system(size: 9)).lineLimit(1).minimumScaleFactor(0.6)
                .frame(width: 62)
                .foregroundStyle(hit ? Color.primary : .secondary)
            if let d = f.date {
                Text(d).font(.system(size: 8, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .scaleEffect(hit ? 1.08 : 1)
        .opacity(dim ? 0.3 : 1)
        .animation(.easeOut(duration: 0.2), value: hit)
        .animation(.easeOut(duration: 0.2), value: dim)
    }

    @ViewBuilder
    private func magnifier(t: Double, cx: CGFloat, step: CGFloat, h: CGFloat) -> some View {
        let p = (t - sweepStart) / sweepLen
        if p >= -0.05 && p <= 1.05 {
            let e = min(max(p, 0), 1)
            Image(systemName: "magnifyingglass.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(Color.accentColor)
                .shadow(radius: 3, y: 2)
                .position(x: cx + (CGFloat(e) - 0.5) * step * 4.4,
                          y: h * 0.56 + CGFloat(sin(e * .pi * 3)) * h * 0.12)
        }
    }

    // MARK: Risultato

    private func resultBadge(t: Double, count: Int) -> some View {
        let p = min(max((t - resultStart) / 0.35, 0), 1)
        return VStack(spacing: 4) {
            ZStack {
                Circle().fill(Color.accentColor.gradient).frame(width: 54, height: 54)
                Text("\(count)").font(.title2.bold().monospacedDigit()).foregroundStyle(.white)
            }
            Text("file trovati").font(.caption).foregroundStyle(.secondary)
        }
        .opacity(p)
        .scaleEffect(0.6 + 0.4 * ease(p))
    }

    private func folder(t: Double, count total: Int) -> some View {
        let arrivals = (0..<total).map { resultStart + Double($0) * copyGap + flight }
        let count = arrivals.filter { t >= $0 }.count
        let bump = arrivals.map { a -> Double in
            let d = t - a
            return d >= 0 && d < 0.25 ? 1 - d / 0.25 : 0
        }.max() ?? 0
        return VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "folder.fill").font(.system(size: 54)).foregroundStyle(Color.teal.gradient)
                if count > 0 {
                    Text("\(count)")
                        .font(.caption2.bold().monospacedDigit()).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(.red)).offset(x: 8, y: -6)
                }
            }
            .scaleEffect(1 + 0.14 * bump)
            Text("Cartella scelta").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func flyingCopy(_ f: Item, k: Int, t: Double, from: CGPoint, to: CGPoint) -> some View {
        let p = (t - (resultStart + Double(k) * copyGap)) / flight
        if p > 0 && p < 1 {
            let e = ease(p)
            Image(systemName: f.symbol)
                .font(.system(size: 17)).foregroundStyle(.white)
                .frame(width: 34, height: 38)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(f.color.gradient))
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                .scaleEffect(1 - 0.45 * e)
                .opacity(1 - pow(p, 4))
                .position(x: from.x + (to.x - from.x) * e,
                          y: from.y + (to.y - from.y) * e - CGFloat(sin(.pi * e)) * 30)
        }
    }
}

/// L'animazione della ricerca con Genuzzu a figura intera accanto, che spiega i passaggi uno alla volta.
struct SearchCoachView: View {
    let name: Bool
    let date: Bool
    let kind: FileKind?
    let copy: Bool
    /// Mascotte a destra dell'animazione (spazio largo) oppure sotto (spazio stretto).
    let sideBySide: Bool
    /// Gli interruttori di Nome, Data e Tipo: i riquadri dell'invito li accendono davvero.
    let toggles: [Binding<Bool>]
    @AppStorage("mascotVisible") private var visible = true

    var body: some View {
        let anim = SearchAnimationView(name: name, date: date, kind: kind, copy: copy)
        // Nessun criterio scelto: l'animazione invita a sceglierne uno.
        let idle = !name && !date && kind == nil
        let layout = sideBySide ? AnyLayout(HStackLayout(alignment: .center, spacing: 12))
                                : AnyLayout(VStackLayout(spacing: 8))
        layout {
            if idle { SearchInviteView(toggles: toggles).frame(minHeight: 220) } else { anim.frame(minHeight: 220) }
            if visible && !idle {
                // Cambiando i criteri si ricomincia dal primo passo.
                CoachBubble(script: idle ? SearchInviteView.script : anim.script, sideBySide: sideBySide)
                    .id("\(name)\(date)\(kind != nil)\(copy)")
            }
        }
    }
}

struct CoachBubble: View {
    let script: [SearchAnimationView.Narration]
    let sideBySide: Bool
    @State private var step = 0
    @State private var talking = true

    var body: some View {
        let line = script[min(step, script.count - 1)]
        let last = step >= script.count - 1
        let bubble = VStack(alignment: .leading, spacing: 6) {
            Text(line.text)
                .font(.system(size: 12.5))
                .fixedSize(horizontal: false, vertical: true)
                .id(step)
                .transition(.opacity)
            HStack(spacing: 8) {
                Text("\(step + 1) di \(script.count)").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if step > 0 {
                    Button { go(step - 1) } label: { Image(systemName: "chevron.left") }
                        .help("Indietro")
                }
                Button { go(last ? 0 : step + 1) } label: {
                    Label(last ? "Ricomincia" : "Avanti", systemImage: last ? "arrow.counterclockwise" : "chevron.right")
                        .labelStyle(.titleAndIcon)
                }
                .keyboardShortcut(.rightArrow, modifiers: [])
            }
            .buttonStyle(.borderless).font(.caption.weight(.semibold))
        }
        .padding(.vertical, 10).padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        let mascot = GenuzzuView(mood: line.mood, talking: talking, fullBody: true)
            .frame(width: 88, height: 150)
        return Group {
            if sideBySide {
                VStack(spacing: 0) {
                    bubble.glass(SpeechBubble(tail: .bottom))
                        .padding(.bottom, 9)
                    mascot
                }
                .frame(width: 210)
            } else {
                HStack(spacing: 2) {
                    mascot
                    bubble.padding(.leading, 9)
                        .glass(SpeechBubble(tail: .left))
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: step)
        .onAppear { speak() }
    }

    private func go(_ n: Int) {
        step = n
        speak()
    }

    private func speak() {
        talking = true
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            talking = false
        }
    }
}

/// Animazione d'invito, mostrata finché non si sceglie nessun criterio: Nome, Data e Tipo si accendono
/// uno alla volta e poi tutti insieme, per far capire che si può cercare in ogni modo.
struct SearchInviteView: View {
    static let script: [SearchAnimationView.Narration] = [
        .init(text: "Ciao! Cosa vuoi cercare? Puoi partire dal nome, dalla data o dal tipo di file.", mood: .happy),
        .init(text: "Clicca su Nome, Data o Tipo, qui o a sinistra: si accendono e ti mostrano cosa compilare.", mood: .happy),
        .init(text: "Ne puoi accendere uno solo oppure combinarli: valgono tutti insieme e la ricerca diventa più precisa.", mood: .happy),
        .init(text: "Quando hai scelto, premi Cerca. Io intanto resto qui a fare il tifo!", mood: .wink),
    ]

    /// Nome, Data e Tipo, nello stesso ordine dei riquadri.
    let toggles: [Binding<Bool>]

    private struct Tile { let title: String, symbol: String, sample: String }
    private let tiles = [Tile(title: "Nome", symbol: "textformat", sample: "cliente"),
                         Tile(title: "Data", symbol: "calendar", sample: "Ottobre"),
                         Tile(title: "Tipo", symbol: "square.grid.2x2", sample: "Immagini")]
    private let cycle = 9.0
    private let together = (from: 5.0, to: 7.8)

    private func ease(_ p: Double) -> Double { let c = min(max(p, 0), 1); return c * c * (3 - 2 * c) }
    /// 1 tra `a` e `b`, con una breve dissolvenza ai bordi.
    private func win(_ t: Double, _ a: Double, _ b: Double) -> Double {
        ease((t - a) / 0.25) * (1 - ease((t - b) / 0.25))
    }

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle)
            GeometryReader { geo in scene(t: t, w: geo.size.width, h: geo.size.height) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .glass(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityHidden(true)
    }

    private func scene(t: Double, w: CGFloat, h: CGFloat) -> some View {
        let tileW = min(max((w - 48) / 3 - 14, 64), 96)
        let gap = tileW + 16
        let global = min(t / 0.4, 1, (cycle - t) / 0.4)
        let all = win(t, together.from, together.to)
        let caption = t < together.from - 0.2 ? "Scegli un criterio…" : "…oppure combinali tutti insieme"
        return ZStack {
            Text("Cosa vuoi cercare?").font(.title3.weight(.semibold))
                .position(x: w / 2, y: h * 0.14)
            ForEach(tiles.indices, id: \.self) { i in
                let on = max(win(t, 0.6 + 1.3 * Double(i), 1.7 + 1.3 * Double(i)), all)
                Button { toggles[i].wrappedValue = true } label: { tile(tiles[i], on: on, width: tileW) }
                    .buttonStyle(.plain)
                    .help("Cerca per \(tiles[i].title.lowercased())")
                    .position(x: w / 2 + CGFloat(i - 1) * gap, y: h * 0.48)
            }
            ForEach(0..<2, id: \.self) { i in
                Image(systemName: "plus").font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                    .opacity(win(t, together.from + 0.3, together.to))
                    .position(x: w / 2 + (CGFloat(i) - 0.5) * gap, y: h * 0.48)
            }
            Image(systemName: "magnifyingglass.circle.fill").font(.system(size: 34))
                .foregroundStyle(Color.accentColor)
                .opacity(all)
                .scaleEffect(0.7 + 0.3 * all)
                .position(x: w / 2, y: h * 0.76)
            Text(caption).font(.callout.weight(.medium)).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.7)
                .position(x: w / 2, y: h * 0.92)
        }
        .opacity(max(global, 0))
    }

    private func tile(_ f: Tile, on: Double, width: CGFloat) -> some View {
        VStack(spacing: 6) {
            Image(systemName: f.symbol).font(.system(size: 24))
                .foregroundStyle(on > 0.5 ? Color.accentColor : .secondary)
            Text(f.title).font(.headline)
            Text(f.sample).font(.system(size: 10, design: .monospaced))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color(nsColor: .textBackgroundColor)))
                .opacity(0.4 + 0.6 * on)
        }
        .frame(width: width, height: 100)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.accentColor.opacity(0.04 + 0.14 * on)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(on > 0.5 ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: on > 0.5 ? 2 : 1))
        .scaleEffect(1 + 0.08 * on)
    }
}

/// Animazione in loop: file sparsi che finiscono ciascuno nella cartella del proprio tipo.
struct SortAnimationView: View {
    private struct Item {
        let symbol: String
        let ext: String
        let color: Color
        let folder: Int
        let x: CGFloat, y: CGFloat   // posizione iniziale, in frazioni dell'area
        let rotation: Double
    }

    private static let folders: [(name: String, color: Color)] = [
        ("Immagini", .blue), ("Documenti", .orange), ("Video", .purple),
    ]

    private static let items: [Item] = [
        Item(symbol: "photo", ext: "JPG", color: .blue, folder: 0, x: 0.16, y: 0.14, rotation: -12),
        Item(symbol: "doc.text", ext: "PDF", color: .orange, folder: 1, x: 0.40, y: 0.30, rotation: 9),
        Item(symbol: "film", ext: "MP4", color: .purple, folder: 2, x: 0.80, y: 0.12, rotation: 14),
        Item(symbol: "photo", ext: "PNG", color: .blue, folder: 0, x: 0.62, y: 0.38, rotation: -6),
        Item(symbol: "doc.text", ext: "DOCX", color: .orange, folder: 1, x: 0.12, y: 0.42, rotation: 16),
        Item(symbol: "film", ext: "MOV", color: .purple, folder: 2, x: 0.34, y: 0.08, rotation: -15),
        Item(symbol: "photo", ext: "HEIC", color: .blue, folder: 0, x: 0.88, y: 0.40, rotation: 7),
        Item(symbol: "doc.text", ext: "TXT", color: .orange, folder: 1, x: 0.58, y: 0.10, rotation: -9),
        Item(symbol: "film", ext: "AVI", color: .purple, folder: 2, x: 0.24, y: 0.30, rotation: 5),
    ]

    private let cycle = 8.0          // durata del loop
    private let firstStart = 1.0     // pausa iniziale con i file ancora sparsi
    private let gap = 0.45           // intervallo tra un file e il successivo
    private let flight = 0.8         // durata del volo di un file
    private let fade = 0.5           // dissolvenza di inizio ciclo

    private func start(_ i: Int) -> Double { firstStart + Double(i) * gap }
    private func ease(_ p: Double) -> Double { p * p * (3 - 2 * p) }

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle)
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                let folderY = h * 0.74
                let folderX = { (f: Int) in w * (0.2 + 0.3 * CGFloat(f)) }

                ZStack {
                    ForEach(0..<Self.folders.count, id: \.self) { f in
                        let arrivals = Self.items.indices.filter { Self.items[$0].folder == f }
                            .map { start($0) + flight }
                        let count = arrivals.filter { t >= $0 }.count
                        let bump = arrivals.map { a -> Double in
                            let d = t - a
                            return d >= 0 && d < 0.25 ? 1 - d / 0.25 : 0
                        }.max() ?? 0

                        VStack(spacing: 4) {
                            ZStack(alignment: .topTrailing) {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 54))
                                    .foregroundStyle(Self.folders[f].color.gradient)
                                if count > 0 {
                                    Text("\(count)")
                                        .font(.caption2.bold().monospacedDigit())
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Capsule().fill(.red))
                                        .offset(x: 8, y: -6)
                                }
                            }
                            .scaleEffect(1 + 0.14 * bump)
                            Text(Self.folders[f].name).font(.caption).foregroundStyle(.secondary)
                        }
                        .position(x: folderX(f), y: folderY)
                    }

                    ForEach(Self.items.indices, id: \.self) { i in
                        let item = Self.items[i]
                        let p = min(max((t - start(i)) / flight, 0), 1)
                        if p < 1 {
                            let e = ease(p)
                            let from = CGPoint(x: w * item.x, y: h * item.y)
                            let to = CGPoint(x: folderX(item.folder), y: folderY - 8)
                            VStack(spacing: 2) {
                                Image(systemName: item.symbol).font(.system(size: 18))
                                Text(item.ext).font(.system(size: 9, weight: .bold, design: .rounded))
                            }
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 50)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(item.color.gradient))
                                .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                                .rotationEffect(.degrees(item.rotation * (1 - e)))
                                .scaleEffect(1 - 0.5 * e)
                                .opacity(min(t / fade, 1) * (1 - pow(p, 4)))
                                .position(x: from.x + (to.x - from.x) * e,
                                          y: from.y + (to.y - from.y) * e - sin(.pi * e) * 28)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .glass(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityHidden(true)
    }
}

// MARK: - Genuzzu, la mascotte

enum GenuzzuMood { case happy, shocked, oops, wink }

/// Genuzzu disegnato a vettori: testa grande, contorni neri spessi, occhioni e hatching sulle guance (stile manga anni '90).
struct GenuzzuView: View {
    var mood: GenuzzuMood = .happy
    var talking = false
    /// Figura intera (testa, busto, braccia, gambe) invece del solo mezzo busto.
    var fullBody = false

    private static let skin = Color(red: 0.99, green: 0.83, blue: 0.65)
    private static let shirt = Color(red: 0.12, green: 0.18, blue: 0.40)
    private static let iris = Color(red: 0.48, green: 0.29, blue: 0.13)
    private static let ink = Color.black

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let h: CGFloat = fullBody ? 345 : 190
                let s = min(size.width / 200, size.height / h)
                var c = ctx
                c.translateBy(x: (size.width - 200 * s) / 2, y: (size.height - h * s) / 2)
                c.scaleBy(x: s, y: s)
                // Dondola appena, come uno che non sta mai fermo (a figura intera resta con i piedi a terra).
                let pivot: CGFloat = fullBody ? 330 : 175
                c.translateBy(x: 100, y: pivot + (fullBody ? 0 : sin(t * 2.2) * 1.5))
                c.rotate(by: .degrees(sin(t * 1.3) * (fullBody ? 1.0 : 1.8)))
                c.translateBy(x: -100, y: -pivot)
                let blink = t.truncatingRemainder(dividingBy: 4.3) < 0.14
                let open = talking ? 0.35 + 0.65 * abs(sin(t * 9)) : 0.55
                if fullBody { Self.drawBody(c, wave: sin(t * 3.2), talking: talking) }
                Self.draw(c, mood: mood, blink: blink, open: open, look: sin(t * 0.7) * 2, fullBody: fullBody)
            }
        }
        .accessibilityHidden(true)
    }

    private static func stroke(_ c: GraphicsContext, _ p: Path, _ w: CGFloat = 3.5, _ color: Color = ink) {
        c.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
    }

    private static func fillStroke(_ c: GraphicsContext, _ p: Path, _ fill: Color, _ w: CGFloat = 3.5) {
        c.fill(p, with: .color(fill))
        stroke(c, p, w)
    }

    private static func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }

    /// Busto, braccia e gambe: il braccio sinistro (a sinistra di chi guarda) indica l'animazione.
    private static func drawBody(_ c: GraphicsContext, wave: Double, talking: Bool) {
        let jeans = Color(white: 0.30)
        let w = CGFloat(talking ? wave : 0) * 5
        // Gambe e scarpe
        for x: CGFloat in [62, 104] {
            fillStroke(c, Path(roundedRect: CGRect(x: x, y: 256, width: 34, height: 66), cornerRadius: 8), jeans)
            fillStroke(c, Path(ellipseIn: CGRect(x: x - 6, y: 316, width: 46, height: 22)), .white)
        }
        // Busto
        var torso = Path()
        torso.move(to: CGPoint(x: 46, y: 190))
        torso.addLine(to: CGPoint(x: 52, y: 262))
        torso.addLine(to: CGPoint(x: 148, y: 262))
        torso.addLine(to: CGPoint(x: 154, y: 190))
        torso.closeSubpath()
        fillStroke(c, torso, shirt)
        // Ogni braccio è un tratto per la manica e uno per l'avambraccio: prima l'avambraccio, poi la manica sopra.
        func seg(_ from: CGPoint, _ to: CGPoint, _ color: Color, _ width: CGFloat) {
            var path = Path()
            path.move(to: from)
            path.addLine(to: to)
            stroke(c, path, width + 5)
            stroke(c, path, width, color)
        }
        // Braccio che indica l'animazione (a sinistra di chi guarda), con la mano che saluta
        let hand = CGPoint(x: 20 + w * 1.2, y: 170)
        seg(CGPoint(x: 28, y: 226), hand, skin, 11)
        seg(CGPoint(x: 52, y: 205), CGPoint(x: 28, y: 226), shirt, 17)
        fillStroke(c, circle(hand.x, hand.y - 4, 10), skin, 3)
        // Braccio lungo il fianco
        seg(CGPoint(x: 160, y: 238), CGPoint(x: 158, y: 268), skin, 11)
        seg(CGPoint(x: 148, y: 205), CGPoint(x: 160, y: 238), shirt, 17)
        fillStroke(c, circle(158, 275, 9), skin, 3)
    }

    private static func draw(_ c: GraphicsContext, mood: GenuzzuMood, blink: Bool, open: Double, look: Double,
                             fullBody: Bool = false) {
        // Maglietta blu e collo
        var shirtPath = Path()
        shirtPath.move(to: CGPoint(x: 44, y: 194))
        shirtPath.addCurve(to: CGPoint(x: 78, y: 166), control1: CGPoint(x: 46, y: 176), control2: CGPoint(x: 62, y: 170))
        shirtPath.addLine(to: CGPoint(x: 122, y: 166))
        shirtPath.addCurve(to: CGPoint(x: 156, y: 194), control1: CGPoint(x: 138, y: 170), control2: CGPoint(x: 154, y: 176))
        shirtPath.closeSubpath()
        fillStroke(c, Path(CGRect(x: 86, y: 150, width: 28, height: 24)), skin)
        if fullBody {
            // Il resto della maglietta è già disegnato: qui solo spalle e colletto, senza il bordo in basso.
            c.fill(shirtPath, with: .color(shirt))
            var shoulders = Path()
            shoulders.move(to: CGPoint(x: 44, y: 194))
            shoulders.addCurve(to: CGPoint(x: 78, y: 166), control1: CGPoint(x: 46, y: 176), control2: CGPoint(x: 62, y: 170))
            shoulders.addLine(to: CGPoint(x: 122, y: 166))
            shoulders.addCurve(to: CGPoint(x: 156, y: 194), control1: CGPoint(x: 138, y: 170), control2: CGPoint(x: 154, y: 176))
            stroke(c, shoulders)
        } else {
            fillStroke(c, shirtPath, shirt)
        }
        var neck = Path()
        neck.move(to: CGPoint(x: 83, y: 166))
        neck.addQuadCurve(to: CGPoint(x: 117, y: 166), control: CGPoint(x: 100, y: 190))
        neck.closeSubpath()
        fillStroke(c, neck, skin, 3)

        // Orecchie con cerchietti d'argento
        for x: CGFloat in [44, 156] {
            fillStroke(c, circle(x, 108, 11), skin)
            stroke(c, circle(x + (x < 100 ? -1 : 1), 124, 6), 2.6, Color(white: 0.78))
        }

        // Faccia
        var face = Path()
        face.move(to: CGPoint(x: 46, y: 100))
        face.addCurve(to: CGPoint(x: 100, y: 166), control1: CGPoint(x: 46, y: 142), control2: CGPoint(x: 70, y: 166))
        face.addCurve(to: CGPoint(x: 154, y: 100), control1: CGPoint(x: 130, y: 166), control2: CGPoint(x: 154, y: 142))
        face.addCurve(to: CGPoint(x: 100, y: 52), control1: CGPoint(x: 154, y: 66), control2: CGPoint(x: 130, y: 52))
        face.addCurve(to: CGPoint(x: 46, y: 100), control1: CGPoint(x: 70, y: 52), control2: CGPoint(x: 46, y: 66))
        fillStroke(c, face, skin)

        // Tratteggio sulle guance
        for (dx, dy) in [(0.0, 0.0), (2.0, 6.0), (4.0, 12.0)] {
            for side in [-1.0, 1.0] {
                var h = Path()
                let x = 100 + side * (44 - dx)
                h.move(to: CGPoint(x: x, y: 122 + dy))
                h.addLine(to: CGPoint(x: x + side * -9, y: 126 + dy))
                stroke(c, h, 2, Color(red: 0.85, green: 0.5, blue: 0.3))
            }
        }

        // Barba corta
        for i in 0..<70 {
            let x = 66 + Double((i * 29) % 69)
            let y = 138 + Double((i * 17) % 26)
            if x > 79 && x < 121 && y < 160 { continue }
            c.fill(circle(x, y, 1.1), with: .color(Color(white: 0.2, opacity: 0.75)))
        }

        // Occhi
        for (i, cx) in [76.0, 124.0].enumerated() {
            let cy = 110.0
            if blink || (mood == .wink && i == 1) {
                var lid = Path()
                lid.move(to: CGPoint(x: cx - 15, y: cy + 2))
                lid.addQuadCurve(to: CGPoint(x: cx + 15, y: cy + 2), control: CGPoint(x: cx, y: mood == .wink ? cy - 12 : cy + 12))
                stroke(c, lid, 4)
                continue
            }
            let eye = Path(ellipseIn: CGRect(x: cx - 15, y: cy - 13, width: 30, height: 26))
            fillStroke(c, eye, .white, 3)
            let ir: CGFloat = mood == .shocked ? 6 : 8.5
            var inside = c
            inside.clip(to: eye)
            inside.fill(circle(cx + look, cy + 1, ir), with: .color(iris))
            inside.fill(circle(cx + look, cy + 1, ir * 0.5), with: .color(.black))
            inside.fill(circle(cx + look - 2.5, cy - 3, 2.4), with: .color(.white))
            var top = Path()
            top.move(to: CGPoint(x: cx - 16, y: cy - 2))
            top.addCurve(to: CGPoint(x: cx + 16, y: cy - 2), control1: CGPoint(x: cx - 12, y: cy - 18), control2: CGPoint(x: cx + 12, y: cy - 18))
            stroke(c, top, 5)
        }

        // Sopracciglia
        let lift: CGFloat = mood == .shocked ? -3 : 0
        for side in [-1.0, 1.0] {
            let worried = mood == .oops
            var b = Path()
            b.move(to: CGPoint(x: 100 + side * 42, y: 97 + lift + (worried ? 0 : 0)))
            b.addQuadCurve(to: CGPoint(x: 100 + side * 8, y: (worried ? 88 : 93) + lift),
                           control: CGPoint(x: 100 + side * 25, y: (worried ? 88 : 86) + lift))
            stroke(c, b, 6)
        }

        // Naso
        var nose = Path()
        nose.move(to: CGPoint(x: 96, y: 121))
        nose.addQuadCurve(to: CGPoint(x: 104, y: 125), control: CGPoint(x: 97, y: 128))
        stroke(c, nose, 2.5)

        // Bocca
        switch mood {
        case .shocked:
            let m = Path(ellipseIn: CGRect(x: 90, y: 134, width: 20, height: 26))
            c.fill(m, with: .color(Color(red: 0.55, green: 0.1, blue: 0.1)))
            stroke(c, m, 3)
        case .oops:
            var m = Path()
            m.move(to: CGPoint(x: 82, y: 146))
            m.addQuadCurve(to: CGPoint(x: 100, y: 146), control: CGPoint(x: 91, y: 136))
            m.addQuadCurve(to: CGPoint(x: 118, y: 146), control: CGPoint(x: 109, y: 156))
            stroke(c, m, 3.5)
        default:
            var m = Path()
            m.move(to: CGPoint(x: 80, y: 136))
            m.addQuadCurve(to: CGPoint(x: 120, y: 136), control: CGPoint(x: 100, y: 136 + 4 + 36 * open))
            m.closeSubpath()
            c.fill(m, with: .color(Color(red: 0.55, green: 0.1, blue: 0.1)))
            var inside = c
            inside.clip(to: m)
            inside.fill(Path(CGRect(x: 78, y: 133, width: 44, height: 8)), with: .color(.white))
            inside.fill(Path(ellipseIn: CGRect(x: 88, y: 136 + 4 + 18 * open, width: 24, height: 14)), with: .color(Color(red: 0.95, green: 0.5, blue: 0.5)))
            stroke(c, m, 3)
        }

        // Capelli ricci arruffati
        let curls: [(CGFloat, CGFloat, CGFloat)] = [
            (100, 36, 17), (84, 42, 20), (116, 42, 20), (68, 52, 22), (132, 52, 22), (100, 52, 26),
            (50, 68, 20), (150, 68, 20), (40, 90, 14), (160, 90, 14), (46, 106, 8), (154, 106, 8),
            (64, 72, 13), (82, 77, 12), (102, 74, 13), (121, 77, 12), (138, 72, 13),
        ]
        for (x, y, r) in curls { c.fill(circle(x, y, r), with: .color(ink)) }
        for (x, y, r) in curls.prefix(9) {
            var shine = Path()
            shine.addArc(center: CGPoint(x: x, y: y), radius: r * 0.62, startAngle: .degrees(200), endAngle: .degrees(262), clockwise: false)
            stroke(c, shine, 2.4, Color(white: 1, opacity: 0.35))
        }
        for (x, y, from, to) in [(70.0, 28.0, 100.0, 380.0), (140.0, 34.0, 160.0, 440.0), (30.0, 62.0, 0.0, 280.0), (170.0, 56.0, 120.0, 400.0)] {
            var curl = Path()
            curl.addArc(center: CGPoint(x: x, y: y), radius: 6, startAngle: .degrees(from), endAngle: .degrees(to), clockwise: false)
            stroke(c, curl, 3.5)
        }

        // Un foglio spiegazzato rimasto appiccicato tra i capelli
        var sheet = Path()
        sheet.move(to: CGPoint(x: 124, y: 22))
        sheet.addLine(to: CGPoint(x: 146, y: 14))
        sheet.addLine(to: CGPoint(x: 158, y: 30))
        sheet.addLine(to: CGPoint(x: 148, y: 44))
        sheet.addLine(to: CGPoint(x: 128, y: 40))
        sheet.closeSubpath()
        fillStroke(c, sheet, .white, 2.5)
        for y in [24.0, 31.0] {
            var line = Path()
            line.move(to: CGPoint(x: 133, y: y + 1))
            line.addLine(to: CGPoint(x: 149, y: y - 2))
            stroke(c, line, 1.6, Color(white: 0.55))
        }

        if mood == .oops {
            var drop = Path()
            drop.move(to: CGPoint(x: 176, y: 100))
            drop.addLine(to: CGPoint(x: 171, y: 112))
            drop.addLine(to: CGPoint(x: 181, y: 112))
            drop.closeSubpath()
            drop.addEllipse(in: CGRect(x: 170, y: 108, width: 12, height: 11))
            fillStroke(c, drop, Color(red: 0.55, green: 0.8, blue: 1), 2)
        }
    }
}

// MARK: - Consigli di Genuzzu

enum GenuzzuContext: Equatable { case idle, busy, preview, ordered, done, search }

struct GenuzzuTip {
    let mood: GenuzzuMood
    let text: String
    let warning: String

    static func contextual(_ context: GenuzzuContext) -> GenuzzuTip {
        switch context {
        case .idle:
            return GenuzzuTip(mood: .happy, text: "Ciao, sono Genuzzu! Trascina qui una cartella (o scegline una) e la sistemo per data e tipo.",
                              warning: "Il mio Desktop? Meglio non guardarlo. Non fare come me!")
        case .busy:
            return GenuzzuTip(mood: .shocked, text: "Sto guardando i file… un attimo!",
                              warning: "Io ci metterei tre giorni e poi perderei la cartella. Non fare come me!")
        case .preview:
            return GenuzzuTip(mood: .happy, text: "Questa è solo l'anteprima: finché non premi “Ordina” non si muove niente. Controlla come verranno le cartelle.",
                              warning: "Io sposto prima e controllo mai. Non fare come me!")
        case .ordered:
            return GenuzzuTip(mood: .wink, text: "Qui è già tutto in ordine, bravo! Prova con un'altra cartella.",
                              warning: "Io ho il frigo pieno di calzini e il cassetto pieno di yogurt. Non fare come me!")
        case .done:
            return GenuzzuTip(mood: .wink, text: "Fatto! Se qualcosa non ti convince, c'è “Annulla ultimo ordinamento”.",
                              warning: "Io i pasticci li lascio lì per mesi. Non fare come me!")
        case .search:
            return GenuzzuTip(mood: .happy, text: "Non trovi un file? Cercalo per nome, tipo o data, poi sposta o copia i risultati dove vuoi.",
                              warning: "Io cerco le chiavi da tre anni. Non fare come me!")
        }
    }

    static let generic: [GenuzzuTip] = [
        GenuzzuTip(mood: .happy, text: "Dalle Impostazioni scegli la struttura delle cartelle: Anno/Mese/Tipo o l'ordine che preferisci.",
                   warning: "Io le chiamo tutte “Varie nuova FINALE 2”. Non fare come me!"),
        GenuzzuTip(mood: .wink, text: "Attiva “Includi anche le sottocartelle” per riordinare pure quello che sta dentro altre cartelle.",
                   warning: "Io ho cartelle dentro cartelle dentro cartelle, e non so più dov'è l'uscita. Non fare come me!"),
        GenuzzuTip(mood: .happy, text: "Puoi escludere certe estensioni (tipo dmg o torrent): quei file restano dove sono.",
                   warning: "Io escludo solo le bollette. Non fare come me!"),
        GenuzzuTip(mood: .oops, text: "Con “Ignora i file recenti” riordini solo il vecchio e lasci stare quello che stai usando.",
                   warning: "I miei file recenti sono sparsi ovunque, anche sul termosifone. Non fare come me!"),
        GenuzzuTip(mood: .happy, text: "Trascina una cartella dall'elenco a sinistra direttamente nell'area tratteggiata.",
                   warning: "Io trascino tutto… nel cestino sbagliato. Non fare come me!"),
        GenuzzuTip(mood: .wink, text: "Poco alla volta, ma spesso: una cartella al giorno e il caos non si accumula.",
                   warning: "Io faccio il grande riordino ogni mai. Non fare come me!"),
        GenuzzuTip(mood: .shocked, text: "Hai sbagliato qualcosa? “Annulla ultimo ordinamento” rimette i file dov'erano.",
                   warning: "Io non ho mai avuto un Annulla, solo scatoloni. Non fare come me!"),
        GenuzzuTip(mood: .happy, text: "L'app controlla da sola gli aggiornamenti, così hai sempre le novità.",
                   warning: "Io rimando pure quelli, dal 2019. Non fare come me!"),
    ]
}

/// Striscia in fondo alla finestra: Genuzzu con il suo fumetto. Un clic per un altro consiglio.
struct GenuzzuFooter: View {
    let context: GenuzzuContext
    @AppStorage("mascotVisible") private var visible = true
    @State private var generic: Int?
    @State private var talking = false

    private var tip: GenuzzuTip { generic.map { GenuzzuTip.generic[$0] } ?? GenuzzuTip.contextual(context) }

    var body: some View {
        if visible {
            HStack(spacing: 2) {
                GenuzzuView(mood: tip.mood, talking: talking)
                    .frame(width: 84, height: 80)
                (Text(tip.text + " ") + Text(tip.warning).italic().bold().foregroundColor(.orange))
                    .font(.system(size: 12))
                    .lineLimit(4)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 8).padding(.trailing, 12).padding(.leading, 21)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glass(SpeechBubble())
            }
            .frame(height: 88)
            .padding(.horizontal).padding(.bottom, 6)
            .contentShape(Rectangle())
            .onTapGesture { nextTip() }
            .help("Clicca per un altro consiglio di Genuzzu")
            .contextMenu {
                Button("Altro consiglio") { nextTip() }
                Button("Nascondi Genuzzu") { visible = false }
            }
            .onAppear { speak() }
            .onChange(of: context) { _ in
                generic = nil
                speak()
            }
        }
    }

    private func nextTip() {
        let n = GenuzzuTip.generic.count
        generic = generic.map { ($0 + 1) % n } ?? Int.random(in: 0..<n)
        speak()
    }

    private func speak() {
        talking = true
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            talking = false
        }
    }
}

// MARK: - Liquid Glass

extension View {
    /// Liquid Glass su macOS 26 e successivi; su sistemi più vecchi un vetro smerigliato semplice.
    @ViewBuilder
    func glass<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(Self.makeGlass(tint: tint, interactive: interactive), in: shape)
        } else {
            self.background(shape.fill(.ultraThinMaterial)).background(shape.fill(tint?.opacity(0.18) ?? .clear))
        }
    }

    @available(macOS 26, *)
    private static func makeGlass(tint: Color?, interactive: Bool) -> Glass {
        var g = Glass.regular
        if let tint { g = g.tint(tint) }
        if interactive { g = g.interactive() }
        return g
    }

    /// Pulsante principale in vetro (Liquid Glass) con colore a scelta.
    @ViewBuilder
    func prominentGlass(tint: Color? = nil) -> some View {
        if #available(macOS 26, *) {
            self.buttonStyle(.glassProminent).tint(tint)
        } else {
            self.buttonStyle(.borderedProminent).tint(tint)
        }
    }
}

/// Fondale colorato e morbido dietro la finestra: il vetro ha così qualcosa da rifrangere.
struct AmbientBackground: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(colors: [Color.blue.opacity(0.30), .clear], center: .topLeading, startRadius: 0, endRadius: 560)
            RadialGradient(colors: [Color.teal.opacity(0.20), .clear], center: .topTrailing, startRadius: 0, endRadius: 460)
            RadialGradient(colors: [Color.purple.opacity(0.24), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 620)
            RadialGradient(colors: [Color.orange.opacity(0.12), .clear], center: .bottomLeading, startRadius: 0, endRadius: 420)
        }
        .ignoresSafeArea()
    }
}

/// Barra di avanzamento senza fine: la ricerca non sa in anticipo quanti file ci sono.
struct SearchProgressBar: View {
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let p = t.truncatingRemainder(dividingBy: 1.4) / 1.4
            let e = 0.5 - 0.5 * cos(p * .pi)
            GeometryReader { geo in
                let seg = geo.size.width * 0.34
                Capsule().fill(Color.secondary.opacity(0.18))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(LinearGradient(colors: [.yellow, .orange], startPoint: .leading, endPoint: .trailing))
                            .frame(width: seg)
                            .offset(x: -seg + (geo.size.width + seg) * CGFloat(e))
                    }
                    .clipShape(Capsule())
            }
        }
        .frame(height: 6)
        .accessibilityLabel("Ricerca in corso")
    }
}

/// Genuzzu come titolo di una sezione: più grande del consiglio a piè di pagina, con il fumetto colorato per farsi notare.
struct GenuzzuTitleBar: View {
    let title: String
    let text: String
    @State private var talking = false

    var body: some View {
        HStack(spacing: 2) {
            GenuzzuView(mood: .happy, talking: talking)
                .frame(width: 100, height: 95)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 17, weight: .heavy))
                Text(text).font(.system(size: 13, weight: .regular)).foregroundStyle(.primary.opacity(0.85))
            }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 12).padding(.trailing, 16).padding(.leading, 23)
                .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
                .glass(SpeechBubble(), tint: Color.yellow.opacity(0.55))
        }
        .padding(.horizontal).padding(.top, 10)
        .onAppear {
            talking = true
            Task { try? await Task.sleep(nanoseconds: 2_500_000_000); talking = false }
        }
    }
}

struct SpeechBubble: Shape {
    enum Tail { case left, bottom }
    var tail: Tail = .left

    func path(in r: CGRect) -> Path {
        if tail == .bottom {
            // Il fumetto occupa tutto il rettangolo; la codina sporge sotto, verso la testa di Genuzzu.
            let body = CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height)
            var p = Path(roundedRect: body, cornerRadius: 12)
            let x = r.midX
            p.move(to: CGPoint(x: x - 8, y: body.maxY - 1))
            p.addLine(to: CGPoint(x: x, y: body.maxY + 9))
            p.addLine(to: CGPoint(x: x + 8, y: body.maxY - 1))
            p.closeSubpath()
            return p
        }
        let tail: CGFloat = 9
        let body = CGRect(x: r.minX + tail, y: r.minY, width: r.width - tail, height: r.height)
        var p = Path(roundedRect: body, cornerRadius: 12)
        p.move(to: CGPoint(x: body.minX + 1, y: r.midY - 7))
        p.addLine(to: CGPoint(x: r.minX, y: r.midY))
        p.addLine(to: CGPoint(x: body.minX + 1, y: r.midY + 7))
        p.closeSubpath()
        return p
    }
}

struct SettingsView: View {
    @AppStorage("layoutParts") private var layoutParts = ""
    @AppStorage("layout") private var legacyLayout = ""
    @AppStorage("monthStyle") private var monthStyle = MonthStyle.numberName.rawValue
    @AppStorage("dateSource") private var dateSource = DateSource.exifThenCreation.rawValue
    @AppStorage("leaveUnknownInPlace") private var leaveUnknown = false
    @AppStorage("excludedExts") private var excluded = ""
    @AppStorage("minAgeDays") private var minAgeDays = 0
    @AppStorage("moveDuplicates") private var moveDuplicates = true
    @AppStorage("autoUpdateCheck") private var autoUpdateCheck = true
    @AppStorage("autoInstall") private var autoInstall = true
    @AppStorage("mascotVisible") private var mascotVisible = true

    private var parts: [Part] { Prefs.resolveParts(layoutParts: layoutParts, legacy: legacyLayout) }
    private func save(_ p: [Part]) { layoutParts = p.map(\.rawValue).joined(separator: ",") }

    var body: some View {
        Form {
            Section("Struttura delle cartelle") {
                ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
                    HStack(spacing: 6) {
                        Picker("Livello \(i + 1)", selection: Binding(
                            get: { part },
                            set: { var p = parts; p[i] = $0; save(p) })) {
                            ForEach(Part.allCases) { Text("\($0.title)  (\($0.example))").tag($0) }
                        }
                        Button { var p = parts; p.swapAt(i, i - 1); save(p) } label: { Image(systemName: "chevron.up") }
                            .disabled(i == 0)
                        Button { var p = parts; p.swapAt(i, i + 1); save(p) } label: { Image(systemName: "chevron.down") }
                            .disabled(i == parts.count - 1)
                        Button { var p = parts; p.remove(at: i); save(p) } label: { Image(systemName: "minus.circle") }
                            .disabled(parts.count == 1)
                    }
                    .buttonStyle(.borderless)
                }
                HStack {
                    Button { save(parts + [.type]) } label: { Label("Aggiungi livello", systemImage: "plus.circle") }
                        .disabled(parts.count >= 5)
                    Spacer()
                    Menu("Applica un modello") {
                        ForEach(Layout.allCases) { l in Button(l.title) { save(l.parts) } }
                    }
                    .fixedSize()
                }
                Picker("Formato del mese", selection: $monthStyle) {
                    ForEach(MonthStyle.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .disabled(!parts.contains(.month))
                LabeledContent("Esempio") {
                    Text(Prefs.current.examplePath)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            Section("Data") {
                Picker("Data da usare", selection: $dateSource) {
                    ForEach(DateSource.allCases) { Text($0.title).tag($0.rawValue) }
                }
            }
            Section("File da non toccare") {
                TextField("Estensioni escluse", text: $excluded, prompt: Text("es. dmg, torrent, ini"))
                Stepper(value: $minAgeDays, in: 0...365) {
                    Text(minAgeDays == 0 ? "Ignora i file recenti: no"
                                         : "Ignora i file modificati negli ultimi \(minAgeDays) giorni")
                }
                Toggle("Lascia al loro posto i file di tipo sconosciuto", isOn: $leaveUnknown)
                Text("I download non completati (.crdownload, .part…) e i file nascosti vengono sempre ignorati.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Doppioni") {
                Toggle("Metti da parte i doppioni esatti", isOn: $moveDuplicates)
                Text("Un file è un doppione solo se ha esattamente lo stesso contenuto, controllato byte per byte (non basta il nome). Ne resta uno al suo posto e gli altri vanno nella cartella “Duplicati”: non viene cancellato nulla e l'anteprima ti mostra tutto prima.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Mascotte") {
                Toggle("Mostra Genuzzu e i suoi consigli", isOn: $mascotVisible)
            }
            Section("Aggiornamenti") {
                LabeledContent("Versione installata", value: Updater.currentVersion)
                Toggle("Controlla gli aggiornamenti all'avvio", isOn: $autoUpdateCheck)
                Toggle("Installa automaticamente gli aggiornamenti", isOn: $autoInstall)
                Button("Controlla ora") { Task { await Updater.check(silent: false) } }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(AmbientBackground())
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Cerca duplicati

struct DupFile: Identifiable {
    let url: URL
    let size: Int64
    let modified: Date?
    /// Solo per i file simili: descrizione della qualità (risoluzione, bitrate…) e punteggio per ordinarli.
    var detail = ""
    var score = 0.0
    var id: String { url.path }
}

struct DupGroup: Identifiable {
    let id = UUID()
    var files: [DupFile]
    /// Gruppo di file simili (non identici): il primo è quello di qualità migliore.
    var similar = false
    var size: Int64 { files[0].size }
}

/// Che cosa cerca “Cerca duplicati”.
enum DupMode: String, CaseIterable, Identifiable {
    case exact = "Identici", photos = "Foto simili", music = "Musica simile"
    var id: String { rawValue }
    var noun: String { self == .exact ? "doppioni" : "file simili" }
}

// MARK: - File simili

/// Trova foto visivamente uguali (ridimensionate, ricompresse, ritoccate di poco) e brani musicali
/// che sono lo stesso pezzo in versioni diverse. In ogni gruppo il primo file è quello di qualità migliore.
enum Similar {
    static let photoExts: Set<String> = Organizer.photoExts.union(["png", "webp", "bmp"])
    static let audioExts: Set<String> = ["mp3", "wav", "aac", "m4a", "flac", "aiff", "aif"]
    static let losslessExts: Set<String> = ["flac", "wav", "aiff", "aif"]

    /// Distanza massima (su 64 bit) tra le impronte visive di due foto considerate la stessa.
    private static let maxDistance = 5
    /// Differenza massima di proporzioni tra due foto della stessa immagine.
    private static let maxRatioGap = 0.04
    /// Differenza media massima di luminosità (0-255) sulle 64 zone confrontate.
    private static let maxLumaGap = 14.0
    /// Differenza media massima di colore (0-255) sulle 16 zone confrontate: distingue lo stesso disegno in colori diversi.
    private static let maxColorGap = 30.0
    /// Differenza massima di durata tra due versioni dello stesso brano, in secondi.
    private static let maxDurationGap = 2.0

    // MARK: Foto

    struct PhotoInfo {
        var file: DupFile
        let hash: UInt64
        let ratio: Double
        let luma: [Double]
        let color: [Double]
        let pixels: Int
    }

    private static func grayGrid(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var px = [UInt8](repeating: 0, count: width * height)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? px : nil
    }

    /// Colore medio (rosso, verde, blu) di una griglia 4×4.
    private static func colorGrid(_ image: CGImage) -> [Double]? {
        var px = [UInt8](repeating: 0, count: 4 * 4 * 4)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: 4, height: 4))
            return true
        }
        guard ok else { return nil }
        return (0..<16).flatMap { [Double(px[$0 * 4]), Double(px[$0 * 4 + 1]), Double(px[$0 * 4 + 2])] }
    }

    static func photoInfo(_ file: DupFile) -> PhotoInfo? {
        guard let src = CGImageSourceCreateWithURL(file.url as CFURL, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 96]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary),
              thumb.width > 0, thumb.height > 0,
              let diff = grayGrid(thumb, width: 9, height: 8),
              let zones = grayGrid(thumb, width: 8, height: 8),
              let color = colorGrid(thumb) else { return nil }
        var hash: UInt64 = 0
        for row in 0..<8 {
            for col in 0..<8 {
                hash <<= 1
                if diff[row * 9 + col] > diff[row * 9 + col + 1] { hash |= 1 }
            }
        }
        // Luminosità delle 64 zone, senza la media: un ritocco di luminosità non le fa sembrare diverse.
        let mean = zones.reduce(0.0) { $0 + Double($1) } / Double(zones.count)
        var f = file
        f.detail = w > 0 && h > 0
            ? "\(w)×\(h) · " + String(format: "%.1f", Double(w * h) / 1_000_000).replacingOccurrences(of: ".", with: ",") + " MP"
            : ""
        f.score = Double(w * h)
        return PhotoInfo(file: f, hash: hash, ratio: Double(thumb.width) / Double(thumb.height),
                         luma: zones.map { Double($0) - mean }, color: color, pixels: w * h)
    }

    private static func samePhoto(_ a: PhotoInfo, _ b: PhotoInfo) -> Bool {
        guard (a.hash ^ b.hash).nonzeroBitCount <= maxDistance,
              abs(a.ratio - b.ratio) / max(a.ratio, b.ratio) <= maxRatioGap else { return false }
        var gap = 0.0
        for i in 0..<a.luma.count { gap += abs(a.luma[i] - b.luma[i]) }
        guard gap / Double(a.luma.count) <= maxLumaGap else { return false }
        var tint = 0.0
        for i in 0..<a.color.count { tint += abs(a.color[i] - b.color[i]) }
        return tint / Double(a.color.count) <= maxColorGap
    }

    private struct UnionFind {
        var parent: [Int]
        init(_ n: Int) { parent = Array(0..<n) }
        mutating func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        mutating func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }
    }

    /// Dal migliore al peggiore: più qualità, poi più peso, poi il più vecchio.
    private static func ranked(_ files: [DupFile]) -> [DupFile] {
        files.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.size != $1.size { return $0.size > $1.size }
            return ($0.modified ?? .distantFuture, $0.id) < ($1.modified ?? .distantFuture, $1.id)
        }
    }

    static func photoGroups(_ files: [DupFile], isCancelled: @escaping () -> Bool,
                            progress: @escaping (_ done: Int, _ total: Int) -> Void) -> [[DupFile]] {
        let lock = NSLock()
        var infos: [PhotoInfo] = []
        var done = 0
        DispatchQueue.concurrentPerform(iterations: files.count) { i in
            if isCancelled() { return }
            let info = photoInfo(files[i])
            lock.lock()
            if let info { infos.append(info) }
            done += 1
            let d = done
            lock.unlock()
            if d % 20 == 0 || d == files.count { progress(d, files.count) }
        }
        guard !isCancelled(), infos.count > 1 else { return [] }

        // Si confrontano solo le foto che condividono almeno una fascia dell'impronta:
        // con 6 fasce e distanza massima 5, due foto simili ne hanno sempre una uguale.
        var uf = UnionFind(infos.count)
        let bands: [(shift: UInt64, bits: UInt64)] = [(0, 11), (11, 11), (22, 11), (33, 11), (44, 11), (55, 9)]
        for band in bands {
            if isCancelled() { return [] }
            var buckets: [UInt64: [Int]] = [:]
            for (i, info) in infos.enumerated() {
                buckets[(info.hash >> band.shift) & ((1 << band.bits) - 1), default: []].append(i)
            }
            for idx in buckets.values where idx.count > 1 && idx.count <= 1500 {
                for a in 0..<idx.count {
                    for b in (a + 1)..<idx.count where uf.find(idx[a]) != uf.find(idx[b]) {
                        if samePhoto(infos[idx[a]], infos[idx[b]]) { uf.union(idx[a], idx[b]) }
                    }
                }
            }
        }
        var clusters: [Int: [DupFile]] = [:]
        for i in infos.indices { clusters[uf.find(i), default: []].append(infos[i].file) }
        return clusters.values.filter { $0.count > 1 }.map(ranked)
    }

    // MARK: Musica

    struct Track {
        var file: DupFile
        let key: String
        let duration: Double
    }

    private static func normalized(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        return folded.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Nome del file ripulito da numeri di traccia e segni di copia (“01 - Brano (1)”, “Brano copia”).
    private static func cleanedName(_ url: URL) -> String {
        var s = url.deletingPathExtension().lastPathComponent
        s = s.replacingOccurrences(of: #"\s*\(\d+\)$"#, with: "", options: .regularExpression)
        s = normalized(s)
        s = s.replacingOccurrences(of: #"^\d{1,3}\s+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s(copia|copy)(\s\d+)?$"#, with: "", options: .regularExpression)
        return s
    }

    static func track(_ file: DupFile) async -> Track? {
        let asset = AVURLAsset(url: file.url)
        guard let time = try? await asset.load(.duration), time.seconds.isFinite, time.seconds > 1 else { return nil }
        let items = (try? await asset.load(.commonMetadata)) ?? []
        func text(_ id: AVMetadataIdentifier) async -> String {
            guard let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: id).first,
                  let v = try? await item.load(.stringValue) else { return "" }
            return v.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let title = await text(.commonIdentifierTitle), artist = await text(.commonIdentifierArtist)
        var rate = 0.0
        if let t = (try? await asset.loadTracks(withMediaType: .audio))?.first {
            rate = Double((try? await t.load(.estimatedDataRate)) ?? 0)
        }
        if rate <= 0 { rate = Double(file.size) * 8 / time.seconds }

        let t = normalized(title), a = normalized(artist)
        let name = cleanedName(file.url)
        // Con titolo e artista nei tag ci si fida di quelli; altrimenti solo del nome, purché non sia troppo corto.
        let key: String
        if t.count >= 2 && !a.isEmpty { key = "t:\(a)|\(t)" }
        else if name.count >= 4 { key = "f:\(name)" }
        else { return nil }

        let lossless = losslessExts.contains(file.url.pathExtension.lowercased())
        var f = file
        let mins = Int(time.seconds) / 60, secs = Int(time.seconds) % 60
        f.detail = (lossless ? "senza perdita · " : "") + "\(Int(rate / 1000)) kbps · \(mins):" + String(format: "%02d", secs)
            + (key.hasPrefix("t:") ? " · \(artist) – \(title)" : "")
        f.score = rate / 1000 + (lossless ? 100_000 : 0)
        return Track(file: f, key: key, duration: time.seconds)
    }

    static func musicGroups(_ files: [DupFile], isCancelled: @escaping () -> Bool,
                            progress: @escaping (_ done: Int, _ total: Int) -> Void) async -> [[DupFile]] {
        var tracks: [Track] = []
        var done = 0
        await withTaskGroup(of: Track?.self) { group in
            var it = files.makeIterator()
            var running = 0
            while running < 6, let f = it.next() { group.addTask { await track(f) }; running += 1 }
            for await t in group {
                done += 1
                progress(done, files.count)
                if let t { tracks.append(t) }
                if !isCancelled(), let f = it.next() { group.addTask { await track(f) } }
            }
        }
        guard !isCancelled() else { return [] }
        var result: [[DupFile]] = []
        for (_, same) in Dictionary(grouping: tracks, by: \.key) where same.count > 1 {
            // Stesso brano solo se anche la durata coincide (a meno di un paio di secondi).
            var cluster: [Track] = []
            func flush() {
                if cluster.count > 1 { result.append(ranked(cluster.map(\.file))) }
                cluster = []
            }
            for t in same.sorted(by: { $0.duration < $1.duration }) {
                if let first = cluster.first, t.duration - first.duration > maxDurationGap { flush() }
                cluster.append(t)
            }
            flush()
        }
        return result
    }
}

/// Interruttore sicuro da leggere da un altro thread.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
}

/// Cerca nella cartella scelta i file con contenuto esattamente identico, senza riordinare nulla.
@MainActor
final class DuplicateFinder: ObservableObject {
    /// Unico per tutta l'app: la finestra di confronto (separata, così può andare a schermo intero) lo legge da qui.
    static let shared = DuplicateFinder()
    /// Gruppo mostrato nella finestra di confronto e cartella di partenza (per mostrare i percorsi).
    @Published var compareGroup: UUID?
    var root: URL?
    @Published var groups: [DupGroup] = []
    /// I file che l'utente vuole togliere di mezzo: in ogni gruppo ne resta sempre almeno uno.
    @Published var remove = Set<String>()
    @Published var recursive = true
    @Published var mode = DupMode.exact
    @Published var scanning = false
    @Published var busy = false
    @Published var scanned = false
    @Published var status = ""
    private let cancelled = CancelFlag()

    var removeCount: Int { remove.count }
    var reclaimable: Int64 { groups.flatMap(\.files).filter { remove.contains($0.id) }.reduce(0) { $0 + $1.size } }

    func scan(root: URL) {
        guard !scanning else { return }
        self.root = root
        compareGroup = nil
        scanning = true
        scanned = false
        cancelled.set(false)
        groups = []
        remove = []
        status = "Cerco i file in “\(root.lastPathComponent)”…"
        let rec = recursive
        let mode = self.mode
        let cancelled = self.cancelled
        Task.detached(priority: .userInitiated) { [weak self] in
            let keys: [URLResourceKey] = [.isRegularFileKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey]
            var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
            if !rec { options.insert(.skipsSubdirectoryDescendants) }
            let skip = root.appendingPathComponent(Organizer.duplicatesFolder).standardizedFileURL.path + "/"
            var files: [DupFile] = []
            if let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: options) {
                for case let url as URL in en {
                    let v = try? url.resourceValues(forKeys: Set(keys))
                    guard v?.isRegularFile == true, v?.isPackage != true,
                          !Organizer.partialExts.contains(url.pathExtension.lowercased()),
                          !url.standardizedFileURL.path.hasPrefix(skip) else { continue }
                    let ext = url.pathExtension.lowercased()
                    if mode == .photos && !Similar.photoExts.contains(ext) { continue }
                    if mode == .music && !Similar.audioExts.contains(ext) { continue }
                    files.append(DupFile(url: url, size: Int64(v?.fileSize ?? 0), modified: v?.contentModificationDate))
                }
            }
            await MainActor.run { self?.status = "Confronto \(files.count) file…" }
            let built: [DupGroup]
            switch mode {
            case .exact:
                let byPath = Dictionary(files.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                let found = Duplicates.groups(files.map { ($0.url, $0.size) },
                                              isCancelled: { cancelled.isSet },
                                              progress: { d, t in
                    Task { @MainActor in self?.status = "Confronto dei contenuti: \(d) gruppi di \(t)…" }
                })
                // Dentro ogni gruppo: prima il più vecchio, a parità il percorso più corto. Il primo è quello da tenere.
                built = found.map { g -> DupGroup in
                    let f = g.compactMap { byPath[$0.path] }.sorted {
                        ($0.modified ?? .distantFuture, $0.id.count, $0.id) < ($1.modified ?? .distantFuture, $1.id.count, $1.id)
                    }
                    return DupGroup(files: f)
                }.sorted { $0.size > $1.size }
            case .photos, .music:
                let candidates = files.filter { $0.size > 0 }
                let progress: (Int, Int) -> Void = { d, t in
                    let what = mode == .photos ? "Guardo le foto" : "Ascolto i brani"
                    Task { @MainActor in self?.status = "\(what): \(d) di \(t)…" }
                }
                let found = mode == .photos
                    ? Similar.photoGroups(candidates, isCancelled: { cancelled.isSet }, progress: progress)
                    : await Similar.musicGroups(candidates, isCancelled: { cancelled.isSet }, progress: progress)
                // Per primi i gruppi dove si recupera più spazio.
                built = found.map { DupGroup(files: $0, similar: true) }.sorted {
                    $0.files.dropFirst().reduce(0) { $0 + $1.size } > $1.files.dropFirst().reduce(0) { $0 + $1.size }
                }
            }
            await MainActor.run { self?.finishScan(built) }
        }
    }

    func stop() { cancelled.set(true) }

    private func finishScan(_ built: [DupGroup]) {
        groups = built
        remove = Set(built.flatMap { $0.files.dropFirst().map(\.id) })
        scanning = false
        scanned = true
        let extra = built.reduce(0) { $0 + $1.files.count - 1 }
        let none = mode == .exact ? "Nessun doppione: tutti i file sono diversi." : "Nessun file simile trovato."
        status = built.isEmpty ? (cancelled.isSet ? "Ricerca interrotta: niente trovato finora." : none)
            : "\(extra) \(mode.noun) in \(built.count) gruppi, \(ByteCountFormatter.string(fromByteCount: reclaimable, countStyle: .file)) recuperabili."
    }

    /// Spunta o toglie un file; in ogni gruppo almeno un file deve restare.
    func toggle(_ file: DupFile, in group: DupGroup) {
        if remove.contains(file.id) { remove.remove(file.id); return }
        let kept = group.files.filter { !remove.contains($0.id) && $0.id != file.id }
        if !kept.isEmpty { remove.insert(file.id) }
    }

    func isKept(_ file: DupFile) -> Bool { !remove.contains(file.id) }

    private func dropped(_ ids: Set<String>) {
        groups = groups.compactMap { g in
            var g = g
            g.files.removeAll { ids.contains($0.id) }
            return g.files.count > 1 ? g : nil
        }
        remove.subtract(ids)
    }

    /// Sposta i doppioni scelti nella cartella “Duplicati” (si può annullare dal pulsante “Annulla ultimo ordinamento”).
    func moveAside(root: URL) {
        let chosen = groups.flatMap(\.files).filter { remove.contains($0.id) }.map(\.url)
        guard !chosen.isEmpty else { return }
        busy = true
        status = "Sposto \(chosen.count) \(mode.noun)…"
        Task.detached {
            let dir = root.appendingPathComponent(Organizer.duplicatesFolder)
            var used = Set<String>()
            let moves = chosen.map { PlannedMove(source: $0, dest: Organizer.uniqueDestination(dir: dir, name: $0.lastPathComponent, used: &used)) }
            let r = Organizer.apply(moves, root: root)
            let gone = Set(moves.map { $0.source.path })
            await MainActor.run {
                self.busy = false
                self.dropped(gone)
                self.status = "Spostati \(r.done) \(self.mode.noun) in “\(Organizer.duplicatesFolder)”" + (r.failed > 0 ? ", \(r.failed) non riusciti." : ".")
            }
        }
    }

    /// Mette i doppioni scelti nel Cestino: si recuperano da lì.
    func trash() {
        let chosen = groups.flatMap(\.files).filter { remove.contains($0.id) }.map(\.url)
        guard !chosen.isEmpty else { return }
        busy = true
        status = "Metto \(chosen.count) \(mode.noun) nel Cestino…"
        Task.detached {
            var gone = Set<String>()
            for u in chosen where (try? FileManager.default.trashItem(at: u, resultingItemURL: nil)) != nil { gone.insert(u.path) }
            let n = gone.count, bad = chosen.count - n
            await MainActor.run {
                self.busy = false
                self.dropped(gone)
                self.status = "\(n) \(self.mode.noun) nel Cestino" + (bad > 0 ? ", \(bad) non riusciti." : ".")
            }
        }
    }
}

struct DuplicatesView: View {
    @ObservedObject var vm: ViewModel
    @ObservedObject private var f = DuplicateFinder.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var selection = Set<String>()
    @State private var confirmTrash = false
    @FocusState private var listFocused: Bool

    private var root: URL? { vm.folder }
    private var allURLs: [URL] { f.groups.flatMap(\.files).map(\.url) }
    private func previewIndex() -> Int { allURLs.firstIndex { selection.contains($0.path) } ?? 0 }
    private func preview() { QuickLook.shared.toggle(allURLs, index: previewIndex()) }

    private func relative(_ url: URL) -> String {
        guard let r = root?.path else { return url.path }
        let p = url.deletingLastPathComponent().path
        if p == r { return "(cartella principale)" }
        return p.hasPrefix(r + "/") ? String(p.dropFirst(r.count + 1)) : p
    }

    private var modeHelp: String {
        switch f.mode {
        case .exact: "Sono doppioni solo i file con contenuto esattamente identico (stessa dimensione, stessa impronta e confronto byte per byte): il nome non conta. Di ogni gruppo ne resta almeno uno."
        case .photos: "Trova le stesse foto ridimensionate, ricompresse o ritoccate di poco. In ogni gruppo viene tenuta quella con più pixel (poi la più pesante). Scatti in sequenza quasi uguali possono finire insieme: controlla con l'anteprima prima di togliere qualcosa."
        case .music: "Trova lo stesso brano in versioni diverse: stesso titolo e artista nei tag (o stesso nome del file) e durata uguale. In ogni gruppo viene tenuta la qualità migliore (senza perdita, poi bitrate più alto). Ascolta l'anteprima prima di togliere qualcosa."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Cerca duplicati", systemImage: "square.on.square").font(.title3.weight(.semibold))
                Spacer()
                Toggle("Includi sottocartelle", isOn: $f.recursive).disabled(f.scanning || f.busy)
                Button(f.scanned ? "Cerca di nuovo" : "Cerca") { if let r = root { f.scan(root: r) } }
                    .disabled(f.scanning || f.busy || root == nil)
            }
            Text("Cartella: " + (root?.path ?? "nessuna"))
                .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Picker("", selection: $f.mode) {
                ForEach(DupMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().disabled(f.scanning || f.busy)
            Text(modeHelp)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if f.scanning {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(f.status).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Ferma") { f.stop() }
                }
                .padding(10).glass(RoundedRectangle(cornerRadius: 14, style: .continuous), tint: .orange)
                Spacer()
            } else if f.groups.isEmpty {
                ContentUnavailableView(f.scanned ? (f.mode == .exact ? "Nessun doppione" : "Nessun file simile") : "Premi Cerca",
                                       systemImage: f.scanned ? "checkmark.circle" : "magnifyingglass",
                                       description: Text(f.scanned ? f.status : "Controllo la cartella scelta e ti mostro i file \(f.mode == .exact ? "identici" : "simili")."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(f.groups) { g in
                        Section {
                            ForEach(g.files) { file in row(file, in: g) }
                        } header: {
                            HStack {
                                if g.similar {
                                    Text("\(g.files.count) " + (f.mode == .music ? "versioni dello stesso brano" : "foto simili"))
                                } else {
                                    Text("\(g.files.count) copie · \(ByteCountFormatter.string(fromByteCount: g.size, countStyle: .file)) l'una")
                                }
                                Spacer()
                                Button { f.compareGroup = g.id; openWindow(id: "compare") } label: { Label("Confronta", systemImage: "rectangle.split.2x1") }
                                    .buttonStyle(.bordered).controlSize(.small).textCase(nil)
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .glass(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .focused($listFocused)
                .onAppear { listFocused = true }
                .onKeyPress(.space) { preview(); return .handled }
                .onChange(of: selection) { _ in QuickLook.shared.follow(previewIndex()) }
            }

            HStack {
                if f.busy { ProgressView().controlSize(.small) }
                if !f.groups.isEmpty || f.busy {
                    Text(f.groups.isEmpty ? f.status : "\(f.removeCount) da togliere · \(ByteCountFormatter.string(fromByteCount: f.reclaimable, countStyle: .file)) recuperabili")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button("Chiudi") { dismiss() }
                Button("Cestino…") { confirmTrash = true }
                    .disabled(f.removeCount == 0 || f.busy || f.scanning)
                Button("Sposta in “\(Organizer.duplicatesFolder)”") { if let r = root { f.moveAside(root: r) } }
                    .prominentGlass()
                    .disabled(f.removeCount == 0 || f.busy || f.scanning)
            }
        }
        .padding()
        .frame(minWidth: 680, minHeight: 520)
        .background(AmbientBackground())
        .onAppear { if let r = root, !f.scanning { f.scanned = false; f.mode = .exact; f.scan(root: r) } }
        .onChange(of: f.mode) { _ in
            selection = []
            if let r = root, !f.scanning { f.scan(root: r) }
        }
        .alert("Mettere \(f.removeCount) file nel Cestino?", isPresented: $confirmTrash) {
            Button("Metti nel Cestino", role: .destructive) { f.trash() }
            Button("Cancella", role: .cancel) {}
        } message: {
            Text("Resta una copia di ogni gruppo. I file si possono recuperare dal Cestino.")
        }
    }

    private func row(_ file: DupFile, in g: DupGroup) -> some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(get: { f.remove.contains(file.id) }, set: { _ in f.toggle(file, in: g) }))
                .labelsHidden().help("Spunta i file da togliere")
            FileThumbnail(url: file.url)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(file.url.lastPathComponent).font(.system(size: 14, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle)
                    if f.isKept(file) {
                        Text(g.similar && g.files.first?.id == file.id ? "Qualità migliore" : "Da tenere").font(.system(size: 10, weight: .semibold)).foregroundStyle(.green)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.green.opacity(0.16)))
                    }
                }
                Text(relative(file.url)).font(.system(size: 12)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.head)
                if !file.detail.isEmpty {
                    Text(file.detail + " · " + ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
            if let d = file.modified {
                Text(d.formatted(date: .abbreviated, time: .omitted)).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Button {
                selection = [file.id]
                QuickLook.shared.toggle(allURLs, index: allURLs.firstIndex(of: file.url) ?? 0)
            } label: { Image(systemName: "eye") }.buttonStyle(.borderless).help("Anteprima (barra spaziatrice)")
            Button { NSWorkspace.shared.activateFileViewerSelecting([file.url]) } label: { Image(systemName: "folder") }
                .buttonStyle(.borderless).help("Mostra nel Finder")
        }
        .padding(.vertical, 4)
        .tag(file.id)
    }
}

/// Confronto affiancato: i file di un gruppo uno accanto all'altro, grandi, per decidere quale tenere.
struct CompareView: View {
    @ObservedObject private var f = DuplicateFinder.shared
    @Environment(\.dismiss) private var dismiss

    private var root: URL? { f.root }
    private var groupID: UUID? {
        get { f.compareGroup }
        nonmutating set { f.compareGroup = newValue }
    }

    private static var playing: NSSound?
    /// Ingrandimento comune a tutte le foto (1 = intera) e punto guardato (0-1), uguali per ogni foto così si confronta lo stesso dettaglio.
    @State private var zoom: CGFloat = 1
    @State private var focus = CGPoint(x: 0.5, y: 0.5)

    /// Ascolta un brano (fermando quello in corso); senza file ferma l'ascolto.
    private static func play(_ url: URL?) {
        playing?.stop()
        playing = url.flatMap { NSSound(contentsOf: $0, byReference: true) }
        playing?.play()
    }

    private var index: Int? { f.groups.firstIndex { $0.id == f.compareGroup } }
    private var group: DupGroup? { index.map { f.groups[$0] } }

    private func go(_ delta: Int) {
        guard let i = index, f.groups.indices.contains(i + delta) else { return }
        groupID = f.groups[i + delta].id
    }

    private func folder(_ url: URL) -> String {
        guard let r = root?.path else { return url.deletingLastPathComponent().path }
        let p = url.deletingLastPathComponent().path
        if p == r { return "(cartella principale)" }
        return p.hasPrefix(r + "/") ? String(p.dropFirst(r.count + 1)) : p
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button { go(-1) } label: { Image(systemName: "chevron.left") }
                    .disabled((index ?? 0) == 0).keyboardShortcut(.leftArrow, modifiers: [])
                Text(index.map { "Gruppo \($0 + 1) di \(f.groups.count)" } ?? "")
                    .font(.headline).frame(minWidth: 130)
                Button { go(1) } label: { Image(systemName: "chevron.right") }
                    .disabled((index ?? 0) >= f.groups.count - 1).keyboardShortcut(.rightArrow, modifiers: [])
                Spacer()
                Picker("Ingrandimento", selection: $zoom) {
                    Text("Intera").tag(CGFloat(1))
                    Text("2×").tag(CGFloat(2))
                    Text("4×").tag(CGFloat(4))
                    Text("8×").tag(CGFloat(8))
                }
                .pickerStyle(.segmented).frame(width: 220)
                .help("Ingrandisci tutte le foto insieme: passa il mouse su una foto per guardare lo stesso punto in ognuna")
                Button { FullScreen.toggle() } label: { Label("Schermo intero", systemImage: "arrow.up.left.and.arrow.down.right") }
                    .help("Schermo intero (⌃⌘F)")
                Button("Fine") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let g = group {
                GeometryReader { geo in
                    let w = max(250, (geo.size.width - CGFloat(g.files.count - 1) * 12) / CGFloat(g.files.count))
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(g.files) { card($0, in: g, width: w, height: geo.size.height - 4) }
                        }
                    }
                }
            } else {
                ContentUnavailableView("Gruppo non più disponibile", systemImage: "checkmark.circle")
            }
        }
        .padding()
        .frame(minWidth: 760, minHeight: 560)
        .background(AmbientBackground())
        .background(WindowSetup())
        .onDisappear { Self.play(nil) }
    }

    private func card(_ file: DupFile, in g: DupGroup, width: CGFloat, height: CGFloat) -> some View {
        let kept = f.isKept(file)
        let onlyKept = kept && g.files.filter { f.isKept($0) }.count == 1
        let isAudio = Similar.audioExts.contains(file.url.pathExtension.lowercased())
        return VStack(alignment: .leading, spacing: 8) {
            ZStack {
                if isAudio {
                    VStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path)).resizable().frame(width: 96, height: 96)
                        Button { Self.play(file.url) } label: {
                            Label("Ascolta", systemImage: "play.fill")
                        }
                        Button { Self.play(nil) } label: { Label("Ferma", systemImage: "stop.fill") }
                    }
                } else {
                    LargePreview(url: file.url, zoom: zoom, focus: $focus)
                        .onTapGesture {
                            if zoom == 1 { QuickLook.shared.toggle(g.files.map(\.url), index: g.files.firstIndex { $0.id == file.id } ?? 0) }
                        }
                        .help(zoom == 1 ? "Clic per l'anteprima di sistema" : "Muovi il mouse per spostarti in tutte le foto insieme")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))

            HStack(spacing: 6) {
                Text(file.url.lastPathComponent).font(.system(size: 14, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                if g.similar && g.files.first?.id == file.id {
                    Text("Qualità migliore").font(.system(size: 10, weight: .semibold)).foregroundStyle(.green)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Color.green.opacity(0.16)))
                }
            }
            if !file.detail.isEmpty { Text(file.detail).font(.system(size: 13, weight: .medium)) }
            Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)
                 + (file.modified.map { " · " + $0.formatted(date: .abbreviated, time: .omitted) } ?? ""))
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Text(folder(file.url)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)

            Button { f.toggle(file, in: g) } label: {
                Label(kept ? "Tieni (clic per togliere)" : "Da togliere (clic per tenere)",
                      systemImage: kept ? "checkmark.circle.fill" : "trash.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .tint(kept ? .green : .red)
            .buttonStyle(.borderedProminent)
            .disabled(onlyKept)
            .help(onlyKept ? "Almeno un file del gruppo deve restare" : "")
        }
        .padding(10)
        .frame(width: width, height: height)
        .glass(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(kept ? Color.green : Color.red, lineWidth: 3))
    }
}

/// Finestra di confronto: vive a parte dalla finestra principale per poter andare a schermo intero.
struct CompareWindow: View {
    var body: some View { CompareView() }
}

/// Schermo intero della finestra in primo piano.
enum FullScreen {
    @MainActor static func toggle() { (NSApp.keyWindow ?? NSApp.mainWindow)?.toggleFullScreen(nil) }
}

/// Permette alla finestra di andare a schermo intero (pulsante verde, menu Vista, ⌃⌘F).
struct WindowSetup: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            w.collectionBehavior.insert(.fullScreenPrimary)
            w.collectionBehavior.remove(.fullScreenNone)
            w.styleMask.insert(.resizable)
        }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {}
}

/// Anteprima grande di un file, intera (senza ritagli) o ingrandita su un punto.
struct LargePreview: View {
    let url: URL
    var zoom: CGFloat = 1
    @Binding var focus: CGPoint
    @State private var thumb: NSImage?
    @State private var full: NSImage?
    private static let cache = NSCache<NSURL, NSImage>()
    private static let fullCache: NSCache<NSURL, NSImage> = { let c = NSCache<NSURL, NSImage>(); c.countLimit = 8; return c }()

    private func fit(_ img: NSImage, in box: CGSize) -> CGSize {
        guard img.size.width > 0, img.size.height > 0, box.width > 0, box.height > 0 else { return .zero }
        let k = min(box.width / img.size.width, box.height / img.size.height)
        return CGSize(width: img.size.width * k, height: img.size.height * k)
    }

    private func offset(_ fitted: CGSize, in box: CGSize) -> CGSize {
        func axis(_ f: CGFloat, _ size: CGFloat, _ box: CGFloat) -> CGFloat {
            let room = max(0, (size - box) / 2)
            return min(room, max(-room, (0.5 - f) * size))
        }
        return CGSize(width: axis(focus.x, fitted.width * zoom, box.width), height: axis(focus.y, fitted.height * zoom, box.height))
    }

    var body: some View {
        GeometryReader { geo in
            if let img = (zoom > 1 ? full : nil) ?? thumb {
                let fitted = fit(img, in: geo.size)
                Image(nsImage: img).resizable().interpolation(.high)
                    .frame(width: fitted.width * zoom, height: fitted.height * zoom)
                    .offset(offset(fitted, in: geo.size))
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        guard zoom > 1, case .active(let p) = phase, fitted.width > 0, fitted.height > 0 else { return }
                        let x = (p.x - (geo.size.width - fitted.width) / 2) / fitted.width
                        let y = (p.y - (geo.size.height - fitted.height) / 2) / fitted.height
                        focus = CGPoint(x: min(1, max(0, x)), y: min(1, max(0, y)))
                    }
            } else {
                ProgressView().controlSize(.small).frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .task(id: url) {
            if let c = Self.cache.object(forKey: url as NSURL) { thumb = c; return }
            let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 1600, height: 1600),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2,
                                                   representationTypes: .thumbnail)
            if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) {
                Self.cache.setObject(rep.nsImage, forKey: url as NSURL)
                thumb = rep.nsImage
            } else {
                thumb = NSWorkspace.shared.icon(forFile: url.path)
            }
        }
        // Con l'ingrandimento si carica la foto a grandezza quasi piena, altrimenti i dettagli sarebbero sfocati.
        .task(id: zoom > 1 ? url : nil) {
            guard zoom > 1 else { return }
            let key = url as NSURL
            if let c = Self.fullCache.object(forKey: key) { full = c; return }
            let u = url
            let img: NSImage? = await Task.detached(priority: .userInitiated) {
                guard let src = CGImageSourceCreateWithURL(u as CFURL, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 4096] as CFDictionary) else { return nil }
                return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }.value
            if let img { Self.fullCache.setObject(img, forKey: key); full = img }
        }
    }
}

// MARK: - Barra dei menu

/// Ricerca rapida per nome dalla barra dei menu: cerca in tutto il Mac, nei dischi esterni e in rete.
struct MenuBarSearchView: View {
    @ObservedObject var m: SearchModel
    @Environment(\.openWindow) private var openWindow
    @FocusState private var focused: Bool

    private var ready: Bool { m.text.trimmingCharacters(in: .whitespaces).count >= 2 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Cerca file per nome", systemImage: "magnifyingglass")
                .font(.headline)
            HStack {
                TextField("Nome del file", text: $m.text)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .disabled(m.searching)
                    .onSubmit(start)
                if m.searching {
                    Button("Ferma") { m.stop() }
                } else {
                    Button("Cerca", action: start).prominentGlass().disabled(!ready)
                }
            }
            if m.searching {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("\(m.scanned) file controllati, \(m.all.count) trovati")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else {
                Text("Cerco in tutto il Mac e nei dischi esterni e di rete collegati.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Button("Apri Genuzzu") {
                    NSApp.activate(ignoringOtherApps: true)
                    if let w = NSApp.windows.first(where: { $0.canBecomeMain }) { w.makeKeyAndOrderFront(nil) }
                }
                Spacer()
                Button("Esci") { NSApp.terminate(nil) }
            }
            .buttonStyle(.link)
        }
        .padding(16)
        .frame(width: 360)
        .onAppear {
            m.useName = true
            m.searchComputer = true
            m.searchExternal = true
            m.searchNetwork = true
            m.refreshVolumes()
            m.onResults = {
                openWindow(id: "menu-results")
                NSApp.activate(ignoringOtherApps: true)
            }
            focused = true
        }
    }

    private func start() {
        guard ready, !m.searching else { return }
        m.search()
    }
}

/// Finestra con i risultati della ricerca dalla barra dei menu.
struct MenuBarResultsView: View {
    @ObservedObject var m: SearchModel
    @State private var selection = Set<String>()
    @FocusState private var listFocused: Bool

    private func previewIndex() -> Int { m.hits.firstIndex { selection.contains($0.id) } ?? 0 }
    private func preview() { QuickLook.shared.toggle(m.hits.map(\.url), index: previewIndex()) }

    /// Disco e cartella che contiene il file.
    private func place(_ url: URL) -> (badge: String, symbol: String, color: Color, folder: String) {
        let dir = url.deletingLastPathComponent().path
        if dir.hasPrefix("/Volumes/") {
            let parts = dir.dropFirst("/Volumes/".count).split(separator: "/")
            let name = parts.first.map(String.init) ?? "Disco"
            let network = m.volumes.first { $0.url.lastPathComponent == name }?.network ?? false
            return (name, network ? "network" : "externaldrive", network ? .purple : .teal,
                    parts.count > 1 ? parts.last.map(String.init) ?? "" : "Radice del disco")
        }
        return ("Questo Mac", "desktopcomputer", .blue, url.deletingLastPathComponent().lastPathComponent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(m.text.isEmpty ? "Risultati" : "Risultati per “\(m.text)”").font(.title3.weight(.semibold))
                Spacer()
                Text(m.status).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            if m.searching {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Ricerca ancora in corso…").font(.system(size: 13, weight: .semibold))
                        Text("Controllati \(m.scanned) file: l'elenco si aggiorna da solo e può ancora crescere.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Ferma") { m.stop() }
                }
                .padding(10)
                .glass(RoundedRectangle(cornerRadius: 14, style: .continuous), tint: .orange)
            }
            if m.hits.isEmpty && m.searching {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Nessun risultato per ora…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if m.hits.isEmpty {
                ContentUnavailableView("Nessun file trovato", systemImage: "magnifyingglass",
                                       description: Text("Prova con un altro nome o una parte più corta."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(m.hits, selection: $selection) { h in
                    let p = place(h.url)
                    HStack(spacing: 12) {
                        FileThumbnail(url: h.url)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(h.name).font(.system(size: 14, weight: .semibold))
                                .lineLimit(1).truncationMode(.middle)
                            HStack(spacing: 6) {
                                Label(p.badge, systemImage: p.symbol)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(p.color)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Capsule().fill(p.color.opacity(0.16)))
                                    .lineLimit(1)
                                Text(p.folder).font(.system(size: 12)).lineLimit(1).truncationMode(.head)
                            }
                            .help(h.url.deletingLastPathComponent().path)
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 2) {
                            if let s = h.size {
                                Text(ByteCountFormatter.string(fromByteCount: s, countStyle: .file))
                                    .font(.system(size: 12, weight: .medium))
                            }
                            if let d = h.date {
                                Text(d.formatted(date: .abbreviated, time: .omitted))
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                        .monospacedDigit().fixedSize()
                        Button {
                            selection = [h.id]
                            QuickLook.shared.toggle(m.hits.map(\.url), index: m.hits.firstIndex { $0.id == h.id } ?? 0)
                        } label: { Image(systemName: "eye") }
                            .buttonStyle(.borderless).help("Anteprima (barra spaziatrice)")
                        Button { NSWorkspace.shared.activateFileViewerSelecting([h.url]) } label: { Image(systemName: "folder") }
                            .buttonStyle(.borderless).help("Mostra nel Finder")
                    }
                    .padding(.vertical, 5)
                    .tag(h.id)
                }
                .scrollContentBackground(.hidden)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .glass(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .contextMenu(forSelectionType: String.self) { ids in
                    Button("Anteprima") { preview() }
                    Button("Mostra nel Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(ids.map { URL(fileURLWithPath: $0) })
                    }
                } primaryAction: { ids in
                    NSWorkspace.shared.open(ids.compactMap { URL(fileURLWithPath: $0) }.first ?? URL(fileURLWithPath: "/"))
                }
                .focused($listFocused)
                .onAppear { listFocused = true }
                .onKeyPress(.space) { preview(); return .handled }
                .onChange(of: selection) { _ in QuickLook.shared.follow(previewIndex()) }
            }
        }
        .padding()
        .frame(minWidth: 560, minHeight: 360)
        .background(AmbientBackground())
    }
}

@main
struct OrdinaCartelleApp: App {
    @StateObject private var quickSearch = SearchModel()

    var body: some Scene {
        WindowGroup("Genuzzu") { ContentView().background(WindowSetup()) }
            .commands {
                CommandGroup(replacing: .toolbar) {
                    Button("Schermo intero") { FullScreen.toggle() }
                        .keyboardShortcut("f", modifiers: [.command, .control])
                }
                CommandGroup(after: .appInfo) {
                    Button("Controlla aggiornamenti…") { Task { await Updater.check(silent: false) } }
                }
            }
        Window("Confronto", id: "compare") { CompareWindow() }
            .defaultSize(width: 1500, height: 940)
        Window("Impostazioni", id: "settings") { SettingsView() }
            .windowResizability(.contentSize)
        MenuBarExtra("Genuzzu", systemImage: "magnifyingglass") { MenuBarSearchView(m: quickSearch) }
            .menuBarExtraStyle(.window)
        Window("Risultati ricerca", id: "menu-results") { MenuBarResultsView(m: quickSearch) }
            .defaultSize(width: 720, height: 480)
    }
}
