import SwiftUI
import ImageIO
import AppKit

// MARK: - Modello

struct PlannedMove: Identifiable {
    let id = UUID()
    let source: URL
    let dest: URL
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

    static var current: Prefs {
        let d = UserDefaults.standard
        var s = Prefs()
        s.parts = resolveParts(layoutParts: d.string(forKey: "layoutParts") ?? "", legacy: d.string(forKey: "layout") ?? "")
        s.dateSource = DateSource(rawValue: d.string(forKey: "dateSource") ?? "") ?? .exifThenCreation
        s.monthStyle = MonthStyle(rawValue: d.string(forKey: "monthStyle") ?? "") ?? .numberName
        s.leaveUnknownInPlace = d.bool(forKey: "leaveUnknownInPlace")
        s.minAgeDays = d.integer(forKey: "minAgeDays")
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

    static func plan(root: URL, recursive: Bool, settings: Prefs) -> [PlannedMove] {
        let fm = FileManager.default
        var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        if !recursive { options.insert(.skipsSubdirectoryDescendants) }
        guard let en = fm.enumerator(at: root,
                                     includingPropertiesForKeys: [.isRegularFileKey, .isPackageKey, .contentModificationDateKey],
                                     options: options) else { return [] }
        let cal = Calendar.current
        var used = Set<String>()
        var moves: [PlannedMove] = []

        for case let url as URL in en {
            let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .isPackageKey, .contentModificationDateKey])
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

            if url.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL { continue }

            let dest = uniqueDestination(dir: dir, name: url.lastPathComponent, used: &used)
            moves.append(PlannedMove(source: url, dest: dest))
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

    struct Release { let version: String; let url: URL }

    /// Usa `gh` (già autenticato sul Mac, funziona anche con repo privato); in alternativa l'API pubblica.
    static func latest() async -> Release? {
        await Task.detached { () -> Release? in
            guard let data = viaGH() ?? viaHTTP(),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
            return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, url: page)
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

    /// Scarica lo zip della release, lo estrae e sostituisce l'app in esecuzione.
    static func install(_ r: Release) async -> Bool {
        await Task.detached { () -> Bool in
            let fm = FileManager.default
            let tmp = fm.temporaryDirectory.appendingPathComponent("ordina-update-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: tmp) }
            let out = tmp.appendingPathComponent("x")
            guard Bundle.main.bundleURL.pathExtension == "app",
                  let gh = ghPath(),
                  (try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)) != nil,
                  run(gh, ["release", "download", "v\(r.version)", "-R", repo, "-p", "*.zip", "-D", tmp.path]) == 0,
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
            await MainActor.run {
                self.moves = result
                self.busy = false
                self.phase = result.isEmpty ? .ordered : .preview
                self.status = result.isEmpty
                    ? "Niente da spostare: la cartella è già in ordine."
                    : "\(result.count) file verranno spostati in \(Set(result.map { $0.dest.deletingLastPathComponent() }).count) cartelle. Nessun file è stato ancora toccato: controlla l'anteprima, poi premi “Ordina”."
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

struct ContentView: View {
    @StateObject private var vm = ViewModel()
    @Environment(\.openWindow) private var openWindow
    @AppStorage("autoUpdateCheck") private var autoUpdateCheck = true
    @AppStorage("layoutParts") private var layoutParts = ""
    @AppStorage("layout") private var legacyLayout = ""
    @State private var confirm = false
    @State private var dropTargeted = false
    @State private var section = 0
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @StateObject private var search = SearchModel()

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(vm: vm)
                .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 260)
        } detail: {
            VStack(spacing: 0) {
                Picker("Sezione", selection: $section) {
                    Text("Ordina").tag(0)
                    Text("Cerca file").tag(1)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 240)
                .padding([.top, .horizontal])
                if section == 0 { sortView } else { SearchView(m: search) { url in
                    vm.setFolder(url)
                    section = 0
                } }
                GenuzzuFooter(context: mascotContext)
            }
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

                if geo.size.width >= 600 {
                    HStack(spacing: 16) {
                        DropZoneView(vm: vm, targeted: dropTargeted)
                            .frame(minWidth: 220, maxWidth: 300)
                        right
                    }
                } else {
                    // Finestra stretta: area di drop sopra, animazione/anteprima sotto.
                    VStack(spacing: 12) {
                        DropZoneView(vm: vm, targeted: dropTargeted)
                            .frame(minHeight: 140, maxHeight: 190)
                        right.frame(minHeight: 160)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.25), value: vm.moves.isEmpty)

            HStack {
                if vm.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Annulla ultimo ordinamento") { vm.undo() }
                    .disabled(!vm.canUndo || vm.busy)
                Button("Ordina") { confirm = true }
                    .buttonStyle(.borderedProminent)
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
    var key: String { self == .modified ? NSMetadataItemFSContentChangeDateKey : NSMetadataItemFSCreationDateKey }
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

/// Filtro generico per tipo di file, basato sui tipi di contenuto di Spotlight.
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
    var predicate: NSPredicate? {
        let parts = types.map { NSPredicate(format: "%K == %@", NSMetadataItemContentTypeTreeKey, $0) }
        switch parts.count {
        case 0: return nil
        case 1: return parts[0]   // NSMetadataQuery rifiuta predicati composti da un solo elemento
        default: return NSCompoundPredicate(orPredicateWithSubpredicates: parts)
        }
    }
}

@MainActor
final class SearchModel: ObservableObject {
    /// Criteri di ricerca: ognuno si accende da solo e, se ce n'è più di uno, valgono tutti insieme.
    @Published var useName = true
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
    @Published var useDestination = false
    /// Cartella in cui cercare; nil = tutto il computer.
    @Published var scope: URL?
    @Published var busy = false
    /// Cartella in cui proporre il riordino dopo una copia/spostamento riusciti.
    @Published var offerSort: URL?
    @Published var status = "Scrivi una parte del nome dei file e premi Invio."
    @Published var lastMoved: [(from: URL, to: URL)] = []
    private var query: NSMetadataQuery?
    private var observer: NSObjectProtocol?
    private static let maxHits = 5000

    /// Esclude Libreria, pacchetti .app e cartelle nascoste, a meno che si chieda di includerli.
    var hits: [Hit] {
        includeSystem || scope != nil ? all : all.filter { h in
            let p = h.url.path
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
        query?.stop()
        if let o = observer { NotificationCenter.default.removeObserver(o) }
        all = []
        selection = []
        searching = true
        status = "Ricerca in corso…"

        let q = NSMetadataQuery()
        var parts = words.map { NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemFSNameKey, $0) }
        if useDate {
            // Dal primo istante del giorno "dal" fino alla fine del giorno "al" (le due date si possono invertire).
            let cal = Calendar.current
            let lo = cal.startOfDay(for: min(from, to))
            let hi = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: max(from, to))) ?? max(from, to)
            parts.append(NSPredicate(format: "%K >= %@ AND %K < %@", dateField.key, lo as NSDate, dateField.key, hi as NSDate))
        }
        if useKind, let k = kind.predicate { parts.append(k) }
        // NSMetadataQuery lancia un'eccezione con un predicato composto da un solo elemento.
        q.predicate = parts.count == 1 ? parts[0] : NSCompoundPredicate(andPredicateWithSubpredicates: parts)
        q.searchScopes = [scope?.path ?? NSMetadataQueryLocalComputerScope]
        observer = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering, object: q, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.finish() }
        }
        query = q
        q.start()
    }

    private func finish() {
        guard let q = query else { return }
        q.disableUpdates()
        var found: [Hit] = []
        for case let item as NSMetadataItem in q.results {
            guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            let tree = item.value(forAttribute: NSMetadataItemContentTypeTreeKey) as? [String] ?? []
            if tree.contains("public.folder") { continue }
            found.append(Hit(url: URL(fileURLWithPath: path),
                             size: (item.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?.int64Value,
                             date: item.value(forAttribute: useDate ? dateField.key : NSMetadataItemFSContentChangeDateKey) as? Date))
        }
        q.stop()
        found.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        all = Array(found.prefix(Self.maxHits))
        selection = Set(hits.map(\.id))
        searching = false
        let n = hits.count
        status = n == 0 ? "Nessun file trovato."
            : "\(n) file trovati" + (found.count > Self.maxHits ? " (mostrati i primi \(Self.maxHits): restringi la ricerca)." : ".")
    }

    /// Svuota testo e risultati (interrompendo una ricerca in corso); cartella di ricerca e destinazione restano.
    func clear() {
        query?.stop()
        if let o = observer { NotificationCenter.default.removeObserver(o); observer = nil }
        query = nil
        text = ""
        useName = true
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
        (useName && !text.trimmingCharacters(in: .whitespaces).isEmpty) || useDate || useKind
    }

    /// Riassunto a parole di cosa verrà cercato, mostrato sotto il pulsante Cerca.
    var summary: String {
        guard canSearch else { return "Scegli almeno un criterio di ricerca, poi premi Cerca." }
        var bits: [String] = []
        if useName, !text.trimmingCharacters(in: .whitespaces).isEmpty { bits.append("nome con “\(text.trimmingCharacters(in: .whitespaces))”") }
        if useDate { bits.append("\(dateField.title) \(rangeDescription)") }
        if useKind { bits.append("tipo: \(kind.title.lowercased())") }
        return "Cercherò file con " + bits.joined(separator: " · ") + " — in " + (scope?.lastPathComponent ?? "tutto il computer")
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
        if p.runModal() == .OK, let url = p.url { scope = url.standardizedFileURL }
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
                HStack(spacing: 8) { actions }.font(.caption)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(color.opacity(0.08)))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
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
                Text(month.formatted(.dateTime.month(.wide).year()).capitalized).font(.headline)
                Spacer()
                Button { shift(1) } label: { Image(systemName: "chevron.right") }
            }
            .buttonStyle(.borderless)

            HStack(spacing: 0) {
                ForEach(Array(["L", "M", "M", "G", "V", "S", "D"].enumerated()), id: \.offset) { _, d in
                    Text(d).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 2) {
                ForEach(cells) { c in
                    if let d = c.date {
                        let day = cal.startOfDay(for: d)
                        let isEnd = day == lo || day == hi
                        let inRange = day >= lo && day <= hi
                        Button { tap(d) } label: {
                            Text("\(cal.component(.day, from: d))")
                                .font(.callout.weight(isEnd ? .bold : .regular).monospacedDigit())
                                .foregroundStyle(isEnd ? Color.white : .primary)
                                .frame(maxWidth: .infinity, minHeight: 26)
                                .background {
                                    ZStack {
                                        if inRange { Rectangle().fill(Color.accentColor.opacity(0.2)) }
                                        if isEnd { Circle().fill(Color.accentColor) }
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
                        Color.clear.frame(height: 26)
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

    // Soglie di larghezza (area utile della vista) oltre le quali si passa dal layout stretto a quello largo.
    private let mediumWidth: CGFloat = 600
    private let wideWidth: CGFloat = 720
    /// Sopra questa larghezza la ricerca sta a sinistra e animazione/risultati a destra.
    private let twoColumnWidth: CGFloat = 800

    private func stepCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) { content() }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.06)))
    }

    private func stepHeader(_ n: Int, _ title: String, _ subtitle: String? = nil) -> some View {
        HStack(spacing: 8) {
            Text("\(n)").font(.caption.weight(.bold)).foregroundStyle(.white)
                .frame(width: 22, height: 22).background(Circle().fill(Color.accentColor))
            Text(title).font(.headline)
            if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }
    }

    private func criterionTile(_ title: String, _ symbol: String, _ subtitle: String, isOn: Binding<Bool>) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: isOn.wrappedValue ? "checkmark.circle.fill" : symbol)
                    .font(.system(size: 18))
                    .foregroundStyle(isOn.wrappedValue ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(isOn.wrappedValue ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isOn.wrappedValue ? Color.accentColor : Color.secondary.opacity(0.3),
                              lineWidth: isOn.wrappedValue ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var dateOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $m.dateField) {
                Text("Modificati").tag(SearchDateField.modified)
                Text("Creati").tag(SearchDateField.created)
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 200)
            Text("File \(m.dateField.title) \(m.rangeDescription)")
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Menu("Scorciatoie…") {
                ForEach(DatePreset.allCases) { p in Button(p.title) { m.select(p) } }
            }
            .fixedSize()
            Text("Clicca due giorni sul calendario per scegliere il periodo.")
                .font(.caption).foregroundStyle(.secondary)
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
                            dateOptions
                            Spacer(minLength: 0)
                        }
                    } else {
                        RangeCalendarView(from: $m.from, to: $m.to).frame(maxWidth: 300)
                        dateOptions
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
            Toggle("Includi file di sistema e della Libreria", isOn: $m.includeSystem)
                .disabled(m.scope != nil)
                .lineLimit(1)
                .font(.callout)
        }
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Button { m.search() } label: {
                    HStack(spacing: 6) {
                        if m.searching { ProgressView().controlSize(.small) }
                        else { Image(systemName: "magnifyingglass") }
                        Text(m.searching ? "Ricerca…" : "Cerca")
                    }
                    .font(.headline)
                    .frame(minWidth: 110)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!m.canSearch || m.searching || m.busy)
                Spacer(minLength: 8)
                Button { m.clear() } label: { Label("Pulisci tutto", systemImage: "xmark.circle") }
                    .buttonStyle(.borderless).font(.caption)
                    .disabled(m.busy || (m.text.isEmpty && !m.useDate && !m.useKind && m.all.isEmpty && !m.searching))
            }
            Text(m.summary).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var originCard: some View {
        PlaceCard(role: "ORIGINE", symbol: "magnifyingglass", color: .blue,
                  path: m.scope?.path ?? "Tutto il computer", placeholder: "") {
            Button("Scegli cartella…") { m.chooseScope() }
            if m.scope != nil { Button("Tutto il computer") { m.scope = nil } }
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
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.teal.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private var destinationSlot: some View {
        Group { if m.useDestination { destinationCard } else { addDestinationCard } }
    }

    private var resultsList: some View {
        List(m.hits, selection: $m.selection) { h in
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: h.url.path))
                    .resizable().frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(h.name).lineLimit(1).truncationMode(.middle)
                    Text(h.url.deletingLastPathComponent().path
                            .replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.head)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 1) {
                    if let s = h.size { Text(ByteCountFormatter.string(fromByteCount: s, countStyle: .file)) }
                    if let d = h.date { Text(d.formatted(date: .abbreviated, time: .omitted)) }
                }
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize()
            }
            .tag(h.id)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            Button("Mostra nel Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(ids.map { URL(fileURLWithPath: $0) })
            }
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
                .buttonStyle(.borderedProminent)
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
                    SearchAnimationView(name: m.useName, date: m.useDate, kind: m.useKind ? m.kind : nil,
                                        copy: m.useDestination)
                        .frame(minHeight: 220)
                    Text(m.status).foregroundStyle(.secondary).font(.callout)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                resultsList
                HStack {
                    Text(m.useDestination ? "\(m.hits.count) trovati · \(m.selectedHits.count) selezionati"
                                          : "\(m.hits.count) file trovati")
                        .foregroundStyle(.secondary)
                    Spacer()
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

    /// Finestra stretta: tutto in colonna, comandi sopra e risultati sotto.
    private func stacked(medium: Bool, wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            criteriaCard(medium: medium)
            if wide {
                HStack(alignment: .top, spacing: 12) { whereCard; afterCard }
            } else {
                whereCard
                afterCard
            }
            searchButton
            resultsArea(medium: medium)
        }
    }

    /// Finestra larga: comandi a sinistra (con Cerca sempre visibile), animazione o risultati a destra.
    private func twoColumns(width: CGFloat) -> some View {
        let left = min(max(width * 0.42, 340), 430)
        let rightWidth = width - left - 16 - 32
        return HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 12) {
                        criteriaCard(medium: false)
                        whereCard
                        afterCard
                    }
                    .padding(.trailing, 6)
                }
                Divider()
                searchButton
            }
            .frame(width: left)
            resultsArea(medium: rightWidth >= 560)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding()
    }

    var body: some View {
        // Se la finestra è bassa il contenuto scorre; se è alta l'elenco dei risultati occupa lo spazio in più.
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
                Text("Li dispone in sottocartelle per data e tipo, come la sezione Ordina. Vedrai prima l'anteprima e non verrà toccato nulla finché non confermi. Verrà considerata l'intera cartella, compresi i file che c'erano già.")
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
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey],
                                                         options: [.skipHiddenVolumes]) ?? []
        return urls.filter { $0.path.hasPrefix("/Volumes/") }.map {
            let name = (try? $0.resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? $0.lastPathComponent
            return Place(name: name, symbol: "externaldrive", url: $0)
        }
    }

    var body: some View {
        let volumes = Self.volumes()
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
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(targeted ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
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

    private func rows() -> [Row] {
        let root = Node()
        for m in vm.moves {
            let comps = vm.relative(m.dest).split(separator: "/").map(String.init)
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
            for m in node.files.sorted(by: { $0.dest.lastPathComponent.localizedStandardCompare($1.dest.lastPathComponent) == .orderedAscending }) {
                let renamed = m.dest.lastPathComponent != m.source.lastPathComponent
                out.append(Row(id: m.id.uuidString, depth: depth, name: m.dest.lastPathComponent, isFolder: false,
                               count: 0, note: renamed ? "da \(m.source.lastPathComponent)" : nil))
            }
        }
        if !collapsed.contains("/") { walk(root, path: "", depth: 1) }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Dopo il riordino la tua cartella apparirà così")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Vista", selection: $mode) {
                Text("Struttura").tag(0)
                Text("Elenco spostamenti").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 260)

            if mode == 0 {
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
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.secondary.opacity(0.06)))
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
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.secondary.opacity(0.06)))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func scene(t: Double, w: CGFloat, h: CGFloat) -> some View {
        let list = items
        let hits = list.indices.filter { list[$0].hit }
        let step = min(w * 0.14, 72)
        let cx = w * 0.33
        let point = { (i: Int) -> CGPoint in
            CGPoint(x: cx + (CGFloat(i % 4) - 1.5) * step, y: h * (i < 4 ? 0.42 : 0.70))
        }
        let target = CGPoint(x: w * 0.84, y: h * 0.56)
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
            if minWidth > 0 { Spacer(minLength: 0) }
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
            .background(RoundedRectangle(cornerRadius: 6).fill(f.color.gradient))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.yellow, lineWidth: hit ? 3 : 0))
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
                .background(RoundedRectangle(cornerRadius: 6).fill(f.color.gradient))
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                .scaleEffect(1 - 0.45 * e)
                .opacity(1 - pow(p, 4))
                .position(x: from.x + (to.x - from.x) * e,
                          y: from.y + (to.y - from.y) * e - CGFloat(sin(.pi * e)) * 30)
        }
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
                                .background(RoundedRectangle(cornerRadius: 6).fill(item.color.gradient))
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
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.secondary.opacity(0.06)))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityHidden(true)
    }
}

