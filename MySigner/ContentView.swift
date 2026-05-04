import SwiftUI
import UniformTypeIdentifiers
import UIKit

// MARK: - Models

struct Certificate: Identifiable, Codable {
    let id: UUID
    var name: String
    var bundleID: String
    var expiryDate: Date
    var p12Data: Data?
    var provisionData: Data?

    init(id: UUID = UUID(), name: String, bundleID: String, expiryDate: Date, p12Data: Data? = nil, provisionData: Data? = nil) {
        self.id = id
        self.name = name
        self.bundleID = bundleID
        self.expiryDate = expiryDate
        self.p12Data = p12Data
        self.provisionData = provisionData
    }

    var daysLeft: Int {
        Calendar.current.dateComponents([.day], from: Date(), to: expiryDate).day ?? 0
    }
    var isValid: Bool { daysLeft > 0 }
}

struct AppItem: Identifiable, Codable {
    let id: UUID
    var name: String
    var version: String
    var bundleID: String
    var isSigned: Bool
    var fileURL: URL?
    var addedDate: Date

    init(id: UUID = UUID(), name: String, version: String, bundleID: String, isSigned: Bool = false, fileURL: URL? = nil, addedDate: Date = Date()) {
        self.id = id
        self.name = name
        self.version = version
        self.bundleID = bundleID
        self.isSigned = isSigned
        self.fileURL = fileURL
        self.addedDate = addedDate
    }
}

struct DownloadItem: Identifiable, Codable {
    let id: UUID
    var name: String
    var size: String
    var url: String
    var progress: Double
    var isCompleted: Bool
    var downloadedDate: Date?

    init(id: UUID = UUID(), name: String, size: String, url: String, progress: Double = 1.0, isCompleted: Bool = true, downloadedDate: Date? = Date()) {
        self.id = id
        self.name = name
        self.size = size
        self.url = url
        self.progress = progress
        self.isCompleted = isCompleted
        self.downloadedDate = downloadedDate
    }
}

struct Source: Identifiable, Codable {
    let id: UUID
    var name: String
    var url: String
    var appsCount: Int
    var addedDate: Date

    init(id: UUID = UUID(), name: String, url: String, appsCount: Int = 0, addedDate: Date = Date()) {
        self.id = id
        self.name = name
        self.url = url
        self.appsCount = appsCount
        self.addedDate = addedDate
    }
}

struct RepoApp: Identifiable {
    let id = UUID()
    var name: String
    var version: String
    var bundleID: String
    var description: String
    var downloadURL: String
    var size: String
}

// MARK: - AppStore (State)

class AppStore: ObservableObject {
    @Published var certificates: [Certificate] = []
    @Published var downloadedApps: [AppItem] = []
    @Published var signedApps: [AppItem] = []
    @Published var downloads: [DownloadItem] = []
    @Published var sources: [Source] = []
    @Published var repoApps: [RepoApp] = []
    @Published var activeDownloads: [UUID: Double] = [:]

    private let certsKey = "saved_certificates"
    private let appsKey = "saved_apps"
    private let signedKey = "signed_apps"
    private let downloadsKey = "saved_downloads"
    private let sourcesKey = "saved_sources"

    init() {
        loadAll()
        if sources.isEmpty {
            sources = [
                Source(name: "AppTesters IPA Repo", url: "https://repository.apptesters.org", appsCount: 312),
                Source(name: "CyPwn IPA Library", url: "https://ipa.cypwn.xyz/cypwn.json", appsCount: 87),
                Source(name: "SideStore Community", url: "https://community-apps.sidestore.io/sidecommunity.json", appsCount: 204),
                Source(name: "Znoj Repo", url: "https://raw.githubusercontent.com/ZZZ-NGE/repo/main/apps.json", appsCount: 14),
                Source(name: "iTorrent Source", url: "https://xitrix.github.io/iTorrent/AltStore.json", appsCount: 1),
            ]
            saveAll()
        }
    }

    func addCertificate(_ cert: Certificate) {
        certificates.append(cert)
        saveAll()
    }

    func removeCertificate(_ cert: Certificate) {
        certificates.removeAll { $0.id == cert.id }
        saveAll()
    }

    func addSource(_ source: Source) {
        guard !sources.contains(where: { $0.url == source.url }) else { return }
        sources.append(source)
        saveAll()
    }

    func removeSource(_ source: Source) {
        sources.removeAll { $0.id == source.id }
        saveAll()
    }

    func addDownloadedApp(_ app: AppItem) {
        downloadedApps.append(app)
        saveAll()
    }

    func signApp(_ app: AppItem, with cert: Certificate) -> AppItem {
        var signed = app
        signed.isSigned = true
        signedApps.append(signed)
        saveAll()
        return signed
    }

    func addDownload(_ item: DownloadItem) {
        downloads.append(item)
        saveAll()
    }

    func removeDownload(_ item: DownloadItem) {
        downloads.removeAll { $0.id == item.id }
        saveAll()
    }

    func removeApp(_ app: AppItem, from list: String) {
        if list == "downloaded" {
            downloadedApps.removeAll { $0.id == app.id }
        } else {
            signedApps.removeAll { $0.id == app.id }
        }
        saveAll()
    }

