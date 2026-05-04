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
    var developerName: String?
    var appDescription: String?
    var size: String?

    enum CodingKeys: String, CodingKey {
        case name, version, iconURL, localPath, isDownloaded, isInstalled, signedDate
        case bundleID = "bundleIdentifier"
        case ipaURL = "downloadURL"
        case developerName, appDescription, size
    }
}

struct DownloadItem: Identifiable, Codable {
    var id = UUID()
    var name: String
    var size: String = ""
    var ipaURL: String
    var progress: Double = 0.0
    var bytesReceived: Int64 = 0
    var totalBytes: Int64 = 0
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
    @Published var activeDownloads: [DownloadItem] = []
    @Published var sources: [Source] = []

    private var downloadObservations: [UUID: NSKeyValueObservation] = [:]
    private var downloadTasks: [UUID: URLSessionDownloadTask] = [:]

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
        sources = load(Source.self, from: "sources.json")
        certificates = load(Certificate.self, from: "certificates.json")
    }

    func saveAll() {
        save(apps, to: "apps.json")
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

    // MARK: - Fetch Source
    struct RemoteAppItem: Codable {
        let name: String
        let version: String
        let bundleIdentifier: String
        let downloadURL: String
        let iconURL: String?
        let developerName: String?
        let localizedDescription: String?
        let size: Int?
    }

    struct RemoteSourceRoot: Codable {
        let apps: [RemoteAppItem]
    }

    func fetch(source: Source, completion: @escaping (Result<Int, Error>) -> Void) {
        guard let url = URL(string: source.url) else {
            completion(.failure(URLError(.badURL)))
            return
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error { completion(.failure(error)); return }
                guard let data = data else { completion(.failure(URLError(.cannotParseResponse))); return }

                var fetched: [AppItem] = []

                if let root = try? JSONDecoder().decode(RemoteSourceRoot.self, from: data) {
                    fetched = root.apps.map {
                        AppItem(
                            name: $0.name, version: $0.version,
                            bundleID: $0.bundleIdentifier, ipaURL: $0.downloadURL,
                            iconURL: $0.iconURL,
                            developerName: $0.developerName,
                            appDescription: $0.localizedDescription,
                            size: $0.size.map { s in
                                let mb = Double(s) / 1_000_000
                                return String(format: "%.1f MB", mb)
                            }
                        )
                    }
                } else if let items = try? JSONDecoder().decode([RemoteAppItem].self, from: data) {
                    fetched = items.map {
                        AppItem(
                            name: $0.name, version: $0.version,
                            bundleID: $0.bundleIdentifier, ipaURL: $0.downloadURL,
                            iconURL: $0.iconURL,
                            developerName: $0.developerName,
                            appDescription: $0.localizedDescription,
                            size: $0.size.map { s in
                                let mb = Double(s) / 1_000_000
                                return String(format: "%.1f MB", mb)
                            }
                        )
                    }
                } else {
                    completion(.failure(URLError(.cannotParseResponse)))
                    return
                }

                let existingURLs = Set(self.apps.map { $0.ipaURL })
                let newApps = fetched.filter { !existingURLs.contains($0.ipaURL) }
                self.apps.append(contentsOf: newApps)
                self.saveAll()
                completion(.success(newApps.count))
            }
        }.resume()
    }

    // MARK: - Download IPA
    func isDownloading(app: AppItem) -> Bool {
        activeDownloads.contains { $0.ipaURL == app.ipaURL }
    }

    func downloadProgress(for app: AppItem) -> Double? {
        activeDownloads.first { $0.ipaURL == app.ipaURL }?.progress
    }

    func download(app: AppItem) {
        guard let url = URL(string: app.ipaURL) else { return }
        guard !isDownloading(app: app) else { return }

        let item = DownloadItem(name: app.name, ipaURL: app.ipaURL)
        activeDownloads.append(item)

        let task = URLSession.shared.downloadTask(with: url) { [weak self] localURL, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.downloadObservations.removeValue(forKey: item.id)
                self.downloadTasks.removeValue(forKey: item.id)
                self.activeDownloads.removeAll { $0.id == item.id }

                guard let localURL = localURL, error == nil else { return }

                let filename = "\(app.bundleID)_\(UUID().uuidString.prefix(8)).ipa"
                let dest = self.appsDir.appendingPathComponent(filename)
                do {
                    try FileManager.default.moveItem(at: localURL, to: dest)
                    if let idx = self.apps.firstIndex(where: { $0.ipaURL == app.ipaURL }) {
                        self.apps[idx].localPath = dest.path
                        self.apps[idx].isDownloaded = true
                        self.saveAll()
                    }
                } catch { print("Move error: \(error)") }
            }
        }

        let observation = task.progress.observe(\.fractionCompleted) { [weak self] prog, _ in
            DispatchQueue.main.async {
                if let idx = self?.activeDownloads.firstIndex(where: { $0.id == item.id }) {
                    self?.activeDownloads[idx].progress = prog.fractionCompleted
                    self?.activeDownloads[idx].bytesReceived = prog.completedUnitCount
                    self?.activeDownloads[idx].totalBytes = prog.totalUnitCount
                }
            }
        }

        downloadObservations[item.id] = observation
        downloadTasks[item.id] = task
        task.resume()
    }

    // MARK: - Install via local server
    func install(app: AppItem) {
        guard let localPath = app.localPath, FileManager.default.fileExists(atPath: localPath) else { return }
        if !server.isRunning { server.start() }
        let manifest: [String: Any] = [
            "items": [[
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
            ]]
        ]
        let plistData = try? PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0)
        server.manifestData = plistData
        server.ipaFilePath = localPath

        let urlString = "itms-services://?action=download-manifest&url=http://localhost:\(server.port)/manifest.plist"
        if let url = URL(string: urlString) { UIApplication.shared.open(url) }
    }

    // MARK: - Remote Signing
    private let githubToken = "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"
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
            completion(false, "Bad URL"); return
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
                    completion(true, "Signing started successfully.")
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