// MARK: - Genuzzu, la mascotte

enum GenuzzuMood { case happy, shocked, oops, wink }

/// Genuzzu disegnato a vettori: testa grande, contorni neri spessi, occhioni e hatching sulle guance (stile manga anni '90).
struct GenuzzuView: View {
    var mood: GenuzzuMood = .happy
    var talking = false

    private static let skin = Color(red: 0.99, green: 0.83, blue: 0.65)
    private static let shirt = Color(red: 0.12, green: 0.18, blue: 0.40)
    private static let iris = Color(red: 0.48, green: 0.29, blue: 0.13)
    private static let ink = Color.black

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let s = min(size.width / 200, size.height / 190)
                var c = ctx
                c.translateBy(x: (size.width - 200 * s) / 2, y: (size.height - 190 * s) / 2)
                c.scaleBy(x: s, y: s)
                // Dondola appena, come uno che non sta mai fermo.
                c.translateBy(x: 100, y: 175 + sin(t * 2.2) * 1.5)
                c.rotate(by: .degrees(sin(t * 1.3) * 1.8))
                c.translateBy(x: -100, y: -175)
                let blink = t.truncatingRemainder(dividingBy: 4.3) < 0.14
                let open = talking ? 0.35 + 0.65 * abs(sin(t * 9)) : 0.55
                Self.draw(c, mood: mood, blink: blink, open: open, look: sin(t * 0.7) * 2)
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

