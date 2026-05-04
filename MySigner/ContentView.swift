import SwiftUI
import UniformTypeIdentifiers
import Network
import Foundation

// MARK: - Models
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

// MARK: - App Store Manager (عقلي حقيقي)
class AppStore: ObservableObject {
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
        let observation = task.progress.observe(\.fractionCompleted) { prog, _ in
            DispatchQueue.main.async {
                if let idx = self.downloads.firstIndex(where: { $0.id == item.id }) {
                    self.downloads[idx].progress = prog.fractionCompleted
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
        if let url = URL(string: urlString) {
            UIApplication.shared.open(url)
        }
    }

    // MARK: - Remote Signing Trigger
    func triggerRemoteSign(app: AppItem, p12Base64: String, provisionBase64: String, password: String, completion: @escaping (Bool, String) -> Void) {
        let token = UserDefaults.standard.string(forKey: "gh_token") ?? ""
        let owner = UserDefaults.standard.string(forKey: "repo_owner") ?? ""
        let repo = UserDefaults.standard.string(forKey: "repo_name") ?? ""

        guard !token.isEmpty, !owner.isEmpty, !repo.isEmpty,
              let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/actions/workflows/sign_remote.yml/dispatches") else {
            completion(false, "GitHub configuration missing")
            return
        }

        let body: [String: Any] = [
            "ref": "main",
            "inputs": [
                "ipa_url": app.ipaURL,
                "p12_base64": p12Base64,
                "mobileprovision_base64": provisionBase64,
                "password": password,
                "app_name": app.name
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
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
                    completion(false, "Failed to trigger workflow. Status: \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                }
            }
        }.resume()
    }
}

// MARK: - Local HTTP Server (حقيقي)
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

            SignView()
                .tabItem { Label("Sign", systemImage: "signature") }
                .tag(3)

            DownloadsView()
                .tabItem { Label("Downloads", systemImage: "arrow.down.app.fill") }
                .tag(4)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.2.fill") }
                .tag(5)
        }
        .accentColor(.blue)
        .preferredColorScheme(.dark)
        .environmentObject(store)
    }
}

// MARK: - Files View (مبسطة)
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
                }
                .navigationTitle("Documents")
            }
        }
    }
}

// MARK: - Library View (تطبيقات محملة/مثبتة)
struct LibraryView: View {
    @EnvironmentObject var store: AppStore
    @State private var tab = 0
    var downloadedApps: [AppItem] { store.apps.filter { $0.isDownloaded } }

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
                        AppListView(apps: downloadedApps)
                    } else {
                        Text("No installed apps").foregroundColor(.gray)
                    }
                }
            }
            .navigationTitle("Library")
        }
    }
}

struct AppListView: View {
    let apps: [AppItem]
    @EnvironmentObject var store: AppStore

    var body: some View {
        List(apps) { app in
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
                if !app.isInstalled {
                    Button("Install") { store.install(app: app) }
                        .font(.caption.bold()).foregroundColor(.white)
                        .padding(.horizontal, 16).padding(.vertical, 6)
                        .background(Color.blue).clipShape(Capsule())
                } else {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                }
            }
            .padding(.vertical, 4)
            .listRowBackground(Color.black)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - App Store View (متجر من المصادر)
struct AppStoreView: View {
    @EnvironmentObject var store: AppStore
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
                                    Button("Install") { store.install(app: app) }
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
            .searchable(text: $searchText)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Sources") { showSources = true }
                }
            }
            .sheet(isPresented: $showSources) {
                SourcesView()
            }
        }
    }
}

// MARK: - Sources View (إدارة المصادر)
struct SourcesView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State private var showAddSource = false

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                List {
                    ForEach(store.sources) { source in
                        HStack(spacing: 14) {
                            Image(systemName: "globe").foregroundColor(.gray)
                            VStack(alignment: .leading) {
                                Text(source.name).foregroundColor(.white)
                                Text(source.url).foregroundColor(.gray).font(.caption).lineLimit(1)
                            }
                            Spacer()
                            Button("Fetch") { store.fetch(source: source) { _ in } }
                                .font(.caption.bold()).foregroundColor(.white)
                                .padding(.horizontal, 12).padding(.vertical, 4)
                                .background(Color.blue).clipShape(Capsule())
                        }
                        .listRowBackground(Color.black)
                    }
                    .onDelete { store.sources.remove(atOffsets: $0); store.saveAll() }
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
                    let source = Source(name: name, url: url)
                    store.sources.append(source)
                    store.saveAll()
                    dismiss()
                }
                .disabled(name.isEmpty || url.isEmpty)
            }
            .navigationTitle("Add Source")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

// MARK: - Sign View (توقيع عن بعد)
struct SignView: View {
    @EnvironmentObject var store: AppStore
    @State private var selectedApp: AppItem?
    @State private var p12Base64 = ""
    @State private var provBase64 = ""
    @State private var password = ""
    @State private var status = ""

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(spacing: 20) {
                    Picker("App", selection: $selectedApp) {
                        Text("Select an app").tag(nil as AppItem?)
                        ForEach(store.apps) { app in
                            Text(app.name).tag(app as AppItem?)
                        }
                    }
                    .pickerStyle(.wheel)
                    .foregroundColor(.white)

                    TextField("P12 Base64", text: $p12Base64)
                        .textFieldStyle(.roundedBorder)
                    TextField("Mobileprovision Base64", text: $provBase64)
                        .textFieldStyle(.roundedBorder)
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)

                    Button("Sign & Install") {
                        guard let app = selectedApp else { return }
                        store.triggerRemoteSign(app: app, p12Base64: p12Base64, provisionBase64: provBase64, password: password) { success, msg in
                            status = msg
                        }
                    }
                    .font(.body.bold()).foregroundColor(.white)
                    .padding().background(Color.blue).cornerRadius(12)

                    Text(status).foregroundColor(.gray)
                    Spacer()
                }
                .padding()
            }
            .navigationTitle("Sign IPA")
        }
    }
}

// MARK: - Downloads View (تنزيلات نشطة)
struct DownloadsView: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                if store.downloads.isEmpty {
                    Text("No active downloads").foregroundColor(.gray)
                } else {
                    List(store.downloads) { item in
                        HStack(spacing: 14) {
                            Image(systemName: "doc.zipper").foregroundColor(.blue)
                            VStack(alignment: .leading) {
                                Text(item.name).foregroundColor(.white)
                                ProgressView(value: item.progress)
                                    .frame(width: 120)
                            }
                        }
                        .listRowBackground(Color.black)
                    }
                }
            }
            .navigationTitle("Downloads")
        }
    }
}

// MARK: - Settings View (GitHub config)
struct SettingsView: View {
    @AppStorage("gh_token") private var token = ""
    @AppStorage("repo_owner") private var owner = ""
    @AppStorage("repo_name") private var repo = ""

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                Form {
                    Section(header: Text("GitHub Remote Sign Config").foregroundColor(.white)) {
                        TextField("Personal Access Token", text: $token)
                        TextField("Owner (username)", text: $owner)
                        TextField("Repo name", text: $repo)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Settings")
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View { ContentView() }
}