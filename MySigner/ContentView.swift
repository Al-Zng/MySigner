import SwiftUI
import UniformTypeIdentifiers
import Network
import Foundation

// MARK: - Models
struct AppItem: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    var name: String
    var version: String
    var bundleID: String
    var ipaURL: String
    var iconURL: String?
    var localPath: String?
    var isDownloaded: Bool = false
    var isInstalled: Bool = false
    var signedDate: Date?
}

struct DownloadItem: Identifiable, Codable {
    var id = UUID()
    var name: String
    var size: String = ""
    var ipaURL: String
    var progress: Double = 0.0
}

struct Source: Identifiable, Codable {
    var id = UUID()
    var name: String
    var url: String
}

struct Certificate: Identifiable {
    let id = UUID()
    var name: String
    var bundleID: String
    var daysLeft: Int
    var isValid: Bool
    var p12URL: URL?
    var provisionURL: URL?
}

// MARK: - App Store Manager
class AppStore: ObservableObject {
    @Published var certificates: [Certificate] = []
    @Published var apps: [AppItem] = []
    @Published var downloads: [DownloadItem] = []
    @Published var sources: [Source] = []

    let server = LocalHTTPServer()

    private let baseDir: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("MySignerStore")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    let appsDir: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("MySignerApps")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    init() { loadAll() }

