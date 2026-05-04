import SwiftUI
import UniformTypeIdentifiers
import Network
import Foundation

// MARK: - Models
struct Certificate: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var teamID: String
    var expiryDate: Date
    var p12Path: String
    var mobileProvisionPath: String?
    var daysLeft: Int {
        Calendar.current.dateComponents([.day], from: Date(), to: expiryDate).day ?? 0
    }
    var isValid: Bool { daysLeft > 0 }
}

struct AppItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var version: String
    var bundleID: String
    var ipaURL: String
    var iconURL: String?
    var localPath: String?
    var isDownloaded: Bool = false
    var isInstalled: Bool = false
}

struct DownloadItem: Identifiable, Codable {
    var id = UUID()
    var name: String
    var ipaURL: String
    var progress: Double = 0.0
}

struct Source: Identifiable, Codable {
    var id = UUID()
    var name: String
    var url: String
}

// MARK: - App Store Manager
class AppStore: ObservableObject {
    @Published var certificates: [Certificate] = []
    @Published var apps: [AppItem] = []
    @Published var downloads: [DownloadItem] = []
    @Published var sources: [Source] = []

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
    let downloadsDir: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("MySignerDownloads")
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
        certificates = load(Certificate.self, from: "certificates.json")
        apps = load(AppItem.self, from: "apps.json")
        downloads = load(DownloadItem.self, from: "downloads.json")
        sources = load(Source.self, from: "sources.json")
    }

    func saveAll() {
        save(certificates, to: "certificates.json")
        save(apps, to: "apps.json")
        save(downloads, to: "downloads.json")
        save(sources, to: "sources.json")
    }

    // MARK: - Fetch Source
    func fetch(source: Source, completion: @escaping (Result<[AppItem], Error>) -> Void) {
        guard let url = URL(string: source.url) else {
            completion(.failure(URLError(.badURL)))
            return
        }
        URLSession.shared.dataTask(with: url) { data, _, error in
            DispatchQueue.main.async {
                if let error = error { completion(.failure(error)); return }
                guard let data = data else {
                    completion(.failure(URLError(.cannotParseResponse)))
                    return
                }
                do {
                    var fetched = try JSONDecoder().decode([AppItem].self, from: data)
                    let existingIDs = Set(self.apps.map { $0.bundleID })
                    fetched = fetched.filter { !existingIDs.contains($0.bundleID) }
                    self.apps.append(contentsOf: fetched)
                    self.saveAll()
                    completion(.success(fetched))
                } catch {
                    completion(.failure(error))
                }
            }
        }.resume()
    }

    // MARK: - Download with progress
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
        let observation = task.progress.observe(\.fractionCompleted) { prog, _ in
            DispatchQueue.main.async {
                if let idx = self.downloads.firstIndex(where: { $0.id == item.id }) {
                    self.downloads[idx].progress = prog.fractionCompleted
                }
            }
        }
        task.resume()
        // keep observation alive
        _ = observation
    }

    // MARK: - Install via local server
    func install(app: AppItem, server: LocalHTTPServer) {
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
            UIApplication.shared.open(url) { success in
                if success {
                    if let idx = self.apps.firstIndex(where: { $0.id == app.id }) {
                        self.apps[idx].isInstalled = true
                        self.saveAll()
                    }
                }
            }
        }
    }
}

// MARK: - Local HTTP Server
class LocalHTTPServer: ObservableObject {
    private var listener: NWListener?
    let port: UInt16 = 8080
    private(set) var isRunning = false
    var manifestData: Data?
    var ipaFilePath: String?

    func start() {
        guard !isRunning else { return }
        let params = NWParameters.tcp
        listener = try? NWListener(using: params, on: NWEndpoint.Port(integerLiteral: port))
        listener?.stateUpdateHandler = { [weak self] state in
            if state == .ready { self?.isRunning = true }
            else if state == .failed(_) { self?.isRunning = false }
            else if state == .cancelled { self?.isRunning = false }
        }
        listener?.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .main)
            self?.receive(on: connection)
        }
        listener?.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
        isRunning = false
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
            } else {
                connection.cancel()
            }
        } else {
            let notFound = "HTTP/1.1 404 Not Found\r\n\r\n".data(using: .utf8)!
            connection.send(content: notFound, completion: .idempotent)
            connection.cancel()
        }
    }
}

// MARK: - Main ContentView
struct ContentView: View {
    @StateObject private var store = AppStore()
    @StateObject private var server = LocalHTTPServer()
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            FilesView()
                .tabItem { Label("Files", systemImage: "folder.fill") }
                .tag(0)

            LibraryView(server: server)
                .tabItem { Label("Library", systemImage: "square.grid.2x2.fill") }
                .tag(1)

