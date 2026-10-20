import Foundation
import Observation

@MainActor @Observable
final class ClimateStore {
    var addresses: [DeviceAddress]
    var snapshots: [String: DeviceSnapshot] = [:]
    var selectedID: String {
        didSet { defaults.set(selectedID, forKey: "selectedRoom") }
    }
    var refreshing = false
    var sending = false
    var notice: String?
    var noticeConfirmed = false
    var commandRevision = 0
    private let defaults: UserDefaults
    private let client = DaikinClient()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.data(forKey: "climateAddresses")
            .flatMap { try? JSONDecoder().decode([DeviceAddress].self, from: $0) }
            .map { $0.filter { (try? privateHost($0.host)) != nil } }
        let initialAddresses = saved ?? DeviceAddress.initial
        addresses = initialAddresses
        let selected = defaults.string(forKey: "selectedRoom")
        selectedID = initialAddresses.first(where: { $0.host == selected })?.host ?? initialAddresses.first?.host ?? ""
    }

    var selected: DeviceSnapshot? { snapshots[selectedID] }
    var canControl: Bool { selected?.online == true && selected?.mode != nil && !refreshing && !sending }
    var connectedCount: Int { addresses.filter { snapshots[$0.host]?.online == true }.count }

    func refresh() async {
        guard !refreshing, !sending else { return }
        refreshing = true
        defer { refreshing = false }
        let client = client
        await withTaskGroup(of: (String, DeviceSnapshot?, String?).self) { group in
            for address in addresses {
                group.addTask {
                    do { return (address.host, try await client.read(address.host), nil) }
                    catch { return (address.host, nil, error.localizedDescription) }
                }
            }
            for await (host, value, error) in group {
                guard !Task.isCancelled else { continue }
                if let value { snapshots[host] = value }
                else if var previous = snapshots[host] {
                    previous.online = false
                    previous.error = error
                    snapshots[host] = previous
                } else {
                    snapshots[host] = DeviceSnapshot(host: host, name: addresses.first(where: { $0.host == host })?.name ?? "Climatisation",
                        online: false, power: false, mode: nil, target: nil, room: nil, outside: nil,
                        fan: nil, swing: nil, capabilities: Capabilities(temperature: false, fan: false, swing: false),
                        observedAt: .distantPast, error: error)
                }
            }
        }
    }

    func submit(_ changes: ControlChanges) async {
        guard canControl, !changes.isEmpty else { return }
        let host = selectedID
        sending = true
        notice = nil
        defer { sending = false }
        do {
            let result = try await client.control(host, changes: changes)
            snapshots[host] = result.snapshot
            notice = result.message
            noticeConfirmed = result.verified
            commandRevision += 1
        } catch {
            notice = error.localizedDescription + " Actualise l’état avant de réessayer."
            noticeConfirmed = false
            // A transport error may occur after a device accepted the write.
            // Disable commands until a fresh read; never blindly retry a setter.
            if var value = snapshots[host] {
                value.online = false
                value.error = "État à actualiser après la demande."
                snapshots[host] = value
            }
        }
    }

    func add(host input: String, name: String) async throws {
        guard !sending, !refreshing else { throw ClimateError.busy }
        let host = try privateHost(input.trimmingCharacters(in: .whitespacesAndNewlines))
        refreshing = true
        defer { refreshing = false }
        let value = try await client.read(host)
        snapshots[host] = value
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = DeviceAddress(host: host, name: label.isEmpty ? value.name.capitalized : String(label.prefix(40)))
        addresses.removeAll { $0.host == host }
        addresses.append(address)
        selectedID = host
        persist()
    }

    func remove(_ offsets: IndexSet) {
        guard !sending, !refreshing else { return }
        for index in offsets.sorted(by: >) {
            snapshots.removeValue(forKey: addresses[index].host)
            addresses.remove(at: index)
        }
        if !addresses.contains(where: { $0.host == selectedID }) { selectedID = addresses.first?.host ?? "" }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(addresses) { defaults.set(data, forKey: "climateAddresses") }
    }
}