    // MARK: - Persistence
    private func save<T: Codable>(_ items: [T], to filename: String) {
        let url = baseDir.appendingPathComponent(filename)
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: url)
        } catch { print("Save error: \(error)") }
    }

    private func load<T: Codable>(_ type: T.Type, from filename: String) -> [T] {
        let url = baseDir.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([T].self, from: data) else { return [] }
        return items
    }

    func loadAll() {
        apps = load(AppItem.self, from: "apps.json")
        downloads = load(DownloadItem.self, from: "downloads.json")
        sources = load(Source.self, from: "sources.json")
    }

    func saveAll() {
        save(apps, to: "apps.json")
        save(downloads, to: "downloads.json")
        save(sources, to: "sources.json")
    }

    // MARK: - Fetch Source (يحضر التطبيقات من رابط JSON)
    func fetch(source: Source, completion: @escaping (Result<Int, Error>) -> Void) {
        guard let url = URL(string: source.url) else {
            completion(.failure(URLError(.badURL)))
            return
        }
        URLSession.shared.dataTask(with: url) { data, _, error in
            DispatchQueue.main.async {
                if let error = error { completion(.failure(error)); return }
                guard let data = data else { completion(.failure(URLError(.cannotParseResponse))); return }
                do {
                    var fetched = try JSONDecoder().decode([AppItem].self, from: data)
                    let existingIDs = Set(self.apps.map { $0.bundleID })
                    fetched = fetched.filter { !existingIDs.contains($0.bundleID) }
                    self.apps.append(contentsOf: fetched)
                    self.saveAll()
                    completion(.success(fetched.count))
                } catch {
                    completion(.failure(error))
                }
            }
        }.resume()
    }

    // MARK: - Download IPA (حقيقي مع Progress)
    func download(app: AppItem) {
        guard let url = URL(string: app.ipaURL) else { return }
        let item = DownloadItem(name: app.name, ipaURL: app.ipaURL)
        downloads.append(item)
        saveAll()

        let task = URLSession.shared.downloadTask(with: url) { localURL, _, error in
            DispatchQueue.main.async {
                defer {
                    self.downloads.removeAll { $0.id == item.id }
                    self.saveAll()
                }
                guard let localURL = localURL, error == nil else { return }
                let filename = "\(app.bundleID).ipa"
                let dest = self.appsDir.appendingPathComponent(filename)
                try? FileManager.default.removeItem(at: dest)
                do {
                    try FileManager.default.moveItem(at: localURL, to: dest)
                    if let idx = self.apps.firstIndex(where: { $0.id == app.id }) {
                        self.apps[idx].localPath = dest.path
                        self.apps[idx].isDownloaded = true
                    }
                } catch { print("Move error: \(error)") }
            }
        }
        let observation = task.progress.observe(\.fractionCompleted) { [weak self] prog, _ in
            DispatchQueue.main.async {
                if let idx = self?.downloads.firstIndex(where: { $0.name == item.name }) {
                    self?.downloads[idx].progress = prog.fractionCompleted
                }
            }
        }
        task.resume()
        _ = observation
    }

    // MARK: - Install via local server (حقيقي)
    func install(app: AppItem) {
        guard let localPath = app.localPath, FileManager.default.fileExists(atPath: localPath) else { return }
        if !server.isRunning { server.start() }
        let manifest: [String: Any] = [
            "items": [
                [
                    "assets": [
                        ["kind": "software-package", "url": "http://localhost:\(server.port)/ipa/\(app.bundleID).ipa"],
                        ["kind": "display-image", "url": ""],
                        ["kind": "full-size-image", "url": ""]
                    ],
                    "metadata": [
                        "bundle-identifier": app.bundleID,
                        "bundle-version": app.version,
                        "kind": "software",
                        "title": app.name
                    ]
                ]
            ]
        ]
        let plistData = try? PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0)
        server.manifestData = plistData
        server.ipaFilePath = localPath

        let urlString = "itms-services://?action=download-manifest&url=http://localhost:\(server.port)/manifest.plist"
        if let url = URL(string: urlString) {
            UIApplication.shared.open(url)
        }
    }

    // MARK: - Import IPA from file
    func importIPA(from url: URL) {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        let dest = appsDir.appendingPathComponent(url.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: url, to: dest)
        } catch { print("Import error: \(error)"); return }
        let name = url.deletingPathExtension().lastPathComponent
        let newApp = AppItem(name: name, version: "1.0", bundleID: "imported.\(UUID().uuidString.prefix(8))",
                             ipaURL: "", localPath: dest.path, isDownloaded: true)
        apps.append(newApp)
        saveAll()
    }

    // MARK: - Remote Signing Trigger (يستخدم توكنك مباشرة)
    private let githubToken = "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"  // <-- ضع توكنك هنا

    func triggerRemoteSign(app: AppItem, p12Base64: String, provisionBase64: String, password: String, completion: @escaping (Bool, String) -> Void) {
        let owner = "Al-Zng"
        let repo = "MySigner"
        guard !githubToken.isEmpty else {
            completion(false, "Internal token missing")
            return
        }
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/actions/workflows/sign_remote.yml/dispatches") else {
            completion(false, "Bad URL")
            return
        }

        let ipaInput = app.ipaURL.isEmpty ? "file://\(app.localPath ?? "")" : app.ipaURL
        let body: [String: Any] = [
            "ref": "main",
            "inputs": [
                "ipa_url": ipaInput,
                "p12_base64": p12Base64,
                "mobileprovision_base64": provisionBase64,
                "password": password,
                "app_name": app.name
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(githubToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(false, error.localizedDescription)
                    return
                }
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 204 {
                    completion(true, "Signing started. Check your repo artifacts.")
                } else {
                    completion(false, "Status: \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                }
            }
        }.resume()
    }
}

// MARK: - Local HTTP Server
class LocalHTTPServer {
    private var listener: NWListener?
    let port: UInt16 = 8080
    private(set) var isRunning = false
    var manifestData: Data?
    var ipaFilePath: String?

    func start() {
        guard !isRunning else { return }
        let params = NWParameters.tcp
        listener = try? NWListener(using: params, on: .init(integerLiteral: port))
        listener?.stateUpdateHandler = { state in
            switch state {
            case .ready: self.isRunning = true
            case .failed, .cancelled: self.isRunning = false
            default: break
            }
        }
        listener?.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .main)
            self?.receive(on: connection)
        }
        listener?.start(queue: .main)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            if let data = data, let request = String(data: data, encoding: .utf8) {
                self?.handleRequest(request, connection: connection)
            } else if error == nil {
                self?.receive(on: connection)
            }
        }
    }

    private func handleRequest(_ request: String, connection: NWConnection) {
        let lines = request.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else { connection.cancel(); return }
        let components = firstLine.components(separatedBy: " ")
        guard components.count >= 2, components[0] == "GET" else { connection.cancel(); return }
        let path = components[1]

        let respond: (Data, String) -> Void = { body, mime in
            var response = "HTTP/1.1 200 OK\r\n"
            response += "Content-Type: \(mime)\r\n"
            response += "Content-Length: \(body.count)\r\n"
            response += "Connection: close\r\n\r\n"
            let headerData = response.data(using: .utf8)!
            connection.send(content: headerData, completion: .idempotent)
            connection.send(content: body, completion: .idempotent)
            connection.cancel()
        }

        if path == "/manifest.plist", let data = manifestData {
            respond(data, "text/xml")
        } else if path.hasPrefix("/ipa/") {
            if let ipaPath = ipaFilePath, let ipaData = try? Data(contentsOf: URL(fileURLWithPath: ipaPath)) {
                respond(ipaData, "application/octet-stream")
            } else { connection.cancel() }
        } else {
            connection.cancel()
        }
    }
}

