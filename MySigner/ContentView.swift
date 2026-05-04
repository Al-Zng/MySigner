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

// MARK: - App Store (Global State)
class AppStore: ObservableObject {
    @Published var certificates: [Certificate] = [
        Certificate(name: "khoindvn.io.vn GLOBAL TAKEOFF", bundleID: "XC com gto supposetv ent", daysLeft: 53, isValid: true)
    ]
    @Published var downloadedApps: [AppItem] = [
        AppItem(name: "MySigner", version: "1.0", bundleID: "com.example.MySigner"),
        AppItem(name: "MadraPlus", version: "1.0", bundleID: "com.madra"),
    ]
    @Published var downloads: [DownloadItem] = [
        DownloadItem(name: "AlightMotion_6.2.53_Subscription", size: "125.6 MB"),
        DownloadItem(name: "Documents_8.19.13_Plus_@thisi...", size: "343.4 MB"),
    ]
    @Published var sources: [Source] = [
        Source(name: "AppTesters IPA Repo", url: "https://repository.apptesters.org"),
        Source(name: "CyPwn IPA Library", url: "https://ipa.cypwn.xyz/cypwn.json"),
        Source(name: "Ksign Repository", url: "https://raw.githubusercontent.co..."),
        Source(name: "SideStore Team Picks", url: "https://community-apps.sidestore..."),
        Source(name: "Znoj Repoo", url: "https://raw.githubusercontent.co..."),
        Source(name: "iTorrent Source", url: "https://xitrix.github.io/iTorrent/Alt..."),
    ]
}

struct Certificate: Identifiable {
    let id = UUID(); var name: String; var bundleID: String; var daysLeft: Int; var isValid: Bool
}
struct AppItem: Identifiable {
    let id = UUID(); var name: String; var version: String; var bundleID: String
}
struct DownloadItem: Identifiable {
    let id = UUID(); var name: String; var size: String
}
struct Source: Identifiable {
    let id = UUID(); var name: String; var url: String; var iconColor: Color = .gray
}

// MARK: - Files View
struct FilesView: View {
    let folders = [("App", "April 28, 2026"), ("Downloads", "April 28, 2026")]
    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                List {
                    ForEach(folders, id: \.0) { folder in
                        NavigationLink(destination: EmptyFolderView(name: folder.0)) {
                            HStack(spacing: 14) {
                                Image(systemName: "folder.fill")
                                    .foregroundColor(.blue)
                                    .font(.title2)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(folder.0).foregroundColor(.white).font(.body)
                                    Text(folder.1).foregroundColor(.gray).font(.caption)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .listRowBackground(Color.black)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Documents")
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button(action: {}) { Image(systemName: "plus") }
                    Button(action: {}) { Image(systemName: "pencil") }.foregroundColor(.blue)
                    Button(action: {}) { Image(systemName: "line.3.horizontal") }
                }
            }
        }
    }
}

struct EmptyFolderView: View {
    let name: String
    var body: some View {
        ZStack { Color.black.ignoresSafeArea(); Text("Empty").foregroundColor(.gray) }
            .navigationTitle(name)
    }
}

