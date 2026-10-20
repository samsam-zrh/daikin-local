import SwiftUI

struct ConnectionView: View {
    var store: ClimateStore
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var name = ""
    @State private var adding = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Connecte l’iPhone au Wi-Fi de la maison.", systemImage: "wifi")
                    Text("L’application parle directement aux clims. Aucun Mac ni compte Daikin n’est nécessaire pour les piloter.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Section("Tes pièces") {
                    ForEach(store.addresses) { address in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(address.name)
                                Text(address.host).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: store.snapshots[address.host]?.online == true ? "checkmark.circle.fill" : "wifi.exclamationmark")
                                .foregroundStyle(store.snapshots[address.host]?.online == true ? .green : .secondary)
                        }
                    }.onDelete { store.remove($0) }
                }
                Section {
                    TextField("Nom de la pièce", text: $name).textInputAutocapitalization(.words)
                    TextField("Adresse IP, ex. 192.168.1.13", text: $host)
                        .keyboardType(.decimalPad).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button {
                        adding = true
                        error = nil
                        Task {
                            defer { adding = false }
                            do { try await store.add(host: host, name: name); host = ""; name = "" }
                            catch { self.error = error.localizedDescription }
                        }
                    } label: {
                        HStack { if adding { ProgressView() }; Text("Vérifier et ajouter") }
                    }.disabled(host.isEmpty || adding || store.sending || store.refreshing)
                    if let error { Text(error).font(.caption).foregroundStyle(.orange) }
                } header: { Text("Ajouter ou actualiser une adresse") } footer: {
                    Text("Si une adresse change, retrouve-la dans la liste des appareils connectés à ta box. L’ajout vérifie l’appareil sans changer ses réglages. Glisse une pièce vers la gauche pour la retirer de cette liste.")
                }
                Section("Autorisation réseau") {
                    Button("Ouvrir les réglages de l’application") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    Text("Autorise « Réseau local ». Un Wi-Fi invité, un VPN ou l’isolation des appareils peuvent empêcher la connexion.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Text("Mon climat · Application personnelle")
                    Text("Compatible avec les trois unités Daikin détectées dans ce logement. Les réglages sont relus après chaque demande. Fonctionne sur le réseau local de la maison.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Connexion").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Terminé") { dismiss() } } }
        }
    }
}
