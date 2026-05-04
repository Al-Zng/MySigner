import SwiftUI
import UniformTypeIdentifiers

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

// MARK: - Global State
class AppStore: ObservableObject {
    @Published var certificates: [Certificate] = []
    @Published var downloadedApps: [AppItem] = []
    @Published var signedApps: [AppItem] = []
    @Published var downloads: [DownloadItem] = []
    @Published var sources: [Source] = [
        Source(name: "AppTesters IPA Repo", url: "https://repository.apptesters.org"),
        Source(name: "CyPwn IPA Library", url: "https://ipa.cypwn.xyz/cypwn.json"),
    ]
}

// MARK: - Models
struct Certificate: Identifiable {
    let id = UUID()
    var name: String
    var bundleID: String
    var daysLeft: Int
    var isValid: Bool
    var p12URL: URL?
    var provisionURL: URL?
}

struct AppItem: Identifiable {
    let id = UUID()
    var name: String
    var version: String
    var bundleID: String
    var ipaURL: URL?
    var signedDate: Date?
}

struct DownloadItem: Identifiable {
    let id = UUID()
    var name: String
    var size: String
    var url: URL?
    var progress: Double = 1.0
}

struct Source: Identifiable {
    let id = UUID()
    var name: String
    var url: String
}

// MARK: - Files View
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

// MARK: - Library View
struct LibraryView: View {
    @EnvironmentObject var store: AppStore
    @State var tab = 0
    @State var showSigner = false
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

