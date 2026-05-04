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

struct Certificate: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var teamID: String = ""
    var expiryDate: Date = Date().addingTimeInterval(90*24*60*60)
    var p12Path: String
    var mobileProvisionPath: String?
    var isValid: Bool { expiryDate > Date() }
    var daysLeft: Int {
        Calendar.current.dateComponents([.day], from: Date(), to: expiryDate).day ?? 0
    }
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
    private let certsDir: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("MySignerCerts")
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
        certificates = load(Certificate.self, from: "certificates.json")
    }

    func saveAll() {
        save(apps, to: "apps.json")
        save(downloads, to: "downloads.json")
        save(sources, to: "sources.json")
        save(certificates, to: "certificates.json")
    }

    // MARK: - Certificate Management
    func addCertificate(name: String, p12URL: URL, provisionURL: URL?) {
        let p12Dest = certsDir.appendingPathComponent(UUID().uuidString + ".p12")
        try? FileManager.default.copyItem(at: p12URL, to: p12Dest)

        var provDest: String? = nil
        if let provURL = provisionURL {
            let dest = certsDir.appendingPathComponent(UUID().uuidString + ".mobileprovision")
            try? FileManager.default.copyItem(at: provURL, to: dest)
            provDest = dest.path
        }

        let cert = Certificate(name: name, p12Path: p12Dest.path, mobileProvisionPath: provDest)
        certificates.append(cert)
        saveAll()
    }

    func deleteCertificate(_ cert: Certificate) {
        try? FileManager.default.removeItem(atPath: cert.p12Path)
        if let provPath = cert.mobileProvisionPath {
            try? FileManager.default.removeItem(atPath: provPath)
        }
        certificates.removeAll { $0.id == cert.id }
        saveAll()
    }

    // MARK: - Fetch Source (JSON array like KSign/ESign)
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

    // MARK: - Download IPA
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

    // MARK: - Install via local server
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
        if let url = URL(string: urlString) { UIApplication.shared.open(url) }
    }

    // MARK: - Remote Signing (internal GitHub token)
    private let githubToken = "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" // <-- ضع توكنك الحقيقي هنا
    func triggerRemoteSign(app: AppItem, certificate: Certificate, p12Password: String, completion: @escaping (Bool, String) -> Void) {
        guard let p12Data = try? Data(contentsOf: URL(fileURLWithPath: certificate.p12Path)),
              let provData = certificate.mobileProvisionPath.flatMap({ try? Data(contentsOf: URL(fileURLWithPath: $0)) }) else {
            completion(false, "Failed to read certificate files")
            return
        }
        let p12Base64 = p12Data.base64EncodedString()
        let provBase64 = provData.base64EncodedString()

        let owner = "Al-Zng"
        let repo = "MySigner"
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
                "mobileprovision_base64": provBase64,
                "password": p12Password,
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
                if let error = error { completion(false, error.localizedDescription); return }
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

// MARK: - Document Pickers
struct GenericDocumentPicker: UIViewControllerRepresentable {
    var types: [UTType]
    var onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
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

// MARK: - Files View (Import any file)
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
            .sheet(isPresented: $showImporter) {
                GenericDocumentPicker(types: [.item]) { url in
                    if !importedFiles.contains(url) {
                        importedFiles.append(url)
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

// MARK: - Library View
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
            }
        }
    }
}

// MARK: - Signer Sheet (اختيار شهادة محفوظة)
struct SignerSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    var app: AppItem?

    @State private var selectedCert: Certificate?
    @State private var p12Password = ""
    @State private var isSigning = false
    @State private var statusMessage = "اختر شهادة وأدخل كلمة المرور"
    @State private var resultSuccess = false

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 20) {
                        if let app = app {
                            HStack(spacing: 14) {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.blue.opacity(0.2))
                                    .frame(width: 52, height: 52)
                                    .overlay(Image(systemName: "app.fill").foregroundColor(.blue))
                                VStack(alignment: .leading) {
                                    Text(app.name).foregroundColor(.white)
                                    Text("\(app.version) • \(app.bundleID)").foregroundColor(.gray)
                                }
                                Spacer()
                            }
                            .padding()
                            .background(Color(white: 0.1))
                            .cornerRadius(14)
                        }

                        if store.certificates.isEmpty {
                            Text("لا توجد شهادات محفوظة. أضف واحدة من الإعدادات.")
                                .foregroundColor(.gray)
                                .padding()
                        } else {
                            Picker("الشهادة", selection: $selectedCert) {
                                Text("اختر شهادة").tag(nil as Certificate?)
                                ForEach(store.certificates, id: \.id) { cert in
                                    Text(cert.name).tag(cert as Certificate?)
                                }
                            }
                            .pickerStyle(.menu)
                            .foregroundColor(.white)
                            .padding()
                            .background(Color(white: 0.1))
                            .cornerRadius(12)
                        }

                        SecureField("كلمة مرور الشهادة", text: $p12Password)
                            .padding()
                            .background(Color(white: 0.1))
                            .cornerRadius(12)
                            .foregroundColor(.gray)

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
                            .background(selectedCert != nil && !p12Password.isEmpty && !isSigning ? Color.blue : Color.gray.opacity(0.4))
                            .cornerRadius(14)
                        }
                        .disabled(selectedCert == nil || p12Password.isEmpty || isSigning)

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
        }
    }

    func startSigning() {
        guard let app = app, let cert = selectedCert else { return }
        isSigning = true
        resultSuccess = false
        statusMessage = "جاري إرسال الطلب..."

        store.triggerRemoteSign(app: app, certificate: cert, p12Password: p12Password) { success, msg in
            isSigning = false
            resultSuccess = success
            statusMessage = msg
            if success, let idx = store.apps.firstIndex(where: { $0.id == app.id }) {
                store.apps[idx].isInstalled = true
                store.apps[idx].signedDate = Date()
                store.saveAll()
            }
        }
    }
}