// MARK: - Document Picker helper
struct DocumentPicker: UIViewControllerRepresentable {
    var types: [UTType]
    var onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}

// MARK: - Main ContentView
struct ContentView: View {
    @StateObject private var store = AppStore()
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            FilesView()
                .tabItem { Label("Files", systemImage: "folder.fill") }
                .tag(0)

            LibraryView()
                .tabItem { Label("Library", systemImage: "square.grid.2x2.fill") }
                .tag(1)

            AppStoreView()
                .tabItem { Label("App Store", systemImage: "plus.app.fill") }
                .tag(2)

            DownloadsView()
                .tabItem { Label("Downloads", systemImage: "arrow.down.app.fill") }
                .tag(3)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.2.fill") }
                .tag(4)
        }
        .accentColor(.blue)
        .preferredColorScheme(.dark)
        .environmentObject(store)
    }
}

// MARK: - Files View (جميل كما أردت)
struct FilesView: View {
    @EnvironmentObject var store: AppStore
    @State private var showImporter = false
    @State private var importedFiles: [URL] = []

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                if importedFiles.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 52))
                            .foregroundColor(.gray)
                        Text("No Files")
                            .foregroundColor(.gray)
                        Button("Import File") { showImporter = true }
                            .foregroundColor(.blue)
                    }
                } else {
                    List {
                        ForEach(importedFiles, id: \.self) { url in
                            HStack(spacing: 14) {
                                Image(systemName: fileIcon(for: url))
                                    .foregroundColor(.blue)
                                    .font(.title2)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(url.lastPathComponent)
                                        .foregroundColor(.white)
                                    Text(fileSize(url: url))
                                        .foregroundColor(.gray)
                                        .font(.caption)
                                }
                            }
                            .listRowBackground(Color(white: 0.1))
                        }
                        .onDelete { idx in importedFiles.remove(atOffsets: idx) }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Documents")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showImporter = true }) {
                        Image(systemName: "plus")
                    }
                }
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.item],
                          allowsMultipleSelection: true) { result in
                if let urls = try? result.get() {
                    urls.forEach { url in
                        _ = url.startAccessingSecurityScopedResource()
                        if !importedFiles.contains(url) {
                            importedFiles.append(url)
                        }
                    }
                }
            }
        }
    }

    func fileIcon(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "ipa": return "archivebox.fill"
        case "p12": return "lock.shield.fill"
        case "mobileprovision": return "doc.badge.gearshape.fill"
        default: return "doc.fill"
        }
    }

    func fileSize(url: URL) -> String {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let mb = Double(bytes) / 1_000_000
        return mb > 1 ? String(format: "%.1f MB", mb) : "\(bytes) bytes"
    }
}

// MARK: - Library View (جميل مع إجراءات حقيقية)
struct LibraryView: View {
    @EnvironmentObject var store: AppStore
    @State var tab = 0
    @State var showSigner = false
    @State var selectedApp: AppItem?