                    let apps = tab == 0 ? store.downloadedApps : store.signedApps
                    if apps.isEmpty {
                        Spacer()
                        VStack(spacing: 10) {
                            Image(systemName: "tray")
                                .font(.system(size: 44))
                                .foregroundColor(.gray)
                            Text(tab == 0 ? "No Downloaded Apps" : "No Signed Apps")
                                .foregroundColor(.gray)
                        }
                        Spacer()
                    } else {
                        List {
                            Section(header: HStack {
                                Text(tab == 0 ? "Downloaded Apps" : "Signed Apps")
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
                                .onDelete { idx in
                                    if tab == 0 { store.downloadedApps.remove(atOffsets: idx) }
                                    else { store.signedApps.remove(atOffsets: idx) }
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

// MARK: - Signer Sheet
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
    @State private var pickingType: PickType? = nil

    enum PickType: Identifiable {
        case ipa, p12, provision
        var id: Int { switch self { case .ipa: return 0; case .p12: return 1; case .provision: return 2 } }
    }

    var allSelected: Bool { ipaURL != nil && p12URL != nil && provisionURL != nil }

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 20) {
                        VStack(spacing: 12) {
                            FilePickerRow(
                                icon: "archivebox.fill",
                                title: "IPA File",
                                subtitle: ipaURL?.lastPathComponent ?? "اختر ملف .ipa",
                                color: .blue,
                                isSelected: ipaURL != nil
                            ) { pickingType = .ipa }

                            FilePickerRow(
                                icon: "lock.shield.fill",
                                title: "P12 Certificate",
                                subtitle: p12URL?.lastPathComponent ?? "اختر ملف .p12",
                                color: .purple,
                                isSelected: p12URL != nil
                            ) { pickingType = .p12 }

                            FilePickerRow(
                                icon: "doc.badge.gearshape.fill",
                                title: "Provision Profile",
                                subtitle: provisionURL?.lastPathComponent ?? "اختر ملف .mobileprovision",
                                color: .cyan,
                                isSelected: provisionURL != nil
                            ) { pickingType = .provision }
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
                                if isSigning {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                } else {
                                    Image(systemName: "checkmark.seal.fill")
                                }
                                Text(isSigning ? "جاري التوقيع..." : "توقيع IPA")
                                    .font(.system(size: 17, weight: .bold))
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(
                                allSelected && !isSigning
                                ? Color.blue
                                : Color.gray.opacity(0.4)
                            )
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
                DocumentPicker(type: type) { url in
                    switch type {
                    case .ipa:
                        ipaURL = url
                        if appName.isEmpty {
                            appName = url.deletingPathExtension().lastPathComponent
                        }
                    case .p12:
                        p12URL = url
                    case .provision:
                        provisionURL = url
                    }
                    pickingType = nil
                }
            }
        }
    }

    @ViewBuilder
    func inputRow(title: String, placeholder: String, text: Binding<String>, isSecure: Bool = false) -> some View {
        HStack {
            Text(title)
                .foregroundColor(.white)
                .frame(width: 110, alignment: .leading)
            if isSecure {
                SecureField(placeholder, text: text)
                    .foregroundColor(.gray)
            } else {
                TextField(placeholder, text: text)
                    .foregroundColor(.gray)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    func startSigning() {
        guard let ipaURL = ipaURL else { return }
        isSigning = true
        resultSuccess = false
        statusMessage = "جاري فك ضغط IPA..."

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try SigningEngine.sign(
                    ipaURL: ipaURL,
                    p12URL: p12URL!,
                    provisionURL: provisionURL!,
                    p12Password: p12Password,
                    bundleID: bundleID.isEmpty ? nil : bundleID,
                    appName: appName.isEmpty ? nil : appName,
                    appVersion: appVersion.isEmpty ? nil : appVersion
                )
                DispatchQueue.main.async {
                    isSigning = false
                    resultSuccess = true
                    statusMessage = "تم التوقيع بنجاح! ✅"
                    let signed = AppItem(
                        name: appName.isEmpty ? ipaURL.deletingPathExtension().lastPathComponent : appName,
                        version: appVersion.isEmpty ? "1.0" : appVersion,
                        bundleID: bundleID.isEmpty ? "com.unknown" : bundleID,
                        ipaURL: result,
                        signedDate: Date()
                    )
                    store.signedApps.append(signed)
                }
            } catch {
                DispatchQueue.main.async {
                    isSigning = false
                    resultSuccess = false
                    statusMessage = "فشل التوقيع: \(error.localizedDescription)"
                }
            }
        }
    }
}

// MARK: - Signing Engine
struct SigningEngine {
    static func sign(
        ipaURL: URL,
        p12URL: URL,
        provisionURL: URL,
        p12Password: String,
        bundleID: String?,
        appName: String?,
        appVersion: String?
    ) throws -> URL {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)

        let ipaData = try Data(contentsOf: ipaURL)
        let payloadDir = tmp.appendingPathComponent("Payload")
        try fm.createDirectory(at: payloadDir, withIntermediateDirectories: true)

        let tmpIPA = tmp.appendingPathComponent("app.ipa")
        try ipaData.write(to: tmpIPA)

        let unzipResult = shell("unzip -o '\(tmpIPA.path)' -d '\(tmp.path)'")
        if unzipResult.contains("error") {
            throw SigningError.unzipFailed
        }

        guard let appBundle = try fm.contentsOfDirectory(at: payloadDir, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else {
            throw SigningError.appBundleNotFound
        }

        let embeddedProvision = appBundle.appendingPathComponent("embedded.mobileprovision")
        if fm.fileExists(atPath: embeddedProvision.path) {
            try fm.removeItem(at: embeddedProvision)
        }
        try fm.copyItem(at: provisionURL, to: embeddedProvision)

        let infoPlist = appBundle.appendingPathComponent("Info.plist")
        if fm.fileExists(atPath: infoPlist.path) {
            var plist = (try? PropertyListSerialization.propertyList(
                from: Data(contentsOf: infoPlist),
                options: [], format: nil
            ) as? [String: Any]) ?? [:]

            if let bid = bundleID, !bid.isEmpty { plist["CFBundleIdentifier"] = bid }
            if let name = appName, !name.isEmpty {
                plist["CFBundleName"] = name
                plist["CFBundleDisplayName"] = name
            }
            if let ver = appVersion, !ver.isEmpty {
                plist["CFBundleShortVersionString"] = ver
                plist["CFBundleVersion"] = ver
            }

            let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try plistData.write(to: infoPlist)
        }

        let codeSignDir = appBundle.appendingPathComponent("_CodeSignature")
        if fm.fileExists(atPath: codeSignDir.path) {
            try fm.removeItem(at: codeSignDir)
        }

        _ = shell("codesign --force --sign - '\(appBundle.path)' 2>/dev/null || true")

        let outputIPA = fm.temporaryDirectory.appendingPathComponent(
            (appName ?? ipaURL.deletingPathExtension().lastPathComponent) + "_signed.ipa"
        )
        if fm.fileExists(atPath: outputIPA.path) {
            try fm.removeItem(at: outputIPA)
        }
        _ = shell("cd '\(tmp.path)' && zip -r '\(outputIPA.path)' Payload")

        try? fm.removeItem(at: tmp)
        return outputIPA
    }

    @discardableResult
    static func shell(_ command: String) -> String {
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", command]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        task.launch()
        task.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}

enum SigningError: LocalizedError {
    case unzipFailed
    case appBundleNotFound
    case signingFailed

    var errorDescription: String? {
        switch self {
        case .unzipFailed: return "فشل فك ضغط IPA"
        case .appBundleNotFound: return "لم يتم العثور على .app داخل IPA"
        case .signingFailed: return "فشل التوقيع"
        }
    }
}

// MARK: - File Picker Row
struct FilePickerRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let color: Color
    let isSelected: Bool
    let action: () -> Void

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
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isSelected ? color.opacity(0.5) : Color.clear, lineWidth: 1)
            )
        }
    }
}