    private func saveAll() {
        if let d = try? JSONEncoder().encode(certificates) { UserDefaults.standard.set(d, forKey: certsKey) }
        if let d = try? JSONEncoder().encode(downloadedApps) { UserDefaults.standard.set(d, forKey: appsKey) }
        if let d = try? JSONEncoder().encode(signedApps) { UserDefaults.standard.set(d, forKey: signedKey) }
        if let d = try? JSONEncoder().encode(downloads) { UserDefaults.standard.set(d, forKey: downloadsKey) }
        if let d = try? JSONEncoder().encode(sources) { UserDefaults.standard.set(d, forKey: sourcesKey) }
    }

    private func loadAll() {
        if let d = UserDefaults.standard.data(forKey: certsKey), let v = try? JSONDecoder().decode([Certificate].self, from: d) { certificates = v }
        if let d = UserDefaults.standard.data(forKey: appsKey), let v = try? JSONDecoder().decode([AppItem].self, from: d) { downloadedApps = v }
        if let d = UserDefaults.standard.data(forKey: signedKey), let v = try? JSONDecoder().decode([AppItem].self, from: d) { signedApps = v }
        if let d = UserDefaults.standard.data(forKey: downloadsKey), let v = try? JSONDecoder().decode([DownloadItem].self, from: d) { downloads = v }
        if let d = UserDefaults.standard.data(forKey: sourcesKey), let v = try? JSONDecoder().decode([Source].self, from: d) { sources = v }
    }
}

// MARK: - Main Tab View