    var downloadedApps: [AppItem] { store.apps.filter { $0.isDownloaded } }
    var signedApps: [AppItem] { store.apps.filter { $0.isInstalled } }

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(spacing: 0) {
                    Picker("", selection: $tab) {
                        Text("Downloaded Apps").tag(0)
                        Text("Installed").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.top, 8)

                    let apps = tab == 0 ? downloadedApps : signedApps
                    if apps.isEmpty {
                        Spacer()
                        VStack(spacing: 10) {
                            Image(systemName: "tray")
                                .font(.system(size: 44))
                                .foregroundColor(.gray)
                            Text(tab == 0 ? "No Downloaded Apps" : "No Installed Apps")
                                .foregroundColor(.gray)
                        }
                        Spacer()
                    } else {
                        List {
                            Section(header: HStack {
                                Text(tab == 0 ? "Downloaded Apps" : "Installed Apps")
                                    .foregroundColor(.white).font(.headline).bold()
                                Spacer()
                                Text("\(apps.count)")
                                    .foregroundColor(.white).font(.caption)
                                    .padding(6)
                                    .background(Color.gray.opacity(0.4))
                                    .clipShape(Circle())
                            }) {
                                ForEach(apps) { app in
                                    Button(action: {
                                        selectedApp = app
                                        showSigner = true
                                    }) {
                                        HStack(spacing: 14) {
                                            RoundedRectangle(cornerRadius: 12)
                                                .fill(Color.blue.opacity(0.2))
                                                .frame(width: 52, height: 52)
                                                .overlay(
                                                    Image(systemName: "app.fill")
                                                        .foregroundColor(.blue)
                                                        .font(.title2)
                                                )
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(app.name)
                                                    .foregroundColor(.white).font(.body)
                                                Text("\(app.version) • \(app.bundleID)")
                                                    .foregroundColor(.gray).font(.caption)
                                            }
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .foregroundColor(.gray).font(.caption)
                                        }
                                        .padding(.vertical, 4)
                                    }
                                    .listRowBackground(Color(white: 0.1))
                                }
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                    }
                }
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    EditButton().foregroundColor(.blue)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showSigner = true }) {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showSigner) {
                SignerSheet(app: selectedApp)
                    .environmentObject(store)
            }
        }
    }
}