// MARK: - App Store View (مع Fetch حقيقي من المصادر)
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
    @State var newSourceName = ""
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
                            .onDelete { store.sources.remove(atOffsets: $0); store.saveAll() }
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
            .sheet(isPresented: $showAddSource) {
                NavigationView {
                    Form {
                        TextField("Name", text: $newSourceName)
                        TextField("URL (apps.json)", text: $newSourceURL)
                            .keyboardType(.URL)
                        Button("Add") {
                            if !newSourceName.isEmpty && !newSourceURL.isEmpty {
                                store.sources.append(Source(name: newSourceName, url: newSourceURL))
                                store.saveAll()
                                newSourceName = ""
                                newSourceURL = ""
                                showAddSource = false
                            }
                        }
                        .disabled(newSourceName.isEmpty || newSourceURL.isEmpty)
                    }
                    .navigationTitle("Add Source")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showAddSource = false } }
                    }
                }
                .preferredColorScheme(.dark)
            }
        }
    }
}

// MARK: - Downloads View
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
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}

// MARK: - Settings View (الشهادات الحقيقية)
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

                    Section(header: Text("Certificates").foregroundColor(.white).font(.headline).bold()) {
                        NavigationLink(destination: CertificatesView()) {
                            HStack(spacing: 14) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.2)).frame(width: 32, height: 32)
                                    Image(systemName: "signature").foregroundColor(.blue).font(.system(size: 15))
                                }
                                Text("Manage Certificates").foregroundColor(.white)
                                Spacer()
                                Text("\(store.certificates.count)").foregroundColor(.gray)
                            }
                        }.listRowBackground(Color(white: 0.1))

                        NavigationLink(destination: Text("Signing Options")) {
                            SettingsRowContent(icon: "gearshape.fill", iconColor: .blue, title: "Signing Options")
                        }.listRowBackground(Color(white: 0.1))
                    }

                    Section(header: Text("Misc").foregroundColor(.white).font(.headline).bold()) {
                        Button(action: {
                            store.apps.removeAll()
                            store.downloads.removeAll()
                            store.sources.removeAll()
                            store.certificates.removeAll()
                            store.saveAll()
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
    @State private var showAddCert = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if store.certificates.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "signature").font(.system(size: 44)).foregroundColor(.gray)
                    Text("No Certificates").foregroundColor(.gray)
                    Button("Add Certificate") { showAddCert = true }
                        .foregroundColor(.blue)
                }
            } else {
                List {
                    ForEach(store.certificates) { cert in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(cert.name).foregroundColor(.white).font(.body.bold())
                            Text("Team: \(cert.teamID.isEmpty ? "–" : cert.teamID)").foregroundColor(.gray).font(.caption)
                            HStack(spacing: 12) {
                                HStack(spacing: 6) {
                                    Image(systemName: cert.isValid ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .foregroundColor(cert.isValid ? .green : .red)
                                    Text(cert.isValid ? "Valid" : "Expired").foregroundColor(.white).font(.subheadline.bold())
                                }
                                .frame(maxWidth: .infinity).padding(.vertical, 10)
                                .background(cert.isValid ? Color.green.opacity(0.15) : Color.red.opacity(0.15))
                                .cornerRadius(10)

                                HStack(spacing: 6) {
                                    Image(systemName: "clock.fill").foregroundColor(.yellow)
                                    Text("\(cert.daysLeft) days").foregroundColor(.white).font(.subheadline.bold())
                                }
                                .frame(maxWidth: .infinity).padding(.vertical, 10)
                                .background(Color.yellow.opacity(0.15)).cornerRadius(10)
                            }
                        }
                        .padding(16)
                        .background(Color(white: 0.1))
                        .cornerRadius(14)
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.blue.opacity(0.5), lineWidth: 1.5))
                        .listRowBackground(Color.clear)
                    }
                    .onDelete { indexSet in
                        indexSet.forEach { store.deleteCertificate(store.certificates[$0]) }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Certificates")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: { showAddCert = true }) { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showAddCert) {
            AddCertificateView()
        }
    }
}