struct ContentView: View {
    @StateObject var store = AppStore()
    @State var selectedTab = 0

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

// MARK: - Files View (Document Picker Integration)

struct FilesView: View {
    @EnvironmentObject var store: AppStore
    @State var showPicker = false
    @State var importedFiles: [ImportedFile] = []
    @State var showRenameAlert = false
    @State var renameTarget: ImportedFile?
    @State var newName = ""
    @State var editMode: EditMode = .inactive

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                if importedFiles.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 56))
                            .foregroundColor(.gray.opacity(0.5))
                        Text("No files imported")
                            .foregroundColor(.gray)
                        Text("Tap + to import IPA or P12 files")
                            .foregroundColor(.gray.opacity(0.6))
                            .font(.caption)
                    }
                } else {
                    List {
                        ForEach(importedFiles) { file in
                            HStack(spacing: 14) {
                                Image(systemName: iconFor(file.type))
                                    .foregroundColor(colorFor(file.type))
                                    .font(.title2)
                                    .frame(width: 36)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(file.name)
                                        .foregroundColor(.white)
                                        .font(.body)
                                    Text("\(file.type.uppercased()) • \(file.sizeString)")
                                        .foregroundColor(.gray)
                                        .font(.caption)
                                }
                                Spacer()
                                if file.type == "ipa" {
                                    Button {
                                        importAsApp(file)
                                    } label: {
                                        Text("Import")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)
                                            .background(Color.blue)
                                            .clipShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 4)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    importedFiles.removeAll { $0.id == file.id }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button {
                                    renameTarget = file
                                    newName = file.name
                                    showRenameAlert = true
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                .tint(.orange)
                            }
                        }
                        .listRowBackground(Color.black)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .environment(\.editMode, $editMode)
                }
            }
            .navigationTitle("Files")
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button { showPicker = true } label: {
                        Image(systemName: "plus")
                    }
                    if !importedFiles.isEmpty {
                        Button {
                            editMode = editMode == .active ? .inactive : .active
                        } label: {
                            Text(editMode == .active ? "Done" : "Edit")
                        }
                    }
                }
            }
            .sheet(isPresented: $showPicker) {
                DocumentPickerView(allowedTypes: [.init(filenameExtension: "ipa")!, .init(filenameExtension: "p12")!, .init(filenameExtension: "mobileprovision")!]) { urls in
                    for url in urls {
                        let name = url.lastPathComponent
                        let ext = url.pathExtension.lowercased()
                        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                        let file = ImportedFile(name: name, type: ext, size: size, url: url)
                        if !importedFiles.contains(where: { $0.name == name }) {
                            importedFiles.append(file)
                        }
                    }
                }
            }
            .alert("Rename File", isPresented: $showRenameAlert) {
                TextField("Name", text: $newName)
                Button("Rename") {
                    if let target = renameTarget, let i = importedFiles.firstIndex(where: { $0.id == target.id }) {
                        importedFiles[i].name = newName
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    func importAsApp(_ file: ImportedFile) {
        let app = AppItem(
            name: file.name.replacingOccurrences(of: ".ipa", with: ""),
            version: "1.0",
            bundleID: "com.imported.\(file.name.replacingOccurrences(of: ".ipa", with: "").lowercased())",
            fileURL: file.url
        )
        store.addDownloadedApp(app)
    }

    func iconFor(_ type: String) -> String {
        switch type {
        case "ipa": return "app.fill"
        case "p12": return "lock.fill"
        case "mobileprovision": return "doc.badge.gearshape.fill"
        default: return "doc.fill"
        }
    }

    func colorFor(_ type: String) -> Color {
        switch type {
        case "ipa": return .blue
        case "p12": return .orange
        case "mobileprovision": return .green
        default: return .gray
        }
    }
}

struct ImportedFile: Identifiable {
    let id = UUID()
    var name: String
    var type: String
    var size: Int
    var url: URL?

    var sizeString: String {
        let mb = Double(size) / 1_048_576
        if mb < 1 { return String(format: "%.0f KB", Double(size) / 1024) }
        return String(format: "%.1f MB", mb)
    }
}

struct DocumentPickerView: UIViewControllerRepresentable {
    let allowedTypes: [UTType]
    let onPick: ([URL]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: allowedTypes, asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }
    }
}

// MARK: - Library View

struct LibraryView: View {
    @EnvironmentObject var store: AppStore
    @State var tab = 0
    @State var showImportPicker = false
    @State var showSignSheet = false
    @State var selectedApp: AppItem?

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
                    .padding(.horizontal)
                    .padding(.top, 8)

                    if tab == 0 {
                        appList(apps: store.downloadedApps, listType: "downloaded")
                    } else {
                        appList(apps: store.signedApps, listType: "signed")
                    }
                }
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Edit") {}
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showImportPicker = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showImportPicker) {
                DocumentPickerView(allowedTypes: [.init(filenameExtension: "ipa")!]) { urls in
                    for url in urls {
                        let name = url.lastPathComponent.replacingOccurrences(of: ".ipa", with: "")
                        let app = AppItem(name: name, version: "1.0", bundleID: "com.imported.\(name.lowercased())", fileURL: url)
                        store.addDownloadedApp(app)
                    }
                }
            }
            .sheet(item: $selectedApp) { app in
                SignAppSheet(app: app)
            }
        }
    }

    func appList(apps: [AppItem], listType: String) -> some View {
        Group {
            if apps.isEmpty {
                ZStack {
                    Color.black
                    VStack(spacing: 12) {
                        Image(systemName: listType == "signed" ? "signature" : "app.badge")
                            .font(.system(size: 48))
                            .foregroundColor(.gray.opacity(0.4))
                        Text(listType == "signed" ? "No Signed Apps" : "No Downloaded Apps")
                            .foregroundColor(.gray)
                        Text(listType == "downloaded" ? "Tap + to import an IPA file" : "Sign an app from Downloaded Apps")
                            .foregroundColor(.gray.opacity(0.6))
                            .font(.caption)
                    }
                }
            } else {
                List {
                    Section(header: HStack {
                        Text(listType == "signed" ? "Signed Apps" : "Downloaded Apps")
                            .foregroundColor(.white).font(.headline).bold()
                        Spacer()
                        Text("\(apps.count)")
                            .foregroundColor(.white).font(.caption)
                            .padding(6)
                            .background(Color.gray.opacity(0.4))
                            .clipShape(Circle())
                    }.listRowInsets(EdgeInsets())) {
                        ForEach(apps) { app in
                            NavigationLink(destination: AppDetailView(app: app)) {
                                HStack(spacing: 14) {
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color.blue.opacity(0.15))
                                        .frame(width: 52, height: 52)
                                        .overlay(Image(systemName: "app.fill").foregroundColor(.blue).font(.title2))
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(app.name).foregroundColor(.white).font(.body)
                                        Text("\(app.version) • \(app.bundleID)").foregroundColor(.gray).font(.caption)
                                    }
                                    Spacer()
                                    if app.isSigned {
                                        Image(systemName: "checkmark.seal.fill").foregroundColor(.green).font(.caption)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    store.removeApp(app, from: listType)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                if listType == "downloaded" && !store.certificates.isEmpty {
                                    Button {
                                        selectedApp = app
                                        showSignSheet = true
                                    } label: {
                                        Label("Sign", systemImage: "signature")
                                    }
                                    .tint(.blue)
                                }
                            }
                            .listRowBackground(Color.black)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }
}

struct AppDetailView: View {
    @EnvironmentObject var store: AppStore
    let app: AppItem
    @State var showSign = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 20) {
                RoundedRectangle(cornerRadius: 22)
                    .fill(Color.blue.opacity(0.15))
                    .frame(width: 90, height: 90)
                    .overlay(Image(systemName: "app.fill").foregroundColor(.blue).font(.system(size: 40)))

                VStack(spacing: 6) {
                    Text(app.name).foregroundColor(.white).font(.title2.bold())
                    Text(app.bundleID).foregroundColor(.gray).font(.subheadline)
                    Text("Version \(app.version)").foregroundColor(.gray).font(.caption)
                }

                if app.isSigned {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
                        Text("Signed").foregroundColor(.green).font(.subheadline.bold())
                    }
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(Color.green.opacity(0.15)).cornerRadius(12)
                }

                if !app.isSigned && !store.certificates.isEmpty {
                    Button {
                        showSign = true
                    } label: {
                        Label("Sign App", systemImage: "signature")
                            .font(.body.bold())
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.blue)
                            .cornerRadius(14)
                    }
                    .padding(.horizontal)
                } else if store.certificates.isEmpty {
                    Text("Add a certificate in Settings to sign this app")
                        .foregroundColor(.gray)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Spacer()
            }
            .padding(.top, 30)
        }
        .navigationTitle(app.name)
        .sheet(isPresented: $showSign) {
            SignAppSheet(app: app)
        }
    }
}

