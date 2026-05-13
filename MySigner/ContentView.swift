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
    var password: String = ""
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
    func addCertificate(name: String, password: String, p12URL: URL, provisionURL: URL?) {
        let p12Dest = certsDir.appendingPathComponent(UUID().uuidString + ".p12")
        try? FileManager.default.copyItem(at: p12URL, to: p12Dest)

        var provDest: String? = nil
        if let provURL = provisionURL {
            let dest = certsDir.appendingPathComponent(UUID().uuidString + ".mobileprovision")
            try? FileManager.default.copyItem(at: provURL, to: dest)
            provDest = dest.path
        }

        let cert = Certificate(name: name, password: password, p12Path: p12Dest.path, mobileProvisionPath: provDest)
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

    // MARK: - Remote Signing
    func signAndInstall(app: AppItem, certificate: Certificate, completion: @escaping (Result<String, Error>) -> Void) {
        guard let localPath = app.localPath,
              let p12Data = try? Data(contentsOf: URL(fileURLWithPath: certificate.p12Path)) else {
            completion(.failure(NSError(domain: "MySigner", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing files"])))
            return
        }
        
        let ipaURL = URL(fileURLWithPath: localPath)
        guard let ipaData = try? Data(contentsOf: ipaURL) else {
            completion(.failure(NSError(domain: "MySigner", code: -1, userInfo: [NSLocalizedDescriptionKey: "Could not read IPA file"])))
            return
        }
        
        var provData: Data? = nil
        if let provPath = certificate.mobileProvisionPath {
            provData = try? Data(contentsOf: URL(fileURLWithPath: provPath))
        }
        
        let url = URL(string: "https://signtools.ipaomtk.com/sign-merge.php")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var body = Data()
        
        func append(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        
        func appendFile(_ name: String, _ data: Data, _ filename: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
            body.append(data)
            body.append("\r\n".data(using: .utf8)!)
        }
        
        appendFile("p12", p12Data, "cert.p12")
        if let prov = provData {
            appendFile("mobileprovision", prov, "profile.mobileprovision")
        }
        append("password", certificate.password)
        appendFile("custom_ipa", ipaData, "app.ipa")
        append("custom_name", app.name)
        append("bundle", app.bundleID)
        append("mode", "custom_ipa")
        
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            
            guard let data = data else {
                DispatchQueue.main.async { completion(.failure(NSError(domain: "MySigner", code: -1, userInfo: [NSLocalizedDescriptionKey: "No data from server"]))) }
                return
            }
            
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let status = json["status"] as? String, status == "error" {
                        let msg = json["message"] as? String ?? "Unknown server error"
                        DispatchQueue.main.async { completion(.failure(NSError(domain: "MySigner", code: -1, userInfo: [NSLocalizedDescriptionKey: msg]))) }
                        return
                    }
                    
                    // Check multiple possible keys for the manifest URL
                    let manifestUrl = json["manifestUrl"] as? String ?? 
                                     json["manifest_url"] as? String ?? 
                                     json["url"] as? String
                    
                    if let url = manifestUrl {
                        DispatchQueue.main.async { completion(.success(url)) }
                    } else {
                        let rawResponse = String(data: data, encoding: .utf8) ?? "Unable to read response"
                        let errorMsg = "Manifest URL not found. Server response: \(rawResponse)"
                        DispatchQueue.main.async { completion(.failure(NSError(domain: "MySigner", code: -1, userInfo: [NSLocalizedDescriptionKey: errorMsg]))) }
                    }
                }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }.resume()
    }
    
    func triggerInstallation(manifestUrl: String) {
        let installURL = "itms-services://?action=download-manifest&url=\(manifestUrl)"
        if let url = URL(string: installURL) {
            UIApplication.shared.open(url)
        }
    }
}

// MARK: - SwiftUI Native FilePicker
struct FilePicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    var allowedContentTypes: [UTType] = [.item]
    var onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        return controller
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        if isPresented && uiViewController.presentedViewController == nil {
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: allowedContentTypes, asCopy: true)
            picker.delegate = context.coordinator
            picker.allowsMultipleSelection = false
            uiViewController.present(picker, animated: true)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        var parent: FilePicker

        init(_ parent: FilePicker) {
            self.parent = parent
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            
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
            
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
            
            DispatchQueue.main.async {
                self.parent.onPick(resultURL)
                self.parent.isPresented = false
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            DispatchQueue.main.async {
                self.parent.isPresented = false
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
                        image.resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: size, height: size)
                            .cornerRadius(size * 0.22)
                    default:
                        defaultIcon
                    }
                }
            } else {
                defaultIcon
            }
        }
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
                FilePicker(isPresented: $showImporter, allowedContentTypes: [.item, .data, .content]) { url in
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
        guard let attr = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attr[.size] as? Int64 else { return "0 KB" }
        let mb = Double(size) / 1_000_000
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        return String(format: "%.0f KB", Double(size) / 1000)
    }
}