            StoreFrontView(server: server)
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
        .environmentObject(server)
    }
}

// MARK: - Files View
struct FilesView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                List {
                    NavigationLink(destination: Text("Apps folder: \(store.appsDir.path)").foregroundColor(.white)) {
                        HStack(spacing: 14) {
                            Image(systemName: "folder.fill").foregroundColor(.blue).font(.title2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Apps").foregroundColor(.white)
                                Text(store.appsDir.lastPathComponent).foregroundColor(.gray).font(.caption)
                            }
                        }
                    }.listRowBackground(Color.black)

                    NavigationLink(destination: Text("Downloads folder: \(store.downloadsDir.path)").foregroundColor(.white)) {
                        HStack(spacing: 14) {
                            Image(systemName: "folder.fill").foregroundColor(.blue).font(.title2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Downloads").foregroundColor(.white)
                                Text(store.downloadsDir.lastPathComponent).foregroundColor(.gray).font(.caption)
                            }
                        }
                    }.listRowBackground(Color.black)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Documents")
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {} label: { Image(systemName: "plus") }
                    Button {} label: { Image(systemName: "pencil") }
                }
            }
        }
    }
}

// MARK: - Library View
struct LibraryView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var server: LocalHTTPServer
    @State private var tab = 0

    var downloadedApps: [AppItem] { store.apps.filter { $0.isDownloaded } }
    var installedApps: [AppItem] { store.apps.filter { $0.isInstalled } }

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

                    if tab == 0 {
                        AppListView(apps: downloadedApps, server: server)
                    } else {
                        if installedApps.isEmpty {
                            Text("No installed apps").foregroundColor(.gray)
                        } else {
                            AppListView(apps: installedApps, server: server, showInstall: false)
                        }
                    }
                }
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Edit") {} }
                ToolbarItem(placement: .navigationBarTrailing) { Button {} label: { Image(systemName: "plus") } }
            }
        }
    }
}

struct AppListView: View {
    let apps: [AppItem]
    @ObservedObject var server: LocalHTTPServer
    var showInstall: Bool = true
    @EnvironmentObject var store: AppStore

    var body: some View {
        List {
            ForEach(apps) { app in
                HStack(spacing: 14) {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 52, height: 52)
                        .overlay(Image(systemName: "app.fill").foregroundColor(.gray).font(.title2))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.name).foregroundColor(.white).font(.body)
                        Text("\(app.version) • \(app.bundleID)").foregroundColor(.gray).font(.caption)
                    }
                    Spacer()
                    if showInstall && !app.isInstalled {
                        Button("Install") {
                            store.install(app: app, server: server)
                        }
                        .font(.caption.bold())
                        .foregroundColor(.white)
                        .padding(.horizontal, 16).padding(.vertical, 6)
                        .background(Color.blue).clipShape(Capsule())
                    } else if app.isInstalled {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    }
                }
                .padding(.vertical, 4)
                .listRowBackground(Color.black)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - App Store (StoreFrontView)
struct StoreFrontView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var server: LocalHTTPServer
    @State private var showSources = false
    @State private var searchText = ""

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
                                    .fill(Color.gray.opacity(0.25))
                                    .frame(width: 52, height: 52)
                                    .overlay(Image(systemName: "app").foregroundColor(.gray))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(app.name).foregroundColor(.white)
                                    Text("\(app.version) • \(app.bundleID)").foregroundColor(.gray).font(.caption)
                                }
                                Spacer()
                                if app.isDownloaded {
                                    Button("Install") { store.install(app: app, server: server) }
                                        .font(.caption.bold()).foregroundColor(.white)
                                        .padding(.horizontal, 14).padding(.vertical, 5)
                                        .background(Color.blue).clipShape(Capsule())
                                } else {
                                    Button("Get") { store.download(app: app) }
                                        .font(.caption.bold()).foregroundColor(.white)
                                        .padding(.horizontal, 14).padding(.vertical, 5)
                                        .background(Color.gray.opacity(0.4)).clipShape(Capsule())
                                }
                            }
                            .padding(.vertical, 4)
                            .listRowBackground(Color.black)
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
                    Button { } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showSources) {
                SourcesView()
            }
        }
    }
}