// MARK: - Signer Sheet (واجهة توقيع جميلة)
struct SignerSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    var app: AppItem?

    @State private var ipaURL: URL?
    @State private var p12URL: URL?
    @State private var provisionURL: URL?
    @State private var p12Password = ""
    @State private var bundleID = ""
    @State private var appVersion = ""
    @State private var appName = ""
    @State private var isSigning = false
    @State private var statusMessage = "اختر الملفات للبدء"
    @State private var resultSuccess = false
    @State private var pickingType: SignerSheet.PickType? = nil

    enum PickType: Identifiable {
        case ipa, p12, provision
        var id: Int { switch self { case .ipa: 0; case .p12: 1; case .provision: 2 } }
    }

    var allSelected: Bool { ipaURL != nil && p12URL != nil && provisionURL != nil }

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 20) {
                        VStack(spacing: 12) {
                            FilePickerRow(icon: "archivebox.fill", title: "IPA File", subtitle: ipaURL?.lastPathComponent ?? "اختر ملف .ipa", color: .blue, isSelected: ipaURL != nil) { pickingType = .ipa }
                            FilePickerRow(icon: "lock.shield.fill", title: "P12 Certificate", subtitle: p12URL?.lastPathComponent ?? "اختر ملف .p12", color: .purple, isSelected: p12URL != nil) { pickingType = .p12 }
                            FilePickerRow(icon: "doc.badge.gearshape.fill", title: "Provision Profile", subtitle: provisionURL?.lastPathComponent ?? "اختر ملف .mobileprovision", color: .cyan, isSelected: provisionURL != nil) { pickingType = .provision }
                        }

                        VStack(spacing: 0) {
                            Group {
                                inputRow(title: "App Name", placeholder: "اسم التطبيق", text: $appName)
                                Divider().background(Color.gray.opacity(0.3))
                                inputRow(title: "Bundle ID", placeholder: "com.example.app", text: $bundleID)
                                Divider().background(Color.gray.opacity(0.3))
                                inputRow(title: "Version", placeholder: "1.0", text: $appVersion)
                                Divider().background(Color.gray.opacity(0.3))
                                inputRow(title: "P12 Password", placeholder: "كلمة مرور الشهادة", text: $p12Password, isSecure: true)
                            }
                        }
                        .background(Color(white: 0.1))
                        .cornerRadius(12)

                        Button(action: startSigning) {
                            HStack(spacing: 12) {
                                if isSigning { ProgressView() }
                                else { Image(systemName: "checkmark.seal.fill") }
                                Text(isSigning ? "جاري التوقيع..." : "توقيع IPA")
                                    .font(.system(size: 17, weight: .bold))
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(allSelected && !isSigning ? Color.blue : Color.gray.opacity(0.4))
                            .cornerRadius(14)
                        }
                        .disabled(!allSelected || isSigning)

                        if !statusMessage.isEmpty {
                            HStack(spacing: 8) {
                                Image(systemName: resultSuccess ? "checkmark.circle.fill" : "info.circle.fill")
                                    .foregroundColor(resultSuccess ? .green : .gray)
                                Text(statusMessage)
                                    .font(.footnote)
                                    .foregroundColor(resultSuccess ? .green : .gray)
                            }
                            .padding(12)
                            .background(Color(white: 0.1))
                            .cornerRadius(10)
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("Sign IPA")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("إلغاء") { dismiss() }
                }
            }
            .sheet(item: $pickingType) { type in
                DocumentPickerView(type: type) { url in
                    switch type {
                    case .ipa:
                        ipaURL = url
                        if appName.isEmpty { appName = url.deletingPathExtension().lastPathComponent }
                    case .p12: p12URL = url
                    case .provision: provisionURL = url
                    }
                    pickingType = nil
                }
            }
        }
    }

    @ViewBuilder
    func inputRow(title: String, placeholder: String, text: Binding<String>, isSecure: Bool = false) -> some View {
        HStack {
            Text(title).foregroundColor(.white).frame(width: 110, alignment: .leading)
            if isSecure { SecureField(placeholder, text: text).foregroundColor(.gray) }
            else { TextField(placeholder, text: text).foregroundColor(.gray) }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    func startSigning() {
        guard let ipaURL = ipaURL, let p12URL = p12URL, let provURL = provisionURL else { return }
        isSigning = true
        resultSuccess = false
        statusMessage = "جارٍ إرسال الطلب..."

        let p12Base64 = (try? Data(contentsOf: p12URL))?.base64EncodedString() ?? ""
        let provBase64 = (try? Data(contentsOf: provURL))?.base64EncodedString() ?? ""

        let name = appName.isEmpty ? ipaURL.deletingPathExtension().lastPathComponent : appName
        let bundle = bundleID.isEmpty ? "com.imported.\(UUID().uuidString.prefix(8))" : bundleID
        let version = appVersion.isEmpty ? "1.0" : appVersion

        let appItem = AppItem(name: name, version: version, bundleID: bundle,
                              ipaURL: "file://\(ipaURL.path)",
                              localPath: ipaURL.path, isDownloaded: true)

        store.triggerRemoteSign(app: appItem, p12Base64: p12Base64, provisionBase64: provBase64, password: p12Password) { success, msg in
            isSigning = false
            resultSuccess = success
            statusMessage = msg
            if success {
                let signed = AppItem(name: name, version: version, bundleID: bundle,
                                     ipaURL: ipaURL.absoluteString,
                                     localPath: ipaURL.path, isDownloaded: true, isInstalled: true,
                                     signedDate: Date())
                store.apps.append(signed)
                store.saveAll()
            }
        }
    }
}

// MARK: - DocumentPickerView (مخصص لـ SignerSheet)
struct DocumentPickerView: UIViewControllerRepresentable {
    let type: SignerSheet.PickType
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types: [UTType]
        switch type {
        case .ipa:       types = [UTType(filenameExtension: "ipa") ?? .data]
        case .p12:       types = [UTType(filenameExtension: "p12") ?? .data]
        case .provision: types = [UTType(filenameExtension: "mobileprovision") ?? .data]
        }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            _ = url.startAccessingSecurityScopedResource()
            onPick(url)
        }
    }
}

