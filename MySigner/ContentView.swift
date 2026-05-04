import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var ipaURL: URL?
    @State private var p12URL: URL?
    @State private var provisionURL: URL?
    @State private var statusMessage = "جاهز للتوقيع"
    @State private var isSigning = false
    @State private var resultSuccess = false
    @State private var pickingType: PickType? = nil

    enum PickType { case ipa, p12, provision }

    var allSelected: Bool {
        ipaURL != nil && p12URL != nil && provisionURL != nil
    }

    var body: some View {
        NavigationView {
            ZStack {
                LinearGradient(colors: [Color(hex: "0f0c29"), Color(hex: "302b63"), Color(hex: "24243e")],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 24) {
                        VStack(spacing: 6) {
                            Image(systemName: "signature")
                                .font(.system(size: 52))
                                .foregroundColor(.white)
                                .shadow(color: .purple.opacity(0.8), radius: 16)
                            Text("MySigner")
                                .font(.system(size: 34, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                            Text("IPA Signing Tool")
                                .font(.subheadline)
                                .foregroundColor(.white.opacity(0.55))
                        }
                        .padding(.top, 20)

                        FileCard(icon: "archivebox.fill", title: "IPA File",
                                 subtitle: ipaURL?.lastPathComponent ?? "اختر ملف .ipa",
                                 color: Color(hex: "667eea"), isSelected: ipaURL != nil) { pickingType = .ipa }

                        FileCard(icon: "lock.shield.fill", title: "P12 Certificate",
                                 subtitle: p12URL?.lastPathComponent ?? "اختر ملف .p12",
                                 color: Color(hex: "f093fb"), isSelected: p12URL != nil) { pickingType = .p12 }

                        FileCard(icon: "doc.badge.gearshape.fill", title: "Provision Profile",
                                 subtitle: provisionURL?.lastPathComponent ?? "اختر ملف .mobileprovision",
                                 color: Color(hex: "4facfe"), isSelected: provisionURL != nil) { pickingType = .provision }

                        Button(action: startSigning) {
                            HStack(spacing: 12) {
                                if isSigning {
                                    ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white)).scaleEffect(0.9)
                                } else {
                                    Image(systemName: "checkmark.seal.fill").font(.title3)
                                }
                                Text(isSigning ? "جاري التوقيع..." : "توقيع IPA")
                                    .font(.system(size: 18, weight: .bold, design: .rounded))
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                            .background(
                                allSelected && !isSigning
                                ? LinearGradient(colors: [Color(hex: "667eea"), Color(hex: "764ba2")], startPoint: .leading, endPoint: .trailing)
                                : LinearGradient(colors: [Color.gray.opacity(0.4), Color.gray.opacity(0.3)], startPoint: .leading, endPoint: .trailing)
                            )
                            .cornerRadius(16)
                            .shadow(color: allSelected ? Color(hex: "667eea").opacity(0.5) : .clear, radius: 12)
                        }
                        .disabled(!allSelected || isSigning)
                        .padding(.horizontal, 4)

                        HStack(spacing: 8) {
                            Image(systemName: resultSuccess ? "checkmark.circle.fill" : "info.circle.fill")
                                .foregroundColor(resultSuccess ? .green : .white.opacity(0.6))
                            Text(statusMessage)
                                .font(.footnote)
                                .foregroundColor(.white.opacity(0.75))
                        }
                        .padding(.bottom, 30)
                    }
                    .padding(.horizontal, 20)
                }
            }
            .navigationBarHidden(true)
        }
        .sheet(item: $pickingType) { type in
            DocumentPicker(type: type) { url in
                switch type {
                case .ipa:       ipaURL = url
                case .p12:       p12URL = url
                case .provision: provisionURL = url
                }
                pickingType = nil
            }
        }
    }

    func startSigning() {
        isSigning = true
        statusMessage = "جاري التوقيع على الملف..."
        resultSuccess = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            isSigning = false
            resultSuccess = true
            statusMessage = "تم التوقيع بنجاح! (placeholder - يحتاج ZSign للتوقيع الحقيقي)"
        }
    }
}

struct FileCard: View {
    let icon: String; let title: String; let subtitle: String
    let color: Color; let isSelected: Bool; let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                ZStack {
                    Circle().fill(color.opacity(0.2)).frame(width: 52, height: 52)
                    Image(systemName: icon).font(.system(size: 22)).foregroundColor(color)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
                    Text(subtitle).font(.system(size: 12)).foregroundColor(.white.opacity(0.55)).lineLimit(1)
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "chevron.right")
                    .foregroundColor(isSelected ? .green : .white.opacity(0.35)).font(.system(size: 18))
            }
            .padding(16)
            .background(Color.white.opacity(0.07))
            .cornerRadius(16)
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(isSelected ? color.opacity(0.5) : Color.white.opacity(0.1), lineWidth: 1))
        }
    }
}

struct DocumentPicker: UIViewControllerRepresentable {
    let type: ContentView.PickType; let onPick: (URL) -> Void
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

extension ContentView.PickType: Identifiable {
    var id: Int { switch self { case .ipa: return 0; case .p12: return 1; case .provision: return 2 } }
}

extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: .alphanumerics.inverted)
        var val: UInt64 = 0; Scanner(string: h).scanHexInt64(&val)
        self.init(red: Double((val >> 16) & 0xff)/255, green: Double((val >> 8) & 0xff)/255, blue: Double(val & 0xff)/255)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View { ContentView() }
}