// MARK: - SwiftUI Native FilePicker
struct FilePicker: View {
    @Binding var isPresented: Bool
    var onPick: (URL) -> Void

    var body: some View {
        Color.clear
            .fileImporter(
                isPresented: $isPresented,
                allowedContentTypes: [.item, .data, .content],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        let accessing = url.startAccessingSecurityScopedResource()
                        let tempDest = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
                        var resultURL: URL
                        do {
                            if FileManager.default.fileExists(atPath: tempDest.path) {
                                try FileManager.default.removeItem(at: tempDest)
                            }
                            try FileManager.default.copyItem(at: url, to: tempDest)
                            resultURL = tempDest
                        } catch {
                            print("File picker copy error: \(error)")
                            resultURL = url
                        }
                        if accessing { url.stopAccessingSecurityScopedResource() }
                        
                        DispatchQueue.main.async {
                            onPick(resultURL)
                        }
                    }
                case .failure(let error):
                    print("File picker error: \(error.localizedDescription)")
                }
            }
    }
}

// MARK: - App Icon View
struct AppIconView: View {
    let iconURL: String?
    let size: CGFloat

    var body: some View {
        Group {
            if let iconURL = iconURL, let url = URL(string: iconURL) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    case .failure(_):
                        defaultIcon
                    case .empty:
                        Color(white: 0.15)
                            .overlay(ProgressView().tint(.gray).scaleEffect(0.6))
                    @unknown default:
                        defaultIcon
                    }
                }
            } else {
                defaultIcon
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }

    var defaultIcon: some View {
        RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
            .fill(LinearGradient(colors: [Color(white: 0.18), Color(white: 0.12)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(
                Image(systemName: "app.fill")
                    .font(.system(size: size * 0.4))
                    .foregroundColor(Color(white: 0.4))
            )
    }
}

// MARK: - Main ContentView
struct ContentView: View {
    @StateObject private var store = AppStore()
    @State private var selectedTab = 2

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

// MARK: - Files View
struct FilesView: View {
    @EnvironmentObject var store: AppStore
    @State private var showImporter = false
    @State private var importedFiles: [URL] = []
    @State private var selectedFileForAction: URL?
    @State private var showFileAction = false

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                if importedFiles.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 56))
                            .foregroundStyle(.blue.opacity(0.6))
                        Text("No Files")
                            .font(.title3.bold())
                            .foregroundColor(.white)
                        Text("Import IPA or certificate files")
                            .foregroundColor(.gray)
                            .font(.subheadline)
                        Button(action: { showImporter = true }) {
                            Label("Import File", systemImage: "square.and.arrow.down")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 24).padding(.vertical, 12)
                                .background(Color.blue)
                                .clipShape(Capsule())
                        }
                        .padding(.top, 4)
                    }
                } else {
                    List {
                        ForEach(importedFiles, id: \.self) { url in
                            Button(action: {
                                selectedFileForAction = url
                                showFileAction = true
                            }) {
                                HStack(spacing: 14) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(fileColor(for: url).opacity(0.15))
                                            .frame(width: 44, height: 44)
                                        Image(systemName: fileIcon(for: url))
                                            .foregroundColor(fileColor(for: url))
                                            .font(.system(size: 20))
                                    }
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(url.lastPathComponent)
                                            .foregroundColor(.white)
                                            .font(.system(size: 15, weight: .medium))
                                            .lineLimit(1)
                                        Text(fileSize(url: url))
                                            .foregroundColor(.gray)
                                            .font(.caption)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .foregroundColor(Color(white: 0.35))
                                        .font(.caption)
                                }
                                .padding(.vertical, 4)
                            }
                            .listRowBackground(Color(white: 0.08))
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
            .background(
                FilePicker(isPresented: $showImporter) { url in
                    let destURL = store.appsDir.appendingPathComponent(url.lastPathComponent)
                    do {
                        if FileManager.default.fileExists(atPath: destURL.path) {
                            try FileManager.default.removeItem(at: destURL)
                        }
                        try FileManager.default.copyItem(at: url, to: destURL)
                        DispatchQueue.main.async {
                            if !importedFiles.contains(destURL) {
                                importedFiles.append(destURL)
                            }
                        }
                    } catch {
                        print("File import error: \(error)")
                    }
                }
            )
            .confirmationDialog(selectedFileForAction?.lastPathComponent ?? "", isPresented: $showFileAction, titleVisibility: .visible) {
                if let url = selectedFileForAction {
                    if url.pathExtension.lowercased() == "ipa" {
                        Button("Import to Library") {
                            let app = AppItem(
                                name: url.deletingPathExtension().lastPathComponent,
                                version: "1.0",
                                bundleID: "com.imported.\(url.deletingPathExtension().lastPathComponent.lowercased().replacingOccurrences(of: " ", with: "."))",
                                ipaURL: "",
                                localPath: url.path,
                                isDownloaded: true
                            )
                            store.apps.append(app)
                            store.saveAll()
                        }
                    }
                    Button("Delete", role: .destructive) {
                        importedFiles.removeAll { $0 == url }
                        try? FileManager.default.removeItem(at: url)
                    }
                }
                Button("Cancel", role: .cancel) {}
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

    func fileColor(for url: URL) -> Color {
        switch url.pathExtension.lowercased() {
        case "ipa": return .blue
        case "p12": return .purple
        case "mobileprovision": return .cyan
        default: return .gray
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
                        Text("Signed Apps").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                    let apps = tab == 0 ? downloadedApps : signedApps
                    if apps.isEmpty {
                        Spacer()
                        VStack(spacing: 12) {
                            Image(systemName: tab == 0 ? "tray" : "checkmark.seal")
                                .font(.system(size: 48))
                                .foregroundStyle(.gray.opacity(0.5))
                            Text(tab == 0 ? "No Downloaded Apps" : "No Signed Apps")
                                .font(.title3.bold())
                                .foregroundColor(.white)
                            Text(tab == 0 ? "Download apps from the App Store tab" : "Sign an app to see it here")
                                .foregroundColor(.gray)
                                .font(.subheadline)
                                .multilineTextAlignment(.center)
                        }
                        .padding()
                        Spacer()
                    } else {
                        List {
                            Section(header: HStack {
                                Text(tab == 0 ? "Downloaded Apps" : "Signed Apps")
                                    .foregroundColor(.white).font(.headline).bold()
                                Spacer()
                                Text("\(apps.count)")
                                    .foregroundColor(.white).font(.caption2.bold())
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(Color(white: 0.25))
                                    .clipShape(Capsule())
                            }.padding(.bottom, 4)) {
                                ForEach(apps) { app in
                                    Button(action: {
                                        selectedApp = app
                                        showSigner = true
                                    }) {
                                        HStack(spacing: 14) {
                                            AppIconView(iconURL: app.iconURL, size: 52)
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(app.name)
                                                    .foregroundColor(.white)
                                                    .font(.system(size: 16, weight: .medium))
                                                Text("\(app.version) • \(app.bundleID)")
                                                    .foregroundColor(.gray)
                                                    .font(.caption)
                                                    .lineLimit(1)
                                            }
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .foregroundColor(Color(white: 0.35))
                                                .font(.caption)
                                        }
                                        .padding(.vertical, 4)
                                    }
                                    .listRowBackground(Color(white: 0.08))
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
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showSigner = true; selectedApp = nil }) {
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

// MARK: - Signer Sheet
struct SignerSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    var app: AppItem?

    @State private var selectedCert: Certificate?
    @State private var p12Password = ""
    @State private var isSigning = false
    @State private var statusMessage = ""
    @State private var resultSuccess = false

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        if let app = app {
                            HStack(spacing: 14) {
                                AppIconView(iconURL: app.iconURL, size: 56)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(app.name)
                                        .foregroundColor(.white)
                                        .font(.system(size: 17, weight: .semibold))
                                    Text(app.version)
                                        .foregroundColor(.gray)
                                        .font(.subheadline)
                                    Text(app.bundleID)
                                        .foregroundColor(Color(white: 0.4))
                                        .font(.caption)
                                        .lineLimit(1)
                                }
                                Spacer()
                            }
                            .padding(16)
                            .background(Color(white: 0.08))
                            .cornerRadius(16)
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Signing")
                                .font(.headline.bold())
                                .foregroundColor(.white)

                            if store.certificates.isEmpty {
                                HStack {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(.yellow)
                                    Text("No certificates. Add one in Settings.")
                                        .foregroundColor(.gray)
                                        .font(.subheadline)
                                }
                                .padding()
                                .frame(maxWidth: .infinity)
                                .background(Color(white: 0.08))
                                .cornerRadius(14)
                            } else {
                                ForEach(store.certificates) { cert in
                                    Button(action: { selectedCert = cert }) {
                                        HStack(spacing: 12) {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(cert.name)
                                                    .foregroundColor(.white)
                                                    .font(.system(size: 15, weight: .semibold))
                                                Text(cert.teamID.isEmpty ? "No Team ID" : cert.teamID)
                                                    .foregroundColor(.gray)
                                                    .font(.caption)
                                            }
                                            Spacer()
                                            HStack(spacing: 8) {
                                                Label(cert.isValid ? "Valid" : "Expired", systemImage: cert.isValid ? "checkmark.circle.fill" : "xmark.circle.fill")
                                                    .font(.caption.bold())
                                                    .foregroundColor(cert.isValid ? .green : .red)
                                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                                    .background((cert.isValid ? Color.green : Color.red).opacity(0.12))
                                                    .clipShape(Capsule())

                                                if selectedCert?.id == cert.id {
                                                    Image(systemName: "checkmark.circle.fill")
                                                        .foregroundColor(.blue)
                                                }
                                            }
                                        }
                                        .padding(14)
                                        .background(Color(white: 0.1))
                                        .cornerRadius(14)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 14)
                                                .stroke(selectedCert?.id == cert.id ? Color.blue : Color.clear, lineWidth: 1.5)
                                        )
                                    }
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Certificate Password")
                                .font(.headline.bold())
                                .foregroundColor(.white)
                            SecureField("Enter P12 password", text: $p12Password)
                                .padding(14)
                                .background(Color(white: 0.08))
                                .cornerRadius(12)
                                .foregroundColor(.white)
                        }

                        if !statusMessage.isEmpty {
                            HStack(spacing: 10) {
                                Image(systemName: resultSuccess ? "checkmark.circle.fill" : "info.circle.fill")
                                    .foregroundColor(resultSuccess ? .green : .orange)
                                Text(statusMessage)
                                    .font(.subheadline)
                                    .foregroundColor(resultSuccess ? .green : .orange)
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(white: 0.08))
                            .cornerRadius(12)
                        }
                    }
                    .padding(16)
                }

                VStack {
                    Spacer()
                    Button(action: startSigning) {
                        HStack(spacing: 10) {
                            if isSigning { ProgressView().tint(.white) }
                            else { Image(systemName: "checkmark.seal.fill") }
                            Text(isSigning ? "Signing…" : "Start Signing")
                                .font(.system(size: 17, weight: .bold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(canSign ? Color.blue : Color(white: 0.2))
                        .cornerRadius(16)
                    }
                    .disabled(!canSign)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .background(
                        LinearGradient(colors: [Color.black.opacity(0), Color.black], startPoint: .top, endPoint: .bottom)
                            .frame(height: 100)
                            .offset(y: -20),
                        alignment: .bottom
                    )
                }
            }
            .navigationTitle("Sign IPA")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    var canSign: Bool { selectedCert != nil && !p12Password.isEmpty && !isSigning && app != nil }

    func startSigning() {
        guard let app = app, let cert = selectedCert else { return }
        isSigning = true
        resultSuccess = false
        statusMessage = "Sending signing request…"

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

// MARK: - App Store View
struct AppStoreView: View {
    @EnvironmentObject var store: AppStore
    @State var showSources = false
    @State var searchText = ""
    @State var selectedApp: AppItem?

    var filteredApps: [AppItem] {
        if searchText.isEmpty { return store.apps }
        return store.apps.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.bundleID.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                if store.apps.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "square.stack.3d.up")
                            .font(.system(size: 56))
                            .foregroundStyle(.blue.opacity(0.5))
                        Text("No Apps")
                            .font(.title3.bold())
                            .foregroundColor(.white)
                        Text("Add a source to browse and download apps")
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                            .font(.subheadline)
                        Button(action: { showSources = true }) {
                            Label("Add Source", systemImage: "plus")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 24).padding(.vertical, 12)
                                .background(Color.blue)
                                .clipShape(Capsule())
                        }
                        .padding(.top, 4)
                    }
                    .padding()
                } else {
                    List {
                        if !store.activeDownloads.isEmpty {
                            Section(header: Text("Downloading").foregroundColor(.white).font(.headline).bold()) {
                                ForEach(store.activeDownloads) { item in
                                    ActiveDownloadRow(item: item)
                                        .listRowBackground(Color(white: 0.08))
                                }
                            }
                        }

                        Section(header: HStack {
                            Text("\(filteredApps.count) Apps")
                                .foregroundColor(.gray)
                                .font(.subheadline)
                            Spacer()
                        }) {
                            ForEach(filteredApps) { app in
                                Button(action: { selectedApp = app }) {
                                    AppStoreRow(app: app)
                                }
                                .listRowBackground(Color(white: 0.08))
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("App Store")
            .searchable(text: $searchText, prompt: "Search apps")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { showSources = true }) {
                        Label("Sources", systemImage: "list.bullet")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        for source in store.sources {
                            store.fetch(source: source) { _ in }
                        }
                    }) {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .sheet(isPresented: $showSources) {
                SourcesView().environmentObject(store)
            }
            .sheet(item: $selectedApp) { app in
                AppDetailView(app: app).environmentObject(store)
            }
        }
    }
}

// MARK: - App Store Row
struct AppStoreRow: View {
    @EnvironmentObject var store: AppStore
    let app: AppItem

    var body: some View {
        HStack(spacing: 14) {
            AppIconView(iconURL: app.iconURL, size: 56)

            VStack(alignment: .leading, spacing: 3) {
                Text(app.name)
                    .foregroundColor(.white)
                    .font(.system(size: 16, weight: .medium))
                if let dev = app.developerName {
                    Text(dev)
                        .foregroundColor(.gray)
                        .font(.caption)
                }
                Text(app.version)
                    .foregroundColor(Color(white: 0.45))
                    .font(.caption)
            }

            Spacer()

            AppActionButton(app: app)
        }
        .padding(.vertical, 6)
    }
}

// MARK: - App Action Button
struct AppActionButton: View {
    @EnvironmentObject var store: AppStore
    let app: AppItem

    var body: some View {
        Group {
            if let progress = store.downloadProgress(for: app) {
                ZStack {
                    Circle()
                        .stroke(Color(white: 0.2), lineWidth: 2)
                        .frame(width: 32, height: 32)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(Color.blue, lineWidth: 2)
                        .rotationEffect(.degrees(-90))
                        .frame(width: 32, height: 32)
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.gray)
                }
            } else if app.isDownloaded {
                Button(action: { store.install(app: app) }) {
                    Text("Install")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.blue)
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .background(Color.blue.opacity(0.15))
                        .clipShape(Capsule())
                }
            } else {
                Button(action: { store.download(app: app) }) {
                    Text("Get")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.blue)
                        .padding(.horizontal, 20).padding(.vertical, 7)
                        .background(Color.blue.opacity(0.15))
                        .clipShape(Capsule())
                }
            }
        }
    }
}