// MARK: - Library View
struct LibraryView: View {
    @EnvironmentObject var store: AppStore
    @State private var showSignSheet = false
    @State private var selectedApp: AppItem?

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                if store.apps.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 56))
                            .foregroundStyle(.blue.opacity(0.6))
                        Text("No Apps")
                            .font(.title3.bold())
                            .foregroundColor(.white)
                        Text("Apps you download or import will appear here")
                            .foregroundColor(.gray)
                            .font(.subheadline)
                    }
                } else {
                    List {
                        ForEach(store.apps) { app in
                            Button(action: {
                                selectedApp = app
                                showSignSheet = true
                            }) {
                                HStack(spacing: 14) {
                                    AppIconView(iconURL: app.iconURL, size: 54)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(app.name)
                                            .foregroundColor(.white)
                                            .font(.system(size: 15, weight: .bold))
                                        Text(app.bundleID)
                                            .foregroundColor(.gray)
                                            .font(.caption)
                                    }
                                    Spacer()
                                    if app.isDownloaded {
                                        Text("SIGN")
                                            .font(.system(size: 12, weight: .black))
                                            .foregroundColor(.blue)
                                            .padding(.horizontal, 16).padding(.vertical, 6)
                                            .background(Color.blue.opacity(0.15))
                                            .cornerRadius(12)
                                    }
                                }
                                .padding(.vertical, 6)
                            }
                            .listRowBackground(Color(white: 0.08))
                        }
                        .onDelete { idx in store.apps.remove(atOffsets: idx); store.saveAll() }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Library")
            .sheet(isPresented: $showSignSheet) {
                if let app = selectedApp {
                    SignView(app: app).environmentObject(store)
                }
            }
        }
    }
}

// MARK: - App Store View
struct AppStoreView: View {
    @EnvironmentObject var store: AppStore
    @State private var showAddSource = false

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(store.apps.filter { $0.ipaURL != "" }) { app in
                            StoreAppRow(app: app)
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("App Store")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showAddSource = true }) { Image(systemName: "line.3.horizontal.decrease.circle") }
                }
            }
            .sheet(isPresented: $showAddSource) {
                AddSourceView().environmentObject(store)
            }
        }
    }
}

struct StoreAppRow: View {
    @EnvironmentObject var store: AppStore
    let app: AppItem

    var body: some View {
        HStack(spacing: 14) {
            AppIconView(iconURL: app.iconURL, size: 60)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name).font(.system(size: 16, weight: .bold)).foregroundColor(.white)
                if let dev = app.developerName {
                    Text(dev).font(.system(size: 12)).foregroundColor(.gray)
                }
                if let size = app.size {
                    Text(size).font(.system(size: 11)).foregroundColor(.blue)
                }
            }
            Spacer()
            
            if store.isDownloading(app: app) {
                ZStack {
                    CircularProgressView(progress: store.downloadProgress(for: app) ?? 0)
                        .frame(width: 32, height: 32)
                }
            } else {
                Button(action: { store.download(app: app) }) {
                    Text("GET")
                        .font(.system(size: 13, weight: .black))
                        .foregroundColor(.blue)
                        .padding(.horizontal, 20).padding(.vertical, 6)
                        .background(Color.blue.opacity(0.15))
                        .cornerRadius(16)
                }
            }
        }
        .padding(12)
        .background(Color(white: 0.08))
        .cornerRadius(18)
    }
}

struct CircularProgressView: View {
    let progress: Double
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.1), lineWidth: 3)
            Circle().trim(from: 0, to: progress)
                .stroke(Color.blue, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
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
                if store.activeDownloads.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 56))
                            .foregroundStyle(.blue.opacity(0.6))
                        Text("No Downloads")
                            .font(.title3.bold())
                            .foregroundColor(.white)
                    }
                } else {
                    List(store.activeDownloads) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(item.name).foregroundColor(.white).font(.system(size: 15, weight: .semibold))
                                Spacer()
                                Text("\(Int(item.progress * 100))%").foregroundColor(.blue).font(.system(size: 12, weight: .bold))
                            }
                            ProgressView(value: item.progress)
                                .tint(.blue)
                            HStack {
                                Text(formatBytes(item.bytesReceived)).font(.system(size: 11)).foregroundColor(.gray)
                                Text("/").font(.system(size: 11)).foregroundColor(.gray)
                                Text(formatBytes(item.totalBytes)).font(.system(size: 11)).foregroundColor(.gray)
                            }
                        }
                        .padding(.vertical, 8)
                        .listRowBackground(Color(white: 0.08))
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Downloads")
        }
    }

    func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Settings View
struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @State private var showCerts = false

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                List {
                    Section {
                        Button(action: { showCerts = true }) {
                            SettingsRowContent(icon: "lock.shield.fill", iconColor: .purple, title: "Certificates")
                        }
                    } header: { Text("Management").foregroundColor(.gray) }
                    .listRowBackground(Color(white: 0.08))

                    Section {
                        SettingsRowContent(icon: "info.circle.fill", iconColor: .blue, title: "Version 1.0.0")
                        SettingsRowContent(icon: "heart.fill", iconColor: .red, title: "About MySigner")
                    } header: { Text("App").foregroundColor(.gray) }
                    .listRowBackground(Color(white: 0.08))
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showCerts) {
                CertificatesListView().environmentObject(store)
            }
        }
    }
}