// MARK: - Document Picker
struct DocumentPicker: UIViewControllerRepresentable {
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

// MARK: - App Store View
struct AppStoreView: View {
    @EnvironmentObject var store: AppStore
    @State var showSources = false
    @State var searchText = ""

    let sampleApps: [(String, String, String)] = [
        ("AlevioOS", "2.5.1", "Injected with Subscription"),
        ("UpNote", "9.18.5", "Injected with Subscription"),
        ("Busuu", "30.12.0", "Injected with Premium"),
        ("VDIT", "4.0.0", "Injected with Subscription"),
        ("PhoneDiagnostics", "4.1.1", "Injected with IAP"),
        ("FLStudioMobile", "4.10.0", "Injected with IAP"),
        ("SimplyGuitar", "10.19", "Injected with Subscription"),
    ]

    var filtered: [(String, String, String)] {
        searchText.isEmpty ? sampleApps : sampleApps.filter { $0.0.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                List {
                    Section(header: Text("\(sampleApps.count * 971) Apps").foregroundColor(.gray)) {
                        ForEach(filtered, id: \.0) { app in
                            HStack(spacing: 14) {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.blue.opacity(0.15))
                                    .frame(width: 52, height: 52)
                                    .overlay(Image(systemName: "app.fill").foregroundColor(.blue).font(.title3))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(app.0).foregroundColor(.white)
                                    Text("\(app.1) • \(app.2)").foregroundColor(.gray).font(.caption)
                                }
                                Spacer()
                                Button("Get") {
                                    let item = AppItem(name: app.0, version: app.1, bundleID: "com.\(app.0.lowercased())")
                                    if !store.downloadedApps.contains(where: { $0.name == item.name }) {
                                        store.downloadedApps.append(item)
                                    }
                                }
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 18).padding(.vertical, 7)
                                .background(Color.blue.opacity(0.3))
                                .clipShape(Capsule())
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

struct SourcesView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State var showAddSource = false
    @State var newSourceURL = ""

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
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
                            }
                            .listRowBackground(Color(white: 0.1))
                        }
                        .onDelete { store.sources.remove(atOffsets: $0) }
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
                                            ProgressView(value: item.progress)
                                                .tint(.blue)
                                        }
                                    }
                                }
                                .padding(.vertical, 4)
                                .listRowBackground(Color(white: 0.1))
                            }
                            .onDelete { store.downloads.remove(atOffsets: $0) }
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
                Button("Download") { startDownload() }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    func startDownload() {
        guard let url = URL(string: downloadURL), !downloadURL.isEmpty else { return }
        let name = url.lastPathComponent
        let item = DownloadItem(name: name, size: "جاري التحميل...", url: url, progress: 0.0)
        store.downloads.append(item)
        downloadURL = ""

        URLSession.shared.downloadTask(with: url) { localURL, response, error in
            DispatchQueue.main.async {
                if let idx = store.downloads.firstIndex(where: { $0.name == name }) {
                    if let localURL = localURL {
                        let bytes = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? Int) ?? 0
                        let mb = Double(bytes) / 1_000_000
                        store.downloads[idx].size = String(format: "%.1f MB", mb)
                        store.downloads[idx].progress = 1.0
                        let appItem = AppItem(name: name, version: "1.0", bundleID: "com.download.\(name)", ipaURL: localURL)
                        store.downloadedApps.append(appItem)
                    } else {
                        store.downloads[idx].size = "فشل التحميل"
                    }
                }
            }
        }.resume()
    }
}

// MARK: - Settings View
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

                        NavigationLink(destination: SigningOptionsView()) {
                            SettingsRowContent(icon: "gearshape.fill", iconColor: .blue, title: "Signing Options")
                        }.listRowBackground(Color(white: 0.1))

                        NavigationLink(destination: LogsView()) {
                            SettingsRowContent(icon: "terminal.fill", iconColor: .blue, title: "Logs")
                        }.listRowBackground(Color(white: 0.1))
                    }

                    Section(header: Text("Misc").foregroundColor(.white).font(.headline).bold()) {
                        SettingsRowContent(icon: "info.circle", iconColor: .blue, title: "About MySigner")
                            .listRowBackground(Color(white: 0.1))
                        Button(action: {
                            store.downloadedApps.removeAll()
                            store.signedApps.removeAll()
                            store.downloads.removeAll()
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

struct SigningOptionsView: View {
    @State var removePlugins = true
    @State var forceSign = true
    @State var removeWatchApps = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            List {
                Section(header: Text("Signing Options").foregroundColor(.white)) {
                    Toggle("Force Sign", isOn: $forceSign)
                        .foregroundColor(.white).listRowBackground(Color(white: 0.1))
                    Toggle("Remove Plugins", isOn: $removePlugins)
                        .foregroundColor(.white).listRowBackground(Color(white: 0.1))
                    Toggle("Remove Watch Apps", isOn: $removeWatchApps)
                        .foregroundColor(.white).listRowBackground(Color(white: 0.1))
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Signing Options")
        .preferredColorScheme(.dark)
    }
}

struct LogsView: View {
    let logs = [
        "[INFO] MySigner started",
        "[INFO] Loaded certificates",
        "[INFO] Ready to sign",
    ]
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(logs, id: \.self) { log in
                        Text(log).font(.system(.caption, design: .monospaced)).foregroundColor(.green)
                    }
                }
                .padding()
            }
        }
        .navigationTitle("Logs")
        .preferredColorScheme(.dark)
    }
}