struct AddCertificateView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State private var certName = ""
    @State private var p12URL: URL?
    @State private var provURL: URL?
    @State private var pickingType: CertPickType? = nil

    enum CertPickType: Identifiable { case p12, provision; var id: Int { hashValue } }

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(spacing: 20) {
                    TextField("Certificate Name", text: $certName)
                        .padding()
                        .background(Color(white: 0.1))
                        .cornerRadius(12)
                        .foregroundColor(.white)

                    FilePickerRow(icon: "lock.shield.fill", title: "P12 File", subtitle: p12URL?.lastPathComponent ?? "اختر ملف .p12", color: .purple, isSelected: p12URL != nil) {
                        pickingType = .p12
                    }

                    FilePickerRow(icon: "doc.badge.gearshape.fill", title: "Provision Profile", subtitle: provURL?.lastPathComponent ?? "اختر ملف .mobileprovision", color: .cyan, isSelected: provURL != nil) {
                        pickingType = .provision
                    }

                    Button("Add") {
                        guard let p12 = p12URL else { return }
                        let name = certName.isEmpty ? p12.deletingPathExtension().lastPathComponent : certName
                        store.addCertificate(name: name, p12URL: p12, provisionURL: provURL)
                        dismiss()
                    }
                    .disabled(p12URL == nil)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(p12URL != nil ? Color.blue : Color.gray.opacity(0.4))
                    .cornerRadius(12)

                    Spacer()
                }
                .padding()
            }
            .navigationTitle("Add Certificate")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .sheet(item: $pickingType) { type in
                GenericDocumentPicker(types: type == .p12 ? [UTType(filenameExtension: "p12")!] : [UTType(filenameExtension: "mobileprovision")!]) { url in
                    if type == .p12 { p12URL = url } else { provURL = url }
                    pickingType = nil
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Reusable Components
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