    private static func draw(_ c: GraphicsContext, mood: GenuzzuMood, blink: Bool, open: Double, look: Double) {
        // Maglietta blu e collo
        var shirtPath = Path()
        shirtPath.move(to: CGPoint(x: 44, y: 194))
        shirtPath.addCurve(to: CGPoint(x: 78, y: 166), control1: CGPoint(x: 46, y: 176), control2: CGPoint(x: 62, y: 170))
        shirtPath.addLine(to: CGPoint(x: 122, y: 166))
        shirtPath.addCurve(to: CGPoint(x: 156, y: 194), control1: CGPoint(x: 138, y: 170), control2: CGPoint(x: 154, y: 176))
        shirtPath.closeSubpath()
        fillStroke(c, Path(CGRect(x: 86, y: 150, width: 28, height: 24)), skin)
        fillStroke(c, shirtPath, shirt)
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
                    .background(SpeechBubble().fill(Color.secondary.opacity(0.12)))
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

struct SpeechBubble: Shape {
    func path(in r: CGRect) -> Path {
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
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

@main
struct OrdinaCartelleApp: App {
    var body: some Scene {
        WindowGroup("Genuzzu") { ContentView() }
            .commands {
                CommandGroup(after: .appInfo) {
                    Button("Controlla aggiornamenti…") { Task { await Updater.check(silent: false) } }
                }
            }
        Window("Impostazioni", id: "settings") { SettingsView() }
            .windowResizability(.contentSize)
    }
}