// MARK: - Sources View
struct SourcesView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State private var showAddSource = false

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                List {
                    Section(header: Text("Repositories").foregroundColor(.white)) {
                        ForEach(store.sources) { source in
                            HStack(spacing: 14) {
                                Image(systemName: "globe").foregroundColor(.gray)
                                VStack(alignment: .leading) {
                                    Text(source.name).foregroundColor(.white)
                                    Text(source.url).foregroundColor(.gray).font(.caption).lineLimit(1)
                                }
                                Spacer()
                                Button("Fetch") {
                                    store.fetch(source: source) { _ in }
                                }
                                .font(.caption.bold()).foregroundColor(.white)
                                .padding(.horizontal, 12).padding(.vertical, 4)
                                .background(Color.blue).clipShape(Capsule())
                            }
                            .listRowBackground(Color.black)
                        }
                        .onDelete { idx in store.sources.remove(atOffsets: idx); store.saveAll() }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Sources")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("App Store") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showAddSource = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showAddSource) {
                AddSourceView()
            }
        }
    }
}

struct AddSourceView: View {
    @EnvironmentObject var store: AppStore
    @State private var name = ""
    @State private var url = ""
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationView {
            Form {
                TextField("Name", text: $name)
                TextField("URL (apps.json)", text: $url)
                    .keyboardType(.URL)
                Button("Add") {
                    store.sources.append(Source(name: name, url: url))
                    store.saveAll()
                    dismiss()
                }
                .disabled(name.isEmpty || url.isEmpty)
            }
            .navigationTitle("Add Source")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Downloads View
struct DownloadsView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                if store.downloads.isEmpty {
                    Text("No active downloads").foregroundColor(.gray)
                } else {
                    List {
                        ForEach(store.downloads) { item in
                            HStack(spacing: 14) {
                                Image(systemName: "doc.zipper").foregroundColor(.blue).font(.title2)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.name).foregroundColor(.white)
                                    HStack {
                                        ProgressView(value: item.progress)
                                            .frame(width: 100)
                                        Text("\(Int(item.progress * 100))%")
                                            .foregroundColor(.gray).font(.caption)
                                    }
                                }
                            }
                            .padding(.vertical, 6)
                            .listRowBackground(Color.black)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Downloads")
        }
    }
}

// MARK: - Settings View
struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @State private var showCertificates = false

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                List {
                    Section {
                        NavigationLink(destination: CertificatesView()) {
                            Label("Certificates", systemImage: "signature")
                        }
                    }
                    .listRowBackground(Color(white: 0.12))

                    Section(header: Text("About").foregroundColor(.white)) {
                        NavigationLink(destination: Text("MySigner v1.0").foregroundColor(.white)) {
                            Label("About", systemImage: "info.circle")
                        }
                        Button {
                            // Example link
                        } label: {
                            Label("Telegram Channel", systemImage: "paperplane.fill").foregroundColor(.white)
                        }
                    }
                    .listRowBackground(Color(white: 0.12))

                    Section {
                        Button(role: .destructive) {
                            store.certificates.removeAll()
                            store.apps.removeAll()
                            store.sources.removeAll()
                            store.downloads.removeAll()
                            store.saveAll()
                        } label: {
                            Label("Reset All Data", systemImage: "trash")
                        }
                    }
                    .listRowBackground(Color(white: 0.12))
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Settings")
        }
    }
}

// MARK: - Certificates View
struct CertificatesView: View {
    @EnvironmentObject var store: AppStore
    @State private var showImporter = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if store.certificates.isEmpty {
                Text("No certificates imported").foregroundColor(.gray)
            } else {
                List {
                    ForEach(store.certificates) { cert in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(cert.name).foregroundColor(.white).bold()
                            Text("Team: \(cert.teamID)").foregroundColor(.gray)
                            HStack {
                                Label("Valid", systemImage: "checkmark.circle.fill").foregroundColor(.green)
                                Spacer()
                                Text("\(cert.daysLeft) days").foregroundColor(.yellow)
                            }
                        }
                        .padding()
                        .background(Color(white: 0.15))
                        .cornerRadius(12)
                        .listRowBackground(Color.black)
                    }
                    .onDelete { idx in store.certificates.remove(atOffsets: idx); store.saveAll() }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Certificates")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showImporter = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showImporter) {
            CertificateImporter()
        }
    }
}

struct CertificateImporter: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State private var p12Data: Data?
    @State private var provisionData: Data?
    @State private var password = ""

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Button("Select .p12") {
                        // Document picker integration simplified – you would use a UIDocumentPickerViewController wrapper
                    }
                    Button("Select .mobileprovision") {
                    }
                    SecureField("Password", text: $password)
                }
                Button("Import") {
                    if let p12 = p12Data {
                        let cert = Certificate(name: "Imported", teamID: "", expiryDate: Date().addingTimeInterval(3600*24*30), p12Path: "", mobileProvisionPath: nil)
                        store.certificates.append(cert)
                        store.saveAll()
                        dismiss()
                    }
                }
                .disabled(p12Data == nil)
            }
            .navigationTitle("Import Certificate")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View { ContentView() }
}