// MARK: - Active Download Row
struct ActiveDownloadRow: View {
    let item: DownloadItem

    var sizeText: String {
        if item.totalBytes > 0 {
            let received = Double(item.bytesReceived) / 1_000_000
            let total = Double(item.totalBytes) / 1_000_000
            return String(format: "%.1f / %.1f MB", received, total)
        }
        return "Downloading…"
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.blue.opacity(0.1))
                    .frame(width: 44, height: 44)
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundColor(.blue)
                    .font(.title2)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(item.name)
                    .foregroundColor(.white)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                ProgressView(value: item.progress)
                    .tint(.blue)
                HStack {
                    Text(sizeText)
                        .foregroundColor(.gray)
                        .font(.caption)
                    Spacer()
                    Text("\(Int(item.progress * 100))%")
                        .foregroundColor(.blue)
                        .font(.caption.bold())
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - App Detail View
struct AppDetailView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    let app: AppItem

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 0) {
                        ZStack(alignment: .bottom) {
                            if let iconURL = app.iconURL, let url = URL(string: iconURL) {
                                AsyncImage(url: url) { phase in
                                    if case .success(let image) = phase {
                                        image.resizable()
                                            .aspectRatio(contentMode: .fill)
                                            .frame(height: 200)
                                            .blur(radius: 40)
                                            .opacity(0.5)
                                            .clipped()
                                    }
                                }
                            } else {
                                LinearGradient(colors: [Color.blue.opacity(0.3), Color.black], startPoint: .top, endPoint: .bottom)
                                    .frame(height: 200)
                            }
                            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                                .frame(height: 200)
                        }
                        .frame(height: 160)

                        HStack(alignment: .bottom, spacing: 16) {
                            AppIconView(iconURL: app.iconURL, size: 88)
                                .offset(y: -20)
                                .shadow(color: .black.opacity(0.5), radius: 10)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(app.name)
                                    .font(.title3.bold())
                                    .foregroundColor(.white)
                                if let dev = app.developerName {
                                    Text(dev)
                                        .foregroundColor(.gray)
                                        .font(.subheadline)
                                }
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, -20)

                        HStack(spacing: 12) {
                            if let progress = store.downloadProgress(for: app) {
                                VStack(spacing: 6) {
                                    ProgressView(value: progress)
                                        .tint(.blue)
                                    Text("\(Int(progress * 100))%")
                                        .font(.caption.bold())
                                        .foregroundColor(.blue)
                                }
                                .padding(.horizontal, 20)
                            } else if app.isDownloaded {
                                Button(action: {
                                    store.install(app: app)
                                    dismiss()
                                }) {
                                    Text("Install")
                                        .font(.system(size: 17, weight: .bold))
                                        .foregroundColor(.white)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 14)
                                        .background(Color.blue)
                                        .cornerRadius(14)
                                }
                                .padding(.horizontal, 20)
                            } else {
                                Button(action: {
                                    store.download(app: app)
                                    dismiss()
                                }) {
                                    Text("Get")
                                        .font(.system(size: 17, weight: .bold))
                                        .foregroundColor(.white)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 14)
                                        .background(Color.blue)
                                        .cornerRadius(14)
                                }
                                .padding(.horizontal, 20)
                            }
                        }
                        .padding(.top, 4)
                        .padding(.bottom, 20)

                        Divider().background(Color(white: 0.2)).padding(.horizontal)

                        if let desc = app.appDescription, !desc.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Description")
                                    .font(.headline.bold())
                                    .foregroundColor(.white)
                                Text(desc)
                                    .foregroundColor(.gray)
                                    .font(.subheadline)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(20)

                            Divider().background(Color(white: 0.2)).padding(.horizontal)
                        }

                        VStack(alignment: .leading, spacing: 0) {
                            Text("Information")
                                .font(.headline.bold())
                                .foregroundColor(.white)
                                .padding(.horizontal, 20)
                                .padding(.top, 20)
                                .padding(.bottom, 12)

                            Group {
                                InfoRow(label: "Version", value: app.version)
                                InfoRow(label: "Identifier", value: app.bundleID)
                                if let size = app.size { InfoRow(label: "Size", value: size) }
                                if let dev = app.developerName { InfoRow(label: "Developer", value: dev) }
                            }
                        }
                        .padding(.bottom, 20)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.gray)
                .font(.subheadline)
            Spacer()
            Text(value)
                .foregroundColor(.white)
                .font(.subheadline)
                .lineLimit(1)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(white: 0.08))
        Divider().background(Color(white: 0.12)).padding(.horizontal, 20)
    }
}