struct SignAppSheet: View {
    @EnvironmentObject var store: AppStore
    let app: AppItem
    @Environment(\.dismiss) var dismiss
    @State var selectedCert: Certificate?
    @State var isSigning = false
    @State var signSuccess = false

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(spacing: 20) {
                    if signSuccess {
                        VStack(spacing: 16) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 64))
                                .foregroundColor(.green)
                            Text("Signed Successfully!")
                                .foregroundColor(.white)
                                .font(.title2.bold())
                            Text("\(app.name) has been signed and moved to Signed Apps.")
                                .foregroundColor(.gray)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                            Button("Done") { dismiss() }
                                .font(.body.bold())
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color.green)
                                .cornerRadius(14)
                                .padding(.horizontal)
                        }
                    } else {
                        Text("Select Certificate")
                            .foregroundColor(.white)
                            .font(.headline)
                            .padding(.top)

                        List(store.certificates) { cert in
                            Button {
                                selectedCert = cert
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(cert.name).foregroundColor(.white)
                                        Text("\(cert.daysLeft) days left • \(cert.bundleID)")
                                            .foregroundColor(.gray)
                                            .font(.caption)
                                    }
                                    Spacer()
                                    if selectedCert?.id == cert.id {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.blue)
                                    }
                                }
                            }
                            .listRowBackground(Color(white: 0.1))
                        }
                        .listStyle(.insetGrouped)
                        .scrollContentBackground(.hidden)

                        if isSigning {
                            ProgressView("Signing...").tint(.blue).foregroundColor(.white)
                        } else {
                            Button {
                                guard selectedCert != nil else { return }
                                isSigning = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                                    _ = store.signApp(app, with: selectedCert!)
                                    isSigning = false
                                    signSuccess = true
                                }
                            } label: {
                                Text(selectedCert == nil ? "Select a Certificate" : "Sign Now")
                                    .font(.body.bold())
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                                    .background(selectedCert == nil ? Color.gray.opacity(0.4) : Color.blue)
                                    .cornerRadius(14)
                            }
                            .disabled(selectedCert == nil)
                            .padding(.horizontal)
                        }
                        Spacer()
                    }
                }
            }
            .navigationTitle("Sign \(app.name)")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - App Store View

struct AppStoreView: View {
    @EnvironmentObject var store: AppStore
    @State var showSources = false
    @State var searchText = ""
    @State var loadingSourceApps = false

    let featuredApps: [RepoApp] = [
        RepoApp(name: "AlightMotion", version: "6.2.53", bundleID: "com.alightcreative.motion", description: "Injected • Premium Unlocked", downloadURL: "", size: "125.6 MB"),
        RepoApp(name: "Documents by Readdle", version: "8.19.13", bundleID: "com.readdle.smartdocuments", description: "Injected • Plus Unlocked", downloadURL: "", size: "343.4 MB"),
        RepoApp(name: "FL Studio Mobile", version: "4.10.0", bundleID: "com.imageline.flmobile", description: "Injected • IAP Unlocked", downloadURL: "", size: "412.3 MB"),
        RepoApp(name: "Simply Guitar", version: "10.19", bundleID: "com.joytunes.simpleguitar", description: "Injected • Subscription Free", downloadURL: "", size: "218.7 MB"),
        RepoApp(name: "UpNote", version: "9.18.5", bundleID: "com.guizhou.ubnote", description: "Injected • Premium Unlocked", downloadURL: "", size: "98.2 MB"),
        RepoApp(name: "Busuu", version: "30.12.0", bundleID: "com.busuu.busuu", description: "Injected • Premium Unlocked", downloadURL: "", size: "187.4 MB"),
        RepoApp(name: "PhoneDiagnostics", version: "4.1.1", bundleID: "com.phonecheck.diagapp", description: "Injected • IAP Unlocked", downloadURL: "", size: "33.1 MB"),
    ]

    var filtered: [RepoApp] {
        searchText.isEmpty ? featuredApps : featuredApps.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                List {
                    Section(header: Text("\(featuredApps.count * store.sources.count) Apps").foregroundColor(.gray).font(.subheadline)) {
                        ForEach(filtered) { app in
                            NavigationLink(destination: RepoAppDetailView(app: app)) {
                                HStack(spacing: 14) {
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color.gray.opacity(0.2))
                                        .frame(width: 52, height: 52)
                                        .overlay(Image(systemName: "app").foregroundColor(.gray).font(.title3))
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(app.name).foregroundColor(.white).font(.body)
                                        Text("\(app.version) • \(app.description)").foregroundColor(.gray).font(.caption)
                                        Text(app.size).foregroundColor(.gray.opacity(0.7)).font(.caption2)
                                    }
                                    Spacer()
                                    GetButton(app: app)
                                }
                                .padding(.vertical, 4)
                            }
                            .listRowBackground(Color.black)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("App Store")
            .searchable(text: $searchText, prompt: "Search apps")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Sources") { showSources = true }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showSources = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showSources) { SourcesView() }
        }
    }
}

struct GetButton: View {
    @EnvironmentObject var store: AppStore
    let app: RepoApp
    @State var state: ButtonState = .idle

    enum ButtonState { case idle, loading, done }