// MARK: - Sign View
struct SignView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    let app: AppItem
    @State private var selectedCert: Certificate?
    @State private var isSigning = false
    @State private var errorMessage: String?
    @State private var showError = false

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(spacing: 24) {
                    AppIconView(iconURL: app.iconURL, size: 80)
                    VStack(spacing: 4) {
                        Text(app.name).font(.title2.bold()).foregroundColor(.white)
                        Text(app.bundleID).font(.subheadline).foregroundColor(.gray)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Select Certificate").font(.system(size: 14, weight: .bold)).foregroundColor(.gray).padding(.leading, 4)
                        if store.certificates.isEmpty {
                            NavigationLink(destination: CertificatesListView().environmentObject(store)) {
                                Text("No Certificates Found. Add one in Settings.")
                                    .font(.system(size: 14))
                                    .foregroundColor(.blue)
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(Color.blue.opacity(0.1))
                                    .cornerRadius(12)
                            }
                        } else {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(store.certificates) { cert in
                                        CertCard(cert: cert, isSelected: selectedCert?.id == cert.id)
                                            .onTapGesture { selectedCert = cert }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)

                    if isSigning {
                        VStack(spacing: 12) {
                            ProgressView()
                                .tint(.blue)
                            Text("Uploading & Signing...").font(.caption).foregroundColor(.gray)
                        }
                        .padding(.horizontal, 40)
                    }

                    Spacer()

                    Button(action: {
                        guard let cert = selectedCert else { return }
                        isSigning = true
                        store.signAndInstall(app: app, certificate: cert) { result in
                            isSigning = false
                            switch result {
                            case .success(let manifestUrl):
                                store.triggerInstallation(manifestUrl: manifestUrl)
                                dismiss()
                            case .failure(let error):
                                self.errorMessage = error.localizedDescription
                                self.showError = true
                            }
                        }
                    }) {
                        Text(isSigning ? "Signing..." : "Sign & Install")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(selectedCert != nil ? Color.blue : Color(white: 0.2))
                            .cornerRadius(16)
                    }
                    .disabled(selectedCert == nil || isSigning)
                    .padding(20)
                }
                .padding(.top, 20)
            }
            .navigationTitle("Sign App")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("Signing Error", isPresented: $showError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(errorMessage ?? "An unknown error occurred")
            }
        }
    }
}

struct CertCard: View {
    let cert: Certificate
    let isSelected: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "lock.shield.fill").foregroundColor(isSelected ? .white : .purple).font(.title2)
            Text(cert.name).font(.system(size: 14, weight: .bold)).foregroundColor(isSelected ? .white : .white).lineLimit(1)
            Text(cert.isValid ? "Valid" : "Expired").font(.system(size: 10)).foregroundColor(isSelected ? .white.opacity(0.8) : .gray)
        }
        .padding(12)
        .background(isSelected ? Color.blue : Color(white: 0.1))
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(isSelected ? Color.blue : Color.white.opacity(0.1), lineWidth: 2))
    }
}

// MARK: - Add Source View
struct AddSourceView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State private var url = ""
    @State private var isFetching = false

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(spacing: 20) {
                    TextField("Source URL (JSON)", text: $url)
                        .padding(14)
                        .background(Color(white: 0.1))
                        .cornerRadius(12)
                        .foregroundColor(.white)
                        .autocapitalization(.none)
                        .keyboardType(.URL)

                    Button(action: {
                        isFetching = true
                        let source = Source(name: "New Source", url: url)
                        store.fetch(source: source) { result in
                            isFetching = false
                            dismiss()
                        }
                    }) {
                        if isFetching {
                            ProgressView().tint(.white)
                        } else {
                            Text("Add Source").font(.system(size: 16, weight: .bold)).foregroundColor(.white)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.blue)
                    .cornerRadius(12)
                    .disabled(url.isEmpty || isFetching)

                    Spacer()
                }
                .padding(20)
            }
            .navigationTitle("Add Source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Certificates List View
struct CertificatesListView: View {
    @EnvironmentObject var store: AppStore
    @State private var showAddCert = false

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                if store.certificates.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "lock.shield")
                            .font(.system(size: 56))
                            .foregroundStyle(.purple.opacity(0.6))
                        Text("No Certificates")
                            .font(.title3.bold())
                            .foregroundColor(.white)
                        Button(action: { showAddCert = true }) {
                            Label("Add Certificate", systemImage: "plus.circle.fill")
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
}

// MARK: - Add Certificate View
struct AddCertificateView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State private var certName = ""
    @State private var certPassword = ""
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

                    SecureField("Certificate Password", text: $certPassword)
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
                        store.addCertificate(name: name, password: certPassword, p12URL: p12, provisionURL: provURL)
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
                    FilePicker(isPresented: $showP12Picker, allowedContentTypes: [.item]) { url in
                        p12URL = url
                    }
                    FilePicker(isPresented: $showProvPicker, allowedContentTypes: [.item]) { url in
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