// MARK: - Sources View
struct SourcesView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State var showAddSource = false
    @State var newSourceName = ""
    @State var newSourceURL = ""
    @State var alertMessage = ""
    @State var showAlert = false
    @State var fetchingSourceID: UUID?

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                if store.sources.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "globe")
                            .font(.system(size: 56))
                            .foregroundStyle(.blue.opacity(0.5))
                        Text("No Sources")
                            .font(.title3.bold())
                            .foregroundColor(.white)
                        Text("Add a repository to browse apps")
                            .foregroundColor(.gray)
                            .font(.subheadline)
                        Button(action: { showAddSource = true }) {
                            Label("Add Source", systemImage: "plus")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 24).padding(.vertical, 12)
                                .background(Color.blue)
                                .clipShape(Capsule())
                        }
                        .padding(.top, 4)
                    }
                } else {
                    List {
                        NavigationLink(destination: AllAppsFromSourcesView().environmentObject(store)) {
                            HStack(spacing: 14) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                                        .frame(width: 44, height: 44)
                                    Image(systemName: "square.stack.3d.up.fill")
                                        .foregroundColor(.white)
                                        .font(.system(size: 18))
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("All Repositories")
                                        .foregroundColor(.white)
                                        .font(.system(size: 16, weight: .medium))
                                    Text("See all apps from your sources")
                                        .foregroundColor(.gray)
                                        .font(.caption)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .listRowBackground(Color(white: 0.08))

                        Section(header: HStack {
                            Text("Repositories")
                                .foregroundColor(.white).font(.headline).bold()
                            Spacer()
                            Text("\(store.sources.count)")
                                .foregroundColor(.white).font(.caption2.bold())
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Color(white: 0.25))
                                .clipShape(Capsule())
                        }) {
                            ForEach(store.sources) { src in
                                HStack(spacing: 14) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(Color.blue.opacity(0.15))
                                            .frame(width: 44, height: 44)
                                        Image(systemName: "globe")
                                            .foregroundColor(.blue)
                                            .font(.system(size: 18))
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(src.name)
                                            .foregroundColor(.white)
                                            .font(.system(size: 15, weight: .medium))
                                        Text(src.url)
                                            .foregroundColor(.gray)
                                            .font(.caption)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Button(action: {
                                        fetchingSourceID = src.id
                                        store.fetch(source: src) { result in
                                            fetchingSourceID = nil
                                            switch result {
                                            case .success(let count):
                                                alertMessage = count > 0 ? "Added \(count) new app(s)." : "No new apps found."
                                            case .failure(let error):
                                                alertMessage = "Error: \(error.localizedDescription)"
                                            }
                                            showAlert = true
                                        }
                                    }) {
                                        if fetchingSourceID == src.id {
                                            ProgressView().tint(.white).scaleEffect(0.7)
                                                .frame(width: 60)
                                        } else {
                                            Text("Fetch")
                                                .font(.caption.bold())
                                                .foregroundColor(.white)
                                                .padding(.horizontal, 14).padding(.vertical, 6)
                                                .background(Color.blue)
                                                .clipShape(Capsule())
                                        }
                                    }
                                }
                                .padding(.vertical, 4)
                                .listRowBackground(Color(white: 0.08))
                            }
                            .onDelete {
                                store.sources.remove(atOffsets: $0)
                                store.saveAll()
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Sources")
            .alert("Fetch Result", isPresented: $showAlert) {
                Button("OK") {}
            } message: {
                Text(alertMessage)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showAddSource = true }) {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAddSource) {
                AddSourceSheet(isPresented: $showAddSource)
                    .environmentObject(store)
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Add Source Sheet
struct AddSourceSheet: View {
    @EnvironmentObject var store: AppStore
    @Binding var isPresented: Bool
    @State var newSourceName = ""
    @State var newSourceURL = ""

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Source Name")
                            .foregroundColor(.gray)
                            .font(.caption.bold())
                        TextField("My Repo", text: $newSourceName)
                            .padding(14)
                            .background(Color(white: 0.1))
                            .cornerRadius(12)
                            .foregroundColor(.white)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Source URL")
                            .foregroundColor(.gray)
                            .font(.caption.bold())
                        TextField("https://example.com/apps.json", text: $newSourceURL)
                            .padding(14)
                            .background(Color(white: 0.1))
                            .cornerRadius(12)
                            .foregroundColor(.white)
                            .keyboardType(.URL)
                            .autocapitalization(.none)
                    }

                    Button(action: {
                        let name = newSourceName.trimmingCharacters(in: .whitespaces)
                        let url = newSourceURL.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty && !url.isEmpty else { return }
                        store.sources.append(Source(name: name, url: url))
                        store.saveAll()
                        isPresented = false
                    }) {
                        Text("Add Source")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(newSourceName.isEmpty || newSourceURL.isEmpty ? Color(white: 0.2) : Color.blue)
                            .cornerRadius(14)
                    }
                    .disabled(newSourceName.isEmpty || newSourceURL.isEmpty)

                    Spacer()
                }
                .padding(20)
            }
            .navigationTitle("Add Source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - All Apps From Sources
struct AllAppsFromSourcesView: View {
    @EnvironmentObject var store: AppStore
    @State var searchText = ""
    @State var selectedApp: AppItem?

    var filtered: [AppItem] {
        if searchText.isEmpty { return store.apps }
        return store.apps.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            List {
                Section(header: Text("\(filtered.count) Apps").foregroundColor(.gray).font(.subheadline)) {
                    ForEach(filtered) { app in
                        Button(action: { selectedApp = app }) {
                            AppStoreRow(app: app)
                        }
                        .listRowBackground(Color(white: 0.08))
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("All Repositories")
        .searchable(text: $searchText, prompt: "Search")
        .sheet(item: $selectedApp) { app in
            AppDetailView(app: app).environmentObject(store)
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
                if store.activeDownloads.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 56))
                            .foregroundStyle(.blue.opacity(0.5))
                        Text("No Active Downloads")
                            .font(.title3.bold())
                            .foregroundColor(.white)
                        Text("Downloads will appear here while in progress")
                            .foregroundColor(.gray)
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                } else {
                    List {
                        Section(header: HStack {
                            Text("Downloading")
                                .foregroundColor(.white).font(.headline).bold()
                            Spacer()
                            Text("\(store.activeDownloads.count)")
                                .foregroundColor(.white).font(.caption2.bold())
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Color(white: 0.25))
                                .clipShape(Capsule())
                        }) {
                            ForEach(store.activeDownloads) { item in
                                ActiveDownloadRow(item: item)
                                    .listRowBackground(Color(white: 0.08))
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
                    Button(action: { showAddDownload = true }) {
                        Image(systemName: "plus")
                    }
                }
            }
            .alert("Download IPA", isPresented: $showAddDownload) {
                TextField("https://example.com/app.ipa", text: $downloadURL)
                    .keyboardType(.URL)
                Button("Download") {
                    guard let url = URL(string: downloadURL), !downloadURL.isEmpty else { return }
                    let name = url.deletingPathExtension().lastPathComponent
                    let fakeApp = AppItem(name: name, version: "1.0", bundleID: "com.direct.\(name.lowercased())", ipaURL: downloadURL)
                    store.download(app: fakeApp)
                    downloadURL = ""
                }
                Button("Cancel", role: .cancel) { downloadURL = "" }
            }
        }
    }
}

// MARK: - Settings View
struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @State var showResetConfirm = false

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                List {
                    Section {
                        VStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .fill(LinearGradient(colors: [.blue, Color(red: 0.1, green: 0.3, blue: 0.9)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .frame(width: 72, height: 72)
                                Image(systemName: "signature")
                                    .font(.system(size: 32))
                                    .foregroundColor(.white)
                            }
                            Text("MySigner")
                                .font(.title2.bold())
                                .foregroundColor(.white)
                            Text("IPA Signing Tool • v1.0")
                                .foregroundColor(.gray)
                                .font(.caption)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .listRowBackground(Color(white: 0.08))
                    }

                    Section(header: Text("Features").foregroundColor(.white).font(.headline).bold()) {
                        NavigationLink(destination: CertificatesView().environmentObject(store)) {
                            SettingsRowContent(icon: "signature", iconColor: .blue, title: "Certificates")
                            Spacer()
                            Text("\(store.certificates.count)")
                                .foregroundColor(.gray)
                                .font(.subheadline)
                        }
                        .listRowBackground(Color(white: 0.08))

                        NavigationLink(destination: SigningOptionsView()) {
                            SettingsRowContent(icon: "gearshape.fill", iconColor: .blue, title: "Signing Options")
                        }
                        .listRowBackground(Color(white: 0.08))
                    }

                    Section(header: Text("Reset").foregroundColor(.white).font(.headline).bold()) {
                        Button(action: {
                            store.apps.removeAll()
                            store.saveAll()
                        }) {
                            SettingsRowContent(icon: "xmark.circle.fill", iconColor: .orange, title: "Reset Apps")
                        }
                        .listRowBackground(Color(white: 0.08))

                        Button(action: {
                            store.sources.removeAll()
                            store.saveAll()
                        }) {
                            SettingsRowContent(icon: "xmark.circle.fill", iconColor: .orange, title: "Reset Sources")
                        }
                        .listRowBackground(Color(white: 0.08))

                        Button(action: { showResetConfirm = true }) {
                            SettingsRowContent(icon: "trash.fill", iconColor: .red, title: "Reset All Data")
                        }
                        .listRowBackground(Color(white: 0.08))
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Settings")
            .alert("Reset All Data?", isPresented: $showResetConfirm) {
                Button("Reset", role: .destructive) {
                    store.apps.removeAll()
                    store.sources.removeAll()
                    store.certificates.removeAll()
                    store.saveAll()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will delete all apps, sources, and certificates. This cannot be undone.")
            }
        }
    }
}

// MARK: - Signing Options View
struct SigningOptionsView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "gearshape.2.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.blue.opacity(0.5))
                Text("Signing Options")
                    .font(.title3.bold())
                    .foregroundColor(.white)
                Text("Coming soon")
                    .foregroundColor(.gray)
            }
        }
        .navigationTitle("Signing Options")
        .preferredColorScheme(.dark)
    }
}

// MARK: - Certificates View
struct CertificatesView: View {
    @EnvironmentObject var store: AppStore
    @State private var showAddCert = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if store.certificates.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "signature")
                        .font(.system(size: 56))
                        .foregroundStyle(.blue.opacity(0.5))
                    Text("No Certificates")
                        .font(.title3.bold())
                        .foregroundColor(.white)
                    Text("Add a P12 certificate to start signing")
                        .foregroundColor(.gray)
                        .font(.subheadline)
                    Button(action: { showAddCert = true }) {
                        Label("Add Certificate", systemImage: "plus")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 24).padding(.vertical, 12)
                            .background(Color.blue)
                            .clipShape(Capsule())
                    }
                    .padding(.top, 4)
                }
            } else {
                List {
                    ForEach(store.certificates) { cert in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(cert.name)
                                .foregroundColor(.white)
                                .font(.system(size: 16, weight: .semibold))
                            if !cert.teamID.isEmpty {
                                Text(cert.teamID)
                                    .foregroundColor(.gray)
                                    .font(.caption)
                            }
                            HStack(spacing: 10) {
                                Label(cert.isValid ? "Valid" : "Expired", systemImage: cert.isValid ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .font(.subheadline.bold())
                                    .foregroundColor(cert.isValid ? .green : .red)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background((cert.isValid ? Color.green : Color.red).opacity(0.12))
                                    .cornerRadius(10)

                                Label("\(cert.daysLeft) days", systemImage: "clock.fill")
                                    .font(.subheadline.bold())
                                    .foregroundColor(.yellow)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(Color.yellow.opacity(0.12))
                                    .cornerRadius(10)
                            }
                        }
                        .padding(16)
                        .background(Color(white: 0.08))
                        .cornerRadius(16)
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.blue.opacity(0.4), lineWidth: 1.5))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
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
            AddCertificateView().environmentObject(store)
        }
    }
}