    var body: some View {
        Button {
            guard state == .idle else { return }
            state = .loading
            DispatchQueue.main.asyncAfter(deadline: .now() + Double.random(in: 1.2...2.5)) {
                let dl = DownloadItem(name: app.name, size: app.size, url: app.downloadURL)
                store.addDownload(dl)
                state = .done
            }
        } label: {
            Group {
                switch state {
                case .idle:
                    Text("Get")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 18).padding(.vertical, 7)
                        .background(Color.gray.opacity(0.3))
                        .clipShape(Capsule())
                case .loading:
                    ProgressView().tint(.blue)
                        .frame(width: 52, height: 28)
                case .done:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .frame(width: 52, height: 28)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

struct RepoAppDetailView: View {
    @EnvironmentObject var store: AppStore
    let app: RepoApp
    @State var downloaded = false
    @State var downloading = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 24) {
                    RoundedRectangle(cornerRadius: 22)
                        .fill(Color.gray.opacity(0.2))
                        .frame(width: 100, height: 100)
                        .overlay(Image(systemName: "app").foregroundColor(.gray).font(.system(size: 44)))

                    VStack(spacing: 6) {
                        Text(app.name).foregroundColor(.white).font(.title2.bold())
                        Text(app.bundleID).foregroundColor(.gray).font(.subheadline)
                        Text(app.description).foregroundColor(.blue).font(.caption)
                    }

                    HStack(spacing: 30) {
                        VStack {
                            Text(app.version).foregroundColor(.white).font(.subheadline.bold())
                            Text("Version").foregroundColor(.gray).font(.caption)
                        }
                        Divider().frame(height: 30)
                        VStack {
                            Text(app.size).foregroundColor(.white).font(.subheadline.bold())
                            Text("Size").foregroundColor(.gray).font(.caption)
                        }
                    }
                    .padding()
                    .background(Color(white: 0.1))
                    .cornerRadius(14)

                    Button {
                        guard !downloading && !downloaded else { return }
                        downloading = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            let dl = DownloadItem(name: app.name, size: app.size, url: app.downloadURL)
                            store.addDownload(dl)
                            downloading = false
                            downloaded = true
                        }
                    } label: {
                        HStack {
                            if downloading {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: downloaded ? "checkmark" : "arrow.down.app")
                                Text(downloaded ? "Downloaded" : "Download")
                            }
                        }
                        .font(.body.bold())
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(downloaded ? Color.green : Color.blue)
                        .cornerRadius(14)
                    }
                    .padding(.horizontal)

                    Spacer()
                }
                .padding(.top, 30)
            }
        }
        .navigationTitle(app.name)
    }
}

struct SourcesView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State var showAddSource = false
    @State var newURL = ""
    @State var newName = ""
    @State var addError = ""

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                List {
                    Section(header: HStack {
                        Text("Repositories").foregroundColor(.white).font(.headline).bold()
                        Spacer()
                        Text("\(store.sources.count)")
                            .foregroundColor(.white).font(.caption)
                            .padding(6).background(Color.gray.opacity(0.4)).clipShape(Circle())
                    }) {
                        ForEach(store.sources) { src in
                            HStack(spacing: 14) {
                                RoundedRectangle(cornerRadius: 12).fill(Color.blue.opacity(0.15))
                                    .frame(width: 44, height: 44)
                                    .overlay(Image(systemName: "globe").foregroundColor(.blue))
                                VStack(alignment: .leading) {
                                    Text(src.name).foregroundColor(.white)
                                    Text(src.url).foregroundColor(.gray).font(.caption).lineLimit(1)
                                    if src.appsCount > 0 {
                                        Text("\(src.appsCount) apps").foregroundColor(.blue).font(.caption2)
                                    }
                                }
                                Spacer()
                                Button {
                                    if let url = URL(string: src.url) { UIApplication.shared.open(url) }
                                } label: {
                                    Image(systemName: "safari").foregroundColor(.gray)
                                }
                            }
                            .listRowBackground(Color.black)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    store.removeSource(src)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Sources")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showAddSource = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAddSource) {
                AddSourceSheet(isPresented: $showAddSource)
            }
        }
    }
}

struct AddSourceSheet: View {
    @EnvironmentObject var store: AppStore
    @Binding var isPresented: Bool
    @State var url = ""
    @State var name = ""
    @State var isLoading = false
    @State var error = ""

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Repository Name").foregroundColor(.gray).font(.caption)
                        TextField("e.g. My IPA Repo", text: $name)
                            .foregroundColor(.white)
                            .padding(12)
                            .background(Color(white: 0.1))
                            .cornerRadius(10)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Repository URL").foregroundColor(.gray).font(.caption)
                        TextField("https://example.com/apps.json", text: $url)
                            .foregroundColor(.white)
                            .autocapitalization(.none)
                            .keyboardType(.URL)
                            .padding(12)
                            .background(Color(white: 0.1))
                            .cornerRadius(10)
                    }
                    if !error.isEmpty {
                        Text(error).foregroundColor(.red).font(.caption)
                    }
                    if isLoading {
                        ProgressView("Validating URL...").tint(.blue).foregroundColor(.white)
                    } else {
                        Button {
                            addSource()
                        } label: {
                            Text("Add Source")
                                .font(.body.bold())
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(url.isEmpty || name.isEmpty ? Color.gray.opacity(0.4) : Color.blue)
                                .cornerRadius(14)
                        }
                        .disabled(url.isEmpty || name.isEmpty)
                    }
                    Spacer()
                }
                .padding()
            }
            .navigationTitle("Add Source")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { isPresented = false }
                }
            }
        }
    }

    func addSource() {
        guard !url.isEmpty, !name.isEmpty else { return }
        guard let _ = URL(string: url), url.hasPrefix("http") else {
            error = "Invalid URL format. Must start with https://"
            return
        }
        isLoading = true
        error = ""
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            store.addSource(Source(name: name, url: url))
            isLoading = false
            isPresented = false
        }
    }
}

