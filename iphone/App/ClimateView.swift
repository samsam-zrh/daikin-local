import SwiftUI

enum ClimateTheme {
    static let blue = Color(red: 0.08, green: 0.42, blue: 0.90)
    static let ink = Color(red: 0.10, green: 0.17, blue: 0.26)
    static let background = Color(red: 0.95, green: 0.97, blue: 0.99)
}

struct ClimateView: View {
    var store: ClimateStore
    @Environment(\.scenePhase) private var phase
    @State private var connectionPresented = false
    @State private var draft = ControlChanges()

    private var device: DeviceSnapshot? { store.selected }
    private var mode: ClimateMode? { draft.mode ?? device?.mode }
    private var target: Double? {
        if let target = draft.target { return target }
        return draft.mode == nil || draft.mode == device?.mode ? device?.target : nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    header
                    roomPicker
                    if store.addresses.isEmpty {
                        ContentUnavailableView("Ajoute une clim", systemImage: "wifi", description: Text("Renseigne son adresse dans Connexion."))
                    } else {
                        thermostat
                        if let error = device?.error {
                            Label(error, systemImage: "wifi.exclamationmark")
                                .font(.callout).foregroundStyle(.orange).padding(.horizontal)
                        }
                        controls
                    }
                    if let notice = store.notice {
                        Label(notice, systemImage: store.noticeConfirmed ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .font(.callout).foregroundStyle(store.noticeConfirmed ? Color.green : Color.orange)
                            .padding().frame(maxWidth: .infinity, alignment: .leading)
                            .background(.white, in: RoundedRectangle(cornerRadius: 18))
                            .accessibilityIdentifier("commandNotice")
                    }
                    Text("Chez toi, directement en Wi-Fi")
                        .font(.footnote).foregroundStyle(.secondary).padding(.bottom, 16)
                }
                .padding(.horizontal, 20).padding(.top, 12)
            }
            .background(ClimateTheme.background)
            .navigationTitle("Mon climat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { connectionPresented = true } label: { Image(systemName: "wifi") }
                        .accessibilityLabel("Connexion aux climatiseurs")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await store.refresh() } } label: {
                        if store.refreshing { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                    }
                    .disabled(store.refreshing || store.sending).accessibilityLabel("Actualiser les états")
                }
            }
            .refreshable { await store.refresh() }
            .sheet(isPresented: $connectionPresented) { ConnectionView(store: store) }
            .task(id: phase) {
                guard phase == .active else { return }
                while !Task.isCancelled {
                    await store.refresh()
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                }
            }
            .onChange(of: store.selectedID) { _, _ in draft = ControlChanges(); store.notice = nil }
            .onChange(of: store.commandRevision) { _, _ in draft = ControlChanges() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Le confort, simplement.").font(.title2.bold()).foregroundStyle(ClimateTheme.ink)
            HStack(spacing: 6) {
                Circle().fill(store.connectedCount > 0 ? .green : .orange).frame(width: 7, height: 7)
                Text(store.refreshing ? "Lecture des climatiseurs…" : "\(store.connectedCount) sur \(store.addresses.count) connectées")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var roomPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(store.addresses) { address in
                    let snapshot = store.snapshots[address.host]
                    Button {
                        store.selectedID = address.host
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Image(systemName: address.name.lowercased() == "salon" ? "sofa" : "bed.double")
                                Text(address.name).lineLimit(1)
                            }.font(.subheadline.weight(.semibold))
                            HStack(spacing: 4) {
                                Text(degrees(snapshot?.room)).font(.title3.bold())
                                Text(snapshot?.online == true ? (snapshot?.power == true ? "En marche" : "À l’arrêt") : "Hors ligne")
                                    .font(.caption2)
                            }
                        }
                        .padding(15).frame(minWidth: 140, alignment: .leading)
                        .foregroundStyle(store.selectedID == address.host ? .white : ClimateTheme.ink)
                        .background(store.selectedID == address.host ? ClimateTheme.blue : .white, in: RoundedRectangle(cornerRadius: 20))
                    }
                    .buttonStyle(.plain).disabled(store.sending)
                    .accessibilityIdentifier("room-\(address.name)")
                }
            }
        }
    }

    private var thermostat: some View {
        VStack(spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(store.addresses.first(where: { $0.host == store.selectedID })?.name ?? "Climatisation")
                        .font(.title2.bold())
                    Text(device?.online == true ? (device?.power == true ? "En marche · \(device?.mode?.title ?? "Mode inconnu")" : "À l’arrêt") : "Connexion en attente")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    guard let device else { return }
                    Task { await store.submit(ControlChanges(power: !device.power)) }
                } label: {
                    Image(systemName: "power").font(.title3.weight(.semibold))
                        .frame(width: 50, height: 50)
                        .foregroundStyle(device?.power == true ? .white : ClimateTheme.blue)
                        .background(device?.power == true ? ClimateTheme.blue : ClimateTheme.background, in: Circle())
                }
                .disabled(!store.canControl)
                .accessibilityLabel(device?.power == true ? "Éteindre cette clim" : "Allumer cette clim")
                .accessibilityIdentifier("powerButton")
            }

            ZStack {
                Circle().trim(from: 0.12, to: 0.88).stroke(ClimateTheme.background, style: StrokeStyle(lineWidth: 14, lineCap: .round)).rotationEffect(.degrees(90))
                Circle().trim(from: 0.12, to: 0.70).stroke(ClimateTheme.blue.gradient, style: StrokeStyle(lineWidth: 14, lineCap: .round)).rotationEffect(.degrees(90))
                VStack(spacing: 4) {
                    Text(mode?.limits == nil ? "MODE" : "TEMPÉRATURE SOUHAITÉE")
                        .font(.caption2.weight(.semibold)).tracking(1.1).foregroundStyle(.secondary)
                    if mode?.limits == nil {
                        Image(systemName: mode?.symbol ?? "thermometer").font(.system(size: 52, weight: .light)).padding(.vertical, 10)
                        Text(mode?.title ?? "—").font(.headline)
                    } else {
                        Text(degrees(target)).font(.system(size: 64, weight: .light, design: .rounded)).minimumScaleFactor(0.6)
                            .accessibilityIdentifier("targetTemperature")
                        Text(target == nil ? "Applique le mode pour lire sa consigne" : "degrés Celsius")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                }.padding(32)
            }
            .frame(maxWidth: 280).frame(height: 280)
            .foregroundStyle(ClimateTheme.ink)
            .opacity(device?.online == true ? 1 : 0.5)

            HStack(spacing: 28) {
                temperatureButton(symbol: "minus", delta: -0.5)
                Text("Consigne").font(.subheadline).foregroundStyle(.secondary)
                temperatureButton(symbol: "plus", delta: 0.5)
            }
            HStack {
                Label("Pièce \(degrees(device?.room))", systemImage: "thermometer.medium")
                Spacer()
                Label("Dehors \(degrees(device?.outside))", systemImage: "cloud.sun")
            }.font(.caption).foregroundStyle(.secondary).padding(.top, 12)
            if device?.online == false, device?.observedAt != .distantPast, let date = device?.observedAt {
                Text("Dernière lecture : \(date.formatted(date: .omitted, time: .shortened)) · valeurs anciennes")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(22).background(.white, in: RoundedRectangle(cornerRadius: 28))
    }

    private func temperatureButton(symbol: String, delta: Double) -> some View {
        Button {
            guard let target, let limits = mode?.limits else { return }
            draft.target = min(limits.upperBound, max(limits.lowerBound, target + delta))
        } label: {
            Image(systemName: symbol).font(.title3.weight(.semibold)).frame(width: 48, height: 48)
                .background(ClimateTheme.background, in: Circle())
        }
        .disabled(!store.canControl || target == nil || mode?.limits == nil || device?.capabilities.temperature != true)
        .accessibilityLabel(symbol == "plus" ? "Augmenter de 0,5 degré" : "Diminuer de 0,5 degré")
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("À ton rythme").font(.headline).foregroundStyle(ClimateTheme.ink)
            HStack(spacing: 6) {
                ForEach(ClimateMode.allCases) { value in
                    Button {
                        draft.mode = value == device?.mode ? nil : value
                        draft.target = nil
                    } label: {
                        VStack(spacing: 7) {
                            Image(systemName: value.symbol).font(.title3)
                            Text(value == .dry ? "Sec" : value.title).font(.caption2).lineLimit(1).minimumScaleFactor(0.7)
                        }
                        .frame(maxWidth: .infinity).frame(minHeight: 65)
                        .foregroundStyle(mode == value ? ClimateTheme.blue : .secondary)
                        .background(mode == value ? ClimateTheme.blue.opacity(0.09) : .white, in: RoundedRectangle(cornerRadius: 14))
                    }.buttonStyle(.plain).accessibilityLabel(value.title)
                }
            }
            if device?.capabilities.fan == true {
                Picker(selection: Binding(get: { draft.fan ?? device?.fan }, set: { draft.fan = $0 })) {
                    if device?.fan == nil { Text("Inconnue").tag(FanSpeed?.none) }
                    ForEach(FanSpeed.allCases) { value in Text(value.title).tag(Optional(value)) }
                } label: { Label("Ventilation", systemImage: "fan") }
            }
            if device?.capabilities.swing == true {
                Picker(selection: Binding(get: { draft.swing ?? device?.swing }, set: { draft.swing = $0 })) {
                    if device?.swing == nil { Text("Inconnus").tag(Swing?.none) }
                    ForEach(Swing.allCases) { value in Text(value.title).tag(Optional(value)) }
                } label: { Label("Volets", systemImage: "arrow.up.and.down") }
            }
            Button {
                Task { await store.submit(draft) }
            } label: {
                HStack {
                    if store.sending { ProgressView().tint(.white) }
                    Text(store.sending ? "Confirmation en cours…" : "Appliquer les réglages").fontWeight(.semibold)
                }.frame(maxWidth: .infinity).padding(.vertical, 9)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(!store.canControl || draft.isEmpty)
            .accessibilityIdentifier("applyButton")
            if !draft.isEmpty { Text("Tes changements seront envoyés en appuyant sur Appliquer.").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(20).background(.white, in: RoundedRectangle(cornerRadius: 24))
        .disabled(!store.canControl)
    }
}

func degrees(_ number: Double?) -> String {
    guard let number else { return "—" }
    return number.formatted(.number.precision(.fractionLength(0...1)).locale(Locale(identifier: "fr_FR"))) + "°"
}