// MARK: - Add Certificate View
struct AddCertificateView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State private var certName = ""
    @State private var p12URL: URL?
    @State private var provURL: URL?
    
    @State private var showP12Picker = false
    @State private var showProvPicker = false

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(spacing: 16) {
                    TextField("Certificate Name", text: $certName)
                        .padding(14)
                        .background(Color(white: 0.1))
                        .cornerRadius(12)
                        .foregroundColor(.white)

                    FilePickerRow(icon: "lock.shield.fill", title: "P12 File", subtitle: p12URL?.lastPathComponent ?? "Select .p12 file", color: .purple, isSelected: p12URL != nil) {
                        showP12Picker = true
                    }

                    FilePickerRow(icon: "doc.badge.gearshape.fill", title: "Provision Profile", subtitle: provURL?.lastPathComponent ?? "Select .mobileprovision (optional)", color: .cyan, isSelected: provURL != nil) {
                        showProvPicker = true
                    }

                    Button(action: {
                        guard let p12 = p12URL else { return }
                        let name = certName.isEmpty ? p12.deletingPathExtension().lastPathComponent : certName
                        store.addCertificate(name: name, p12URL: p12, provisionURL: provURL)
                        dismiss()
                    }) {
                        Text("Add Certificate")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(p12URL != nil ? Color.blue : Color(white: 0.2))
                            .cornerRadius(14)
                    }
                    .disabled(p12URL == nil)

                    Spacer()
                }
                .padding(20)
            }
            .navigationTitle("Add Certificate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .background(
                Group {
                    FilePicker(isPresented: $showP12Picker) { url in
                        p12URL = url
                    }
                    FilePicker(isPresented: $showProvPicker) { url in
                        provURL = url
                    }
                }
            )
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
                    Circle().fill(color.opacity(0.15)).frame(width: 48, height: 48)
                    Image(systemName: icon).font(.system(size: 20)).foregroundColor(color)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
                    Text(subtitle).font(.caption).foregroundColor(.gray).lineLimit(1)
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "chevron.right")
                    .foregroundColor(isSelected ? .green : Color(white: 0.4))
            }
            .padding(14)
            .background(Color(white: 0.1))
            .cornerRadius(14)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(isSelected ? color.opacity(0.4) : Color.clear, lineWidth: 1.5))
        }
    }
}

struct SettingsRowContent: View {
    let icon: String; let iconColor: Color; let title: String
    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(iconColor.opacity(0.15)).frame(width: 32, height: 32)
                Image(systemName: icon).foregroundColor(iconColor).font(.system(size: 15))
            }
            Text(title).foregroundColor(.white)
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View { ContentView() }
}