// MARK: - Downloads View

struct DownloadsView: View {
    @EnvironmentObject var store: AppStore
    @State var searchText = ""

    var filtered: [DownloadItem] {
        searchText.isEmpty ? store.downloads : store.downloads.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                if store.downloads.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "arrow.down.app")
                            .font(.system(size: 52))
                            .foregroundColor(.gray.opacity(0.4))
                        Text("No Downloads")
                            .foregroundColor(.gray)
                        Text("Downloaded apps will appear here")
                            .foregroundColor(.gray.opacity(0.6))
                            .font(.caption)
                    }
                } else {
                    List {
                        Section(header: HStack {
                            Text("Downloaded")
                                .foregroundColor(.white).font(.headline).bold()
                            Spacer()
                            Text("\(store.downloads.count)")
                                .foregroundColor(.white).font(.caption)
                                .padding(6).background(Color.gray.opacity(0.4)).clipShape(Circle())
                        }) {
                            ForEach(filtered) { item in
                                HStack(spacing: 14) {
                                    Image(systemName: "doc.zipper")
                                        .font(.title2).foregroundColor(.blue)
                                        .frame(width: 44, height: 44)
                                        .background(Color.blue.opacity(0.1)).cornerRadius(10)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.name)
                                            .foregroundColor(.white).font(.body).lineLimit(1)
                                        Text(item.size)
                                            .foregroundColor(.gray).font(.caption)
                                        if let date = item.downloadedDate {
                                            Text(date, style: .date)
                                                .foregroundColor(.gray.opacity(0.7)).font(.caption2)
                                        }
                                    }
                                    Spacer()
                                    Button {
                                        importToLibrary(item)
                                    } label: {
                                        Image(systemName: "arrow.up.app")
                                            .foregroundColor(.blue)
                                    }
                                }
                                .padding(.vertical, 4)
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        store.removeDownload(item)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                                .listRowBackground(Color.black)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Downloads")
            .searchable(text: $searchText, prompt: "Search downloads")
        }
    }

    func importToLibrary(_ item: DownloadItem) {
        let app = AppItem(name: item.name, version: "1.0", bundleID: "com.download.\(item.name.lowercased().replacingOccurrences(of: " ", with: "."))")
        store.addDownloadedApp(app)
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @State var showLogs = false
    @State var showSigningOptions = false
    @State var showAbout = false

    let telegramURL = "https://t.me/"
    let githubURL = "https://github.com/ZZZ-NGE"
    let discordURL = "https://discord.com/"
    let donateURL = "https://www.buymeacoffee.com/"

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                List {
                    Section {
                        VStack(spacing: 12) {
                            Image(systemName: "person.crop.circle.fill")
                                .font(.system(size: 48)).foregroundColor(.gray)
                            Text("Donations").font(.title2.bold()).foregroundColor(.white)
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "heart.fill").foregroundColor(.blue).font(.title3)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Show Your Support").foregroundColor(.white).font(.subheadline.bold())
                                    Text("Show your support by donating! If you're unable to donate, spreading the word works too!")
                                        .foregroundColor(.gray).font(.caption)
                                }
                            }
                            Button {
                                if let url = URL(string: donateURL) { UIApplication.shared.open(url) }
                            } label: {
                                Text("Donate")
                                    .font(.body.bold()).foregroundColor(.white)
                                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                                    .background(Color.blue).cornerRadius(12)
                            }
                        }
                        .padding(.vertical, 8)
                        .listRowBackground(Color(white: 0.12))
                    }

                    Section {
                        Button {
                            showAbout = true
                        } label: {
                            SettingsRowContent(icon: "info.circle", iconColor: .blue, title: "About")
                        }
                        .listRowBackground(Color(white: 0.12))

                        Button {
                            if let url = URL(string: telegramURL) { UIApplication.shared.open(url) }
                        } label: {
                            SettingsRowContent(icon: "paperplane.fill", iconColor: .blue, title: "Telegram Channel", isBlue: true)
                        }
                        .listRowBackground(Color(white: 0.12))

                        Button {
                            if let url = URL(string: githubURL) { UIApplication.shared.open(url) }
                        } label: {
                            SettingsRowContent(icon: "safari.fill", iconColor: .blue, title: "GitHub Repository", isBlue: true)
                        }
                        .listRowBackground(Color(white: 0.12))

                        Button {
                            if let url = URL(string: discordURL) { UIApplication.shared.open(url) }
                        } label: {
                            SettingsRowContent(icon: "safari.fill", iconColor: .blue, title: "Discord Server", isBlue: true)
                        }
                        .listRowBackground(Color(white: 0.12))
                    }

                    Section(header: Text("Features").foregroundColor(.white).font(.headline).bold()) {
                        Button { showLogs = true } label: {
                            SettingsRowContent(icon: "terminal.fill", iconColor: .blue, title: "Logs")
                        }
                        .listRowBackground(Color(white: 0.12))

                        NavigationLink(destination: CertificatesView()) {
                            SettingsRowContent(icon: "signature", iconColor: .blue, title: "Certificates")
                        }
                        .listRowBackground(Color(white: 0.12))

                        Button { showSigningOptions = true } label: {
                            SettingsRowContent(icon: "gearshape.fill", iconColor: .blue, title: "Signing Options")
                        }
                        .listRowBackground(Color(white: 0.12))
                    }
                    .listRowBackground(Color(white: 0.12))

                    Section(header: Text("Misc").foregroundColor(.white).font(.headline).bold()) {
                        Button {
                            if let url = URL(string: "shareddocuments://") { UIApplication.shared.open(url) }
                        } label: {
                            SettingsRowContent(icon: "folder.fill", iconColor: .blue, title: "Open Documents", isBlue: true)
                        }
                        .listRowBackground(Color(white: 0.12))
                    }

                    Section {
                        Button(role: .destructive) {
                            resetAll()
                        } label: {
                            HStack {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.2)).frame(width: 32, height: 32)
                                    Image(systemName: "trash.fill").foregroundColor(.red).font(.system(size: 15))
                                }
                                Text("Reset All Data").foregroundColor(.red)
                            }
                        }
                        .listRowBackground(Color(white: 0.12))
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showLogs) { LogsView() }
            .sheet(isPresented: $showSigningOptions) { SigningOptionsView() }
            .sheet(isPresented: $showAbout) { AboutView() }
        }
    }

    func resetAll() {
        store.certificates.removeAll()
        store.downloadedApps.removeAll()
        store.signedApps.removeAll()
        store.downloads.removeAll()
        UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier ?? "")
    }
}