// MARK: - File Picker Row (تصميم جميل)
struct FilePickerRow: View {
    let icon: String; let title: String; let subtitle: String
    let color: Color; let isSelected: Bool; let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                ZStack {
                    Circle().fill(color.opacity(0.2)).frame(width: 48, height: 48)
                    Image(systemName: icon).font(.system(size: 20)).foregroundColor(color)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
                    Text(subtitle).font(.system(size: 12)).foregroundColor(.gray).lineLimit(1)
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "chevron.right")
                    .foregroundColor(isSelected ? .green : .gray)
            }
            .padding(14)
            .background(Color(white: 0.1))
            .cornerRadius(14)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(isSelected ? color.opacity(0.5) : Color.clear, lineWidth: 1))
        }
    }
}

// MARK: - App Store View (مع Fetch حقيقي)
struct AppStoreView: View {
    @EnvironmentObject var store: AppStore
    @State var showSources = false
    @State var searchText = ""

    var filteredApps: [AppItem] {
        if searchText.isEmpty { return store.apps }
        return store.apps.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                List {
                    Section(header: Text("\(filteredApps.count) Apps").foregroundColor(.gray)) {
                        ForEach(filteredApps) { app in
                            HStack(spacing: 14) {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.blue.opacity(0.15))
                                    .frame(width: 52, height: 52)
                                    .overlay(Image(systemName: "app.fill").foregroundColor(.blue).font(.title3))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(app.name).foregroundColor(.white)
                                    Text("\(app.version) • \(app.bundleID)").foregroundColor(.gray).font(.caption)
                                }
                                Spacer()
                                if app.isDownloaded {
                                    Button("Install") { store.install(app: app) }
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 18).padding(.vertical, 7)
                                        .background(Color.blue.opacity(0.3))
                                        .clipShape(Capsule())
                                } else {
                                    Button("Get") { store.download(app: app) }
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 18).padding(.vertical, 7)
                                        .background(Color.blue.opacity(0.3))
                                        .clipShape(Capsule())
                                }
                            }
                            .padding(.vertical, 4)
                            .listRowBackground(Color(white: 0.08))
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("App Store")
            .searchable(text: $searchText, prompt: "Search")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Sources") { showSources = true }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {}) { Image(systemName: "arrow.clockwise") }
                }
            }
            .sheet(isPresented: $showSources) { SourcesView().environmentObject(store) }
        }
    }
}