// MARK: - Library View
struct LibraryView: View {
    @EnvironmentObject var store: AppStore
    @State var tab = 0

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
                        appList(apps: store.downloadedApps)
                    } else {
                        ZStack {
                            Color.black
                            Text("No Signed Apps").foregroundColor(.gray)
                        }
                    }
                }
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Edit") {}
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {}) { Image(systemName: "plus") }
                }
            }
        }
    }

    func appList(apps: [AppItem]) -> some View {
        List {
            Section(header: HStack {
                Text("Downloaded Apps").foregroundColor(.white).font(.headline).bold()
                Spacer()
                Text("\(apps.count)").foregroundColor(.white)
                    .font(.caption).padding(6)
                    .background(Color.gray.opacity(0.4)).clipShape(Circle())
            }.listRowInsets(EdgeInsets())) {
                ForEach(apps) { app in
                    NavigationLink(destination: AppDetailView(app: app)) {
                        HStack(spacing: 14) {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.gray.opacity(0.3))
                                .frame(width: 52, height: 52)
                                .overlay(Image(systemName: "app.fill").foregroundColor(.gray).font(.title2))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(app.name).foregroundColor(.white).font(.body)
                                Text("\(app.version) • \(app.bundleID)").foregroundColor(.gray).font(.caption)
                            }
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
}

struct AppDetailView: View {
    let app: AppItem
    var body: some View {
        ZStack { Color.black.ignoresSafeArea()
            Text(app.name).foregroundColor(.white)
        }.navigationTitle(app.name)
    }
}

// MARK: - App Store View
struct AppStoreView: View {
    @EnvironmentObject var store: AppStore
    @State var showSources = false
    let sampleApps = [
        ("AlevioOS","2.5.1","Injected with Subsc..."),
        ("UpNote","9.18.5","Injected with Subs..."),
        ("Busuu","30.12.0","Injected with Pre..."),
        ("VDIT","4.0.0","Injected with Subs..."),
        ("PhoneDiagnostics","4.1.1","Injected with IAP"),
        ("FLStudioMobile","4.10.0","Injected with IAP"),
        ("SimplyGuitar","10.19","Injected with Subs..."),
    ]

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                List {
                    Section(header: Text("\(sampleApps.count * 971) Apps").foregroundColor(.gray).font(.subheadline)) {
                        ForEach(sampleApps, id: \.0) { app in
                            HStack(spacing: 14) {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.gray.opacity(0.25))
                                    .frame(width: 52, height: 52)
                                    .overlay(Image(systemName: "app").foregroundColor(.gray).font(.title3))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(app.0).foregroundColor(.white).font(.body)
                                    Text("\(app.1) • \(app.2)").foregroundColor(.gray).font(.caption)
                                }
                                Spacer()
                                Button("Get") {}
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 18).padding(.vertical, 7)
                                    .background(Color.gray.opacity(0.3))
                                    .clipShape(Capsule())
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
            .searchable(text: .constant(""), prompt: "Search")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Sources") { showSources = true }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {}) { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showSources) { SourcesView() }
        }
    }
}

struct SourcesView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                List {
                    NavigationLink(destination: EmptyFolderView(name: "All Repositories")) {
                        HStack(spacing: 14) {
                            RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.3))
                                .frame(width: 44, height: 44)
                                .overlay(Image(systemName: "square.grid.2x2").foregroundColor(.white))
                            VStack(alignment: .leading) {
                                Text("All Repositories").foregroundColor(.white)
                                Text("See all apps from your sources").foregroundColor(.gray).font(.caption)
                            }
                        }
                    }.listRowBackground(Color.black)

                    Section(header: HStack {
                        Text("Repositories").foregroundColor(.white).font(.headline).bold()
                        Spacer()
                        Text("\(store.sources.count)").foregroundColor(.white).font(.caption)
                            .padding(6).background(Color.gray.opacity(0.4)).clipShape(Circle())
                    }) {
                        ForEach(store.sources) { src in
                            HStack(spacing: 14) {
                                RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.25))
                                    .frame(width: 44, height: 44)
                                    .overlay(Image(systemName: "globe").foregroundColor(.gray))
                                VStack(alignment: .leading) {
                                    Text(src.name).foregroundColor(.white)
                                    Text(src.url).foregroundColor(.gray).font(.caption).lineLimit(1)
                                }
                            }
                            .listRowBackground(Color.black)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Sources")
            .searchable(text: .constant(""), prompt: "Search")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("App Store") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {}) { Image(systemName: "plus") }
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
                                    .background(Color.gray.opacity(0.15)).cornerRadius(10)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.name).foregroundColor(.white).font(.body).lineLimit(1)
                                    Text(item.size).foregroundColor(.gray).font(.caption)
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
            .navigationTitle("Downloads")
            .searchable(text: .constant(""), prompt: "Search")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {}) { Image(systemName: "plus") }
                }
            }
        }
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
                    // Donations card
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
                            Button(action: {}) {
                                Text("Donate")
                                    .font(.body.bold()).foregroundColor(.white)
                                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                                    .background(Color.blue).cornerRadius(12)
                            }
                        }
                        .padding(.vertical, 8)
                        .listRowBackground(Color(white: 0.12))
                    }

                    // About links
                    Section {
                        SettingsRow(icon: "info.circle", iconColor: .blue, title: "About", isLink: true)
                        SettingsRow(icon: "paperplane.fill", iconColor: .blue, title: "Telegram Channel", isLink: true, isBlue: true)
                        SettingsRow(icon: "safari.fill", iconColor: .blue, title: "GitHub Repository", isLink: true, isBlue: true)
                        SettingsRow(icon: "safari.fill", iconColor: .blue, title: "Discord Server", isLink: true, isBlue: true)
                    }
                    .listRowBackground(Color(white: 0.12))

                    // Appearance
                    Section {
                        SettingsRow(icon: "app.badge", iconColor: .blue, title: "App Icon", isLink: true)
                        SettingsRow(icon: "paintbrush.fill", iconColor: .blue, title: "Appearance", isLink: true)
                    }
                    .listRowBackground(Color(white: 0.12))

                    // Features
                    Section(header: Text("Features").foregroundColor(.white).font(.headline).bold()) {
                        SettingsRow(icon: "terminal.fill", iconColor: .blue, title: "Logs", isLink: true)
                        SettingsRow(icon: "sparkles", iconColor: .blue, title: "App Features", isLink: true)
                        NavigationLink(destination: CertificatesView()) {
                            SettingsRowContent(icon: "signature", iconColor: .blue, title: "Certificates")
                        }.listRowBackground(Color(white: 0.12))
                        SettingsRow(icon: "gearshape.fill", iconColor: .blue, title: "Signing Options", isLink: true)
                        SettingsRow(icon: "archivebox.fill", iconColor: .blue, title: "Archive & Extraction", isLink: true)
                        SettingsRow(icon: "server.rack", iconColor: .blue, title: "Server & SSL", isLink: true)
                    }
                    .listRowBackground(Color(white: 0.12))

                    // Misc
                    Section(header: Text("Misc").foregroundColor(.white).font(.headline).bold()) {
                        SettingsRow(icon: "folder.fill", iconColor: .blue, title: "Open Documents", isLink: false, isBlue: true)
                        SettingsRow(icon: "folder.fill", iconColor: .blue, title: "Open Archives", isLink: false, isBlue: true)
                    }
                    .listRowBackground(Color(white: 0.12))

                    Section {
                        SettingsRow(icon: "trash.fill", iconColor: .red, title: "Reset", isLink: true)
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

struct SettingsRow: View {
    let icon: String; let iconColor: Color; let title: String
    var isLink: Bool = true; var isBlue: Bool = false
    var body: some View {
        NavigationLink(destination: EmptyFolderView(name: title)) {
            SettingsRowContent(icon: icon, iconColor: iconColor, title: title, isBlue: isBlue)
        }
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
        }
    }
}

// MARK: - Certificates View
struct CertificatesView: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 16) {
                ForEach(store.certificates) { cert in
                    CertCard(cert: cert)
                }
                Spacer()
            }
            .padding()
        }
        .navigationTitle("Certificates")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: {}) { Image(systemName: "plus") }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: {}) { Image(systemName: "arrow.clockwise") }
            }
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
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.blue.opacity(0.6), lineWidth: 1.5))
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View { ContentView() }
}