struct SettingsRowContent: View {
    let icon: String; let iconColor: Color; let title: String; var isBlue: Bool = false
    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(iconColor.opacity(0.2)).frame(width: 32, height: 32)
                Image(systemName: icon).foregroundColor(iconColor).font(.system(size: 15))
            }
            Text(title).foregroundColor(isBlue ? .blue : .white)
            Spacer()
        }
    }
}

struct LogsView: View {
    @Environment(\.dismiss) var dismiss
    let logs = [
        "[\(Date().formatted(date: .omitted, time: .standard))] App launched",
        "[\(Date().formatted(date: .omitted, time: .standard))] AppStore initialized",
        "[\(Date().formatted(date: .omitted, time: .standard))] Sources loaded from storage",
        "[\(Date().formatted(date: .omitted, time: .standard))] UI ready",
    ]

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(logs, id: \.self) { log in
                            Text(log)
                                .foregroundColor(.green)
                                .font(.system(.caption, design: .monospaced))
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("Logs")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct SigningOptionsView: View {
    @Environment(\.dismiss) var dismiss
    @AppStorage("signing_forceOriginalID") var forceOriginalID = false
    @AppStorage("signing_removeSupportedDevices") var removeSupportedDevices = true
    @AppStorage("signing_enableFileSharingEnabled") var enableFileSharing = true
    @AppStorage("signing_removeURLScheme") var removeURLScheme = false

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                List {
                    Section(header: Text("Bundle ID").foregroundColor(.gray)) {
                        Toggle("Force Original Bundle ID", isOn: $forceOriginalID)
                            .foregroundColor(.white)
                            .listRowBackground(Color(white: 0.12))
                    }
                    Section(header: Text("Entitlements").foregroundColor(.gray)) {
                        Toggle("Remove Supported Devices", isOn: $removeSupportedDevices)
                            .foregroundColor(.white)
                            .listRowBackground(Color(white: 0.12))
                        Toggle("Enable File Sharing", isOn: $enableFileSharing)
                            .foregroundColor(.white)
                            .listRowBackground(Color(white: 0.12))
                        Toggle("Remove URL Schemes", isOn: $removeURLScheme)
                            .foregroundColor(.white)
                            .listRowBackground(Color(white: 0.12))
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Signing Options")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct AboutView: View {
    @Environment(\.dismiss) var dismiss
    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(spacing: 24) {
                    Image(systemName: "signature")
                        .font(.system(size: 72))
                        .foregroundColor(.blue)
                    Text("MySigner").font(.largeTitle.bold()).foregroundColor(.white)
                    Text("Version 1.0").foregroundColor(.gray)
                    Text("A powerful IPA signing tool for iOS.\nSign your apps with your own certificates.")
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Spacer()
                }
                .padding(.top, 50)
            }
            .navigationTitle("About")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Certificates View

struct CertificatesView: View {
    @EnvironmentObject var store: AppStore
    @State var showAddCert = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if store.certificates.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "signature")
                        .font(.system(size: 52))
                        .foregroundColor(.gray.opacity(0.4))
                    Text("No Certificates").foregroundColor(.gray)
                    Text("Tap + to add a P12 certificate and\na MobileProvision profile").foregroundColor(.gray.opacity(0.6)).font(.caption).multilineTextAlignment(.center)
                }
            } else {
                ScrollView {
                    VStack(spacing: 14) {
                        ForEach(store.certificates) { cert in
                            CertCard(cert: cert)
                                .swipeActions {}
                                .contextMenu {
                                    Button(role: .destructive) {
                                        store.removeCertificate(cert)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("Certificates")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showAddCert = true } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddCert) {
            AddCertificateSheet(isPresented: $showAddCert)
        }
    }
}

struct AddCertificateSheet: View {
    @EnvironmentObject var store: AppStore
    @Binding var isPresented: Bool
    @State var certName = ""
    @State var bundleID = ""
    @State var expiryDate = Calendar.current.date(byAdding: .day, value: 365, to: Date()) ?? Date()
    @State var showP12Picker = false
    @State var showProvisionPicker = false
    @State var p12Picked = false
    @State var provisionPicked = false
    @State var p12Data: Data?
    @State var provisionData: Data?

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 20) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Certificate Name").foregroundColor(.gray).font(.caption)
                            TextField("e.g. My Developer Certificate", text: $certName)
                                .foregroundColor(.white)
                                .padding(12)
                                .background(Color(white: 0.1))
                                .cornerRadius(10)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Bundle ID").foregroundColor(.gray).font(.caption)
                            TextField("com.example.app or *", text: $bundleID)
                                .foregroundColor(.white)
                                .autocapitalization(.none)
                                .padding(12)
                                .background(Color(white: 0.1))
                                .cornerRadius(10)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Expiry Date").foregroundColor(.gray).font(.caption)
                            DatePicker("", selection: $expiryDate, in: Date()..., displayedComponents: .date)
                                .labelsHidden()
                                .colorScheme(.dark)
                        }

                        Button {
                            showP12Picker = true
                        } label: {
                            HStack {
                                Image(systemName: p12Picked ? "checkmark.circle.fill" : "lock.fill")
                                    .foregroundColor(p12Picked ? .green : .orange)
                                Text(p12Picked ? "P12 File Selected ✓" : "Select P12 File")
                                    .foregroundColor(p12Picked ? .green : .white)
                                Spacer()
                                Image(systemName: "chevron.right").foregroundColor(.gray).font(.caption)
                            }
                            .padding(14)
                            .background(Color(white: 0.1))
                            .cornerRadius(10)
                        }

                        Button {
                            showProvisionPicker = true
                        } label: {
                            HStack {
                                Image(systemName: provisionPicked ? "checkmark.circle.fill" : "doc.badge.gearshape.fill")
                                    .foregroundColor(provisionPicked ? .green : .blue)
                                Text(provisionPicked ? "Provision Selected ✓" : "Select MobileProvision")
                                    .foregroundColor(provisionPicked ? .green : .white)
                                Spacer()
                                Image(systemName: "chevron.right").foregroundColor(.gray).font(.caption)
                            }
                            .padding(14)
                            .background(Color(white: 0.1))
                            .cornerRadius(10)
                        }

                        Button {
                            addCertificate()
                        } label: {
                            Text("Add Certificate")
                                .font(.body.bold())
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(canAdd ? Color.blue : Color.gray.opacity(0.4))
                                .cornerRadius(14)
                        }
                        .disabled(!canAdd)
                    }
                    .padding()
                }
            }
            .navigationTitle("Add Certificate")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { isPresented = false }
                }
            }
            .sheet(isPresented: $showP12Picker) {
                DocumentPickerView(allowedTypes: [.init(filenameExtension: "p12")!]) { urls in
                    if let url = urls.first, let data = try? Data(contentsOf: url) {
                        p12Data = data
                        p12Picked = true
                    }
                }
            }
            .sheet(isPresented: $showProvisionPicker) {
                DocumentPickerView(allowedTypes: [.init(filenameExtension: "mobileprovision")!]) { urls in
                    if let url = urls.first, let data = try? Data(contentsOf: url) {
                        provisionData = data
                        provisionPicked = true
                    }
                }
            }
        }
    }

    var canAdd: Bool { !certName.isEmpty && !bundleID.isEmpty && p12Picked && provisionPicked }

    func addCertificate() {
        let cert = Certificate(name: certName, bundleID: bundleID, expiryDate: expiryDate, p12Data: p12Data, provisionData: provisionData)
        store.addCertificate(cert)
        isPresented = false
    }
}

struct CertCard: View {
    @EnvironmentObject var store: AppStore
    let cert: Certificate

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(cert.name).foregroundColor(.white).font(.body.bold())
            Text(cert.bundleID).foregroundColor(.gray).font(.caption)
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: cert.isValid ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(cert.isValid ? .green : .red)
                    Text(cert.isValid ? "Valid" : "Expired")
                        .foregroundColor(.white).font(.subheadline.bold())
                }
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .background((cert.isValid ? Color.green : Color.red).opacity(0.15)).cornerRadius(10)

                HStack(spacing: 6) {
                    Image(systemName: "clock.fill")
                        .foregroundColor(cert.daysLeft > 30 ? .yellow : .red)
                    Text(cert.daysLeft > 0 ? "\(cert.daysLeft) days" : "Expired")
                        .foregroundColor(.white).font(.subheadline.bold())
                }
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .background((cert.daysLeft > 30 ? Color.yellow : Color.red).opacity(0.15)).cornerRadius(10)
            }
        }
        .padding(16)
        .background(Color(white: 0.1))
        .cornerRadius(14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(cert.isValid ? Color.blue.opacity(0.6) : Color.red.opacity(0.4), lineWidth: 1.5))
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View { ContentView() }
}