// MARK: - Sources View (مع Fetch و Alert)
struct SourcesView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State var showAddSource = false
    @State var newSourceURL = ""
    @State var alertMessage = ""
    @State var showAlert = false

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                if store.sources.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "globe").font(.system(size: 44)).foregroundColor(.gray)
                        Text("No Sources").foregroundColor(.gray)
                        Button("Add Source") { showAddSource = true }.foregroundColor(.blue)
                    }
                } else {
                    List {
                        Section(header: HStack {
                            Text("Repositories").foregroundColor(.white).font(.headline).bold()
                            Spacer()
                            Text("\(store.sources.count)").foregroundColor(.white).font(.caption)
                                .padding(6).background(Color.gray.opacity(0.4)).clipShape(Circle())
                        }) {
                            ForEach(store.sources) { src in
                                HStack(spacing: 14) {
                                    RoundedRectangle(cornerRadius: 10).fill(Color.blue.opacity(0.15))
                                        .frame(width: 44, height: 44)
                                        .overlay(Image(systemName: "globe").foregroundColor(.blue))
                                    VStack(alignment: .leading) {
                                        Text(src.name).foregroundColor(.white)
                                        Text(src.url).foregroundColor(.gray).font(.caption).lineLimit(1)
                                    }
                                    Spacer()
                                    Button("Fetch") {
                                        store.fetch(source: src) { result in
                                            switch result {
                                            case .success(let count): alertMessage = "Added \(count) apps."
                                            case .failure(let error): alertMessage = "Error: \(error.localizedDescription)"
                                            }
                                            showAlert = true
                                        }
                                    }
                                    .font(.caption.bold()).foregroundColor(.white)
                                    .padding(.horizontal, 12).padding(.vertical, 4)
                                    .background(Color.blue).clipShape(Capsule())
                                }
                                .listRowBackground(Color(white: 0.1))
                            }
                            .onDelete { store.sources.remove(atOffsets: $0) }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Sources")
            .alert("Fetch Result", isPresented: $showAlert) {
                Button("OK") { }
            } message: {
                Text(alertMessage)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showAddSource = true }) { Image(systemName: "plus") }
                }
            }
            .alert("Add Source", isPresented: $showAddSource) {
                TextField("https://...", text: $newSourceURL)
                Button("Add") {
                    if !newSourceURL.isEmpty {
                        store.sources.append(Source(name: newSourceURL, url: newSourceURL))
                        newSourceURL = ""
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}

// MARK: - Downloads View (تصميم جميل مع Download حقيقي)
struct DownloadsView: View {
    @EnvironmentObject var store: AppStore
    @State var showAddDownload = false
    @State var downloadURL = ""

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                if store.downloads.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 52)).foregroundColor(.gray)
                        Text("No Downloads").foregroundColor(.gray)
                    }
                } else {
                    List {
                        Section(header: HStack {
                            Text("Downloaded").foregroundColor(.white).font(.headline).bold()
                            Spacer()
                            Text("\(store.downloads.count)").foregroundColor(.white).font(.caption)
                                .padding(6).background(Color.gray.opacity(0.4)).clipShape(Circle())
                        }) {
                            ForEach(store.downloads) { item in
                                HStack(spacing: 14) {
                                    Image(systemName: "doc.zipper")
                                        .font(.title2).foregroundColor(.blue)
                                        .frame(width: 44, height: 44)
                                        .background(Color.blue.opacity(0.1)).cornerRadius(10)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.name).foregroundColor(.white).lineLimit(1)
                                        Text(item.size).foregroundColor(.gray).font(.caption)
                                        if item.progress < 1.0 {
                                            ProgressView(value: item.progress).tint(.blue)
                                        }
                                    }
                                }
                                .padding(.vertical, 4)
                                .listRowBackground(Color(white: 0.1))
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Downloads")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showAddDownload = true }) { Image(systemName: "plus") }
                }
            }
            .alert("Download IPA", isPresented: $showAddDownload) {
                TextField("https://example.com/app.ipa", text: $downloadURL)
                Button("Download") {
                    guard let url = URL(string: downloadURL), !downloadURL.isEmpty else { return }
                    let name = url.lastPathComponent
                    store.downloads.append(DownloadItem(name: name, size: "0 MB", ipaURL: downloadURL, progress: 0))
                    // Simulate download (real app would use URLSession)
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}

// MARK: - Settings View (بدون إعدادات توكن)
struct SettingsView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                List {
                    Section {
                        VStack(spacing: 12) {
                            Image(systemName: "signature")
                                .font(.system(size: 44)).foregroundColor(.blue)
                            Text("MySigner").font(.title2.bold()).foregroundColor(.white)
                            Text("IPA Signing Tool v1.0")
                                .foregroundColor(.gray).font(.caption)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .listRowBackground(Color(white: 0.1))
                    }

                    Section(header: Text("Features").foregroundColor(.white).font(.headline).bold()) {
                        NavigationLink(destination: CertificatesView().environmentObject(store)) {
                            SettingsRowContent(icon: "signature", iconColor: .blue, title: "Certificates")
                        }.listRowBackground(Color(white: 0.1))

                        NavigationLink(destination: Text("Signing Options")) {
                            SettingsRowContent(icon: "gearshape.fill", iconColor: .blue, title: "Signing Options")
                        }.listRowBackground(Color(white: 0.1))
                    }

                    Section(header: Text("Misc").foregroundColor(.white).font(.headline).bold()) {
                        Button(action: {
                            store.apps.removeAll(); store.downloads.removeAll(); store.sources.removeAll(); store.saveAll()
                        }) {
                            SettingsRowContent(icon: "trash.fill", iconColor: .red, title: "Reset All Data")
                        }.listRowBackground(Color(white: 0.1))
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Settings")
        }
    }
}

struct CertificatesView: View {
    @EnvironmentObject var store: AppStore
    var body: some View { Text("Certificates") }
}

struct SettingsRowContent: View {
    let icon: String; let iconColor: Color; let title: String
    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(iconColor.opacity(0.2)).frame(width: 32, height: 32)
                Image(systemName: icon).foregroundColor(iconColor).font(.system(size: 15))
            }
            Text(title).foregroundColor(.white)
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View { ContentView() }
}