// MARK: - Certificates View
struct CertificatesView: View {
    @EnvironmentObject var store: AppStore
    @State var showAdd = false
    @State var p12URL: URL?
    @State var provisionURL: URL?
    @State var certName = ""
    @State var pickingType: CertPickType? = nil

    enum CertPickType: Identifiable {
        case p12, provision
        var id: Int { self == .p12 ? 0 : 1 }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack {
                if store.certificates.isEmpty {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "signature").font(.system(size: 44)).foregroundColor(.gray)
                        Text("No Certificates").foregroundColor(.gray)
                        Button("Add Certificate") { showAdd = true }
                            .foregroundColor(.blue)
                    }
                    Spacer()
                } else {
                    List {
                        ForEach(store.certificates) { cert in
                            CertCard(cert: cert)
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                        }
                        .onDelete { store.certificates.remove(atOffsets: $0) }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .padding(.horizontal, store.certificates.isEmpty ? 0 : 16)
        }
        .navigationTitle("Certificates")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: { showAdd = true }) { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showAdd) {
            NavigationView {
                ZStack {
                    Color.black.ignoresSafeArea()
                    VStack(spacing: 16) {
                        TextField("Certificate Name", text: $certName)
                            .padding()

                        FilePickerRow(
                            icon: "lock.shield.fill", title: "P12 File",
                            subtitle: p12URL?.lastPathComponent ?? "اختر .p12",
                            color: .purple, isSelected: p12URL != nil
                        ) { pickingType = .p12 }

                        FilePickerRow(
                            icon: "doc.badge.gearshape.fill", title: "Provision Profile",
                            subtitle: provisionURL?.lastPathComponent ?? "اختر .mobileprovision",
                            color: .cyan, isSelected: provisionURL != nil
                        ) { pickingType = .provision }

                        Button("Add") {
                            let cert = Certificate(
                                name: certName.isEmpty ? (p12URL?.lastPathComponent ?? "Certificate") : certName,
                                bundleID: provisionURL?.lastPathComponent ?? "",
                                daysLeft: 90, isValid: true,
                                p12URL: p12URL, provisionURL: provisionURL
                            )
                            store.certificates.append(cert)
                            showAdd = false
                            certName = ""
                            p12URL = nil
                            provisionURL = nil
                        }
                        .disabled(p12URL == nil || provisionURL == nil)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity).padding()
                        .background(p12URL != nil && provisionURL != nil ? Color.blue : Color.gray.opacity(0.4))
                        .cornerRadius(12)
                        Spacer()
                    }
                    .padding()
                }
                .navigationTitle("Add Certificate")
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Cancel") { showAdd = false }
                    }
                }
                .sheet(item: $pickingType) { type in
                    DocumentPicker(type: type == .p12 ? .p12 : .provision) { url in
                        if type == .p12 { p12URL = url } else { provisionURL = url }
                        pickingType = nil
                    }
                }
            }
            .preferredColorScheme(.dark)
        }
    }
}

struct CertCard: View {
    let cert: Certificate
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(cert.name).foregroundColor(.white).font(.body.bold())
            Text(cert.bundleID).foregroundColor(.gray).font(.caption)
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    Text("Valid").foregroundColor(.white).font(.subheadline.bold())
                }
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(Color.green.opacity(0.15)).cornerRadius(10)

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
    }
}

struct SettingsRowContent: View {
    let icon: String
    let iconColor: Color
    let title: String
    var isBlue: Bool = false

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(iconColor.opacity(0.2)).frame(width: 32, height: 32)
                Image(systemName: icon).foregroundColor(iconColor).font(.system(size: 15))
            }
            Text(title).foregroundColor(isBlue ? .blue : .white)
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View { ContentView() }
}
