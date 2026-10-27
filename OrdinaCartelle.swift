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

enum Part { case year, month, day, type }

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
        parts.map { p -> String in
            switch p { case .year: return "Anno"; case .month: return "Mese"; case .day: return "Giorno"; case .type: return "Tipo" }
        }.joined(separator: " / ")
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
    var layout: Layout = .yearMonthType
    var dateSource: DateSource = .exifThenCreation
    var monthStyle: MonthStyle = .numberName
    var leaveUnknownInPlace = false
    var excludedExts: Set<String> = []
    var minAgeDays = 0

    static var current: Prefs {
        let d = UserDefaults.standard
        var s = Prefs()
        s.layout = Layout(rawValue: d.string(forKey: "layout") ?? "") ?? .yearMonthType
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

    func folderComponents(year: Int, month: Int, day: Int, type: String) -> [String] {
        layout.parts.map { part in
            switch part {
            case .year: return String(year)
            case .day: return String(format: "%02d", day)
            case .type: return type
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
        (folderComponents(year: 2026, month: 10, day: 27, type: "Immagini") + ["foto.jpg"]).joined(separator: "/")
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
                                                  type: cat ?? "Altro")
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

    private static func viaGH() -> Data? {
        guard let gh = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { return nil }
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

    @MainActor
    static func check(silent: Bool) async {
        guard let r = await latest() else {
            if !silent { alert("Impossibile controllare gli aggiornamenti", "Verifica la connessione e che GitHub sia raggiungibile.") }
            return
        }
        if isNewer(r.version, than: currentVersion) {
            let a = NSAlert()
            a.messageText = "È disponibile la versione \(r.version)"
            a.informativeText = "Stai usando la \(currentVersion). Vuoi aprire la pagina di download?"
            a.addButton(withTitle: "Scarica")
            a.addButton(withTitle: "Più tardi")
            if a.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(r.url) }
        } else if !silent {
            alert("Sei aggiornato", "Stai usando l'ultima versione (\(currentVersion)).")
        }
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
    @State private var previewMode = 0
    @Environment(\.openWindow) private var openWindow
    @AppStorage("autoUpdateCheck") private var autoUpdateCheck = true
    @AppStorage("layout") private var layout = Layout.yearMonthType.rawValue
    @State private var confirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
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
                Text("Struttura: " + (Layout(rawValue: layout)?.title ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
            }

            if vm.moves.isEmpty {
                VStack {
                    Spacer()
                    Text(vm.status).foregroundStyle(.secondary)
                    if vm.folder == nil { Text("oppure trascina qui una cartella").font(.caption).foregroundStyle(.tertiary) }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                Picker("Anteprima", selection: $previewMode) {
                    Text("Per cartella").tag(0)
                    Text("Elenco").tag(1)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 220)

                if previewMode == 0 {
                    List {
                        ForEach(vm.groups, id: \.folder) { g in
                            Section {
                                ForEach(g.moves) { m in
                                    HStack {
                                        Image(systemName: "doc")
                                        Text(m.dest.lastPathComponent)
                                        if m.dest.lastPathComponent != m.source.lastPathComponent {
                                            Text("(da \(m.source.lastPathComponent))").foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            } header: {
                                Label("\(g.folder)  ·  \(g.moves.count) file", systemImage: "folder.fill")
                                    .font(.headline)
                            }
                        }
                    }
                } else {
                    List(vm.moves) { m in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(vm.relative(m.source)).font(.body)
                            Text("→ " + vm.relative(m.dest))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            HStack {
                if !vm.moves.isEmpty { Text(vm.status).foregroundStyle(.secondary) }
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
        .frame(minWidth: 720, minHeight: 480)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            vm.setFolder(url)
            return true
        }
        .task { if autoUpdateCheck { await Updater.check(silent: true) } }
        .alert("Spostare \(vm.moves.count) file?", isPresented: $confirm) {
            Button("Ordina") { vm.organize() }
            Button("Cancella", role: .cancel) {}
        } message: {
            Text("I file saranno organizzati secondo la struttura scelta nelle impostazioni dentro la cartella scelta. Potrai annullare l'operazione.")
        }
    }
}

struct SettingsView: View {
    @AppStorage("layout") private var layout = Layout.yearMonthType.rawValue
    @AppStorage("monthStyle") private var monthStyle = MonthStyle.numberName.rawValue
    @AppStorage("dateSource") private var dateSource = DateSource.exifThenCreation.rawValue
    @AppStorage("leaveUnknownInPlace") private var leaveUnknown = false
    @AppStorage("excludedExts") private var excluded = ""
    @AppStorage("minAgeDays") private var minAgeDays = 0
    @AppStorage("autoUpdateCheck") private var autoUpdateCheck = true

    var body: some View {
        Form {
            Section("Struttura delle cartelle") {
                Picker("Organizza per", selection: $layout) {
                    ForEach(Layout.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Picker("Formato del mese", selection: $monthStyle) {
                    ForEach(MonthStyle.allCases) { Text($0.title).tag($0.rawValue) }
                }
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
            Section("Aggiornamenti") {
                LabeledContent("Versione installata", value: Updater.currentVersion)
                Toggle("Controlla gli aggiornamenti all'avvio", isOn: $autoUpdateCheck)
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
        WindowGroup("Ordina Cartelle") { ContentView() }
            .commands {
                CommandGroup(after: .appInfo) {
                    Button("Controlla aggiornamenti…") { Task { await Updater.check(silent: false) } }
                }
            }
        Window("Impostazioni", id: "settings") { SettingsView() }
            .windowResizability(.contentSize)
    }
}
