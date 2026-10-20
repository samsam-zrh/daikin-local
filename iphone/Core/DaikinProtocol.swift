import Foundation

typealias Fields = [String: String]

enum ClimateError: LocalizedError, Equatable {
    case invalidHost, incompleteState, invalidSetting, invalidTemperature
    case unsupportedTemperature, unreachable, invalidResponse, refused, busy

    var errorDescription: String? {
        switch self {
        case .invalidHost: "Saisis une adresse IP privée, par exemple 192.168.1.13."
        case .incompleteState: "Réglages incomplets : aucune commande envoyée."
        case .invalidSetting: "Ce réglage n’est pas pris en charge par cette clim."
        case .invalidTemperature: "Choisis une température dans les limites du mode, par pas de 0,5 °C."
        case .unsupportedTemperature: "Ce mode ne permet pas de régler la température."
        case .unreachable: "Clim inaccessible. Vérifie le Wi-Fi de la maison et l’autorisation Réseau local dans Réglages."
        case .invalidResponse: "La réponse reçue n’est pas celle d’une clim Daikin compatible."
        case .refused: "La climatisation a refusé cette demande."
        case .busy: "Une commande est déjà en cours."
        }
    }
}

enum ClimateMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case auto, cool, heat, dry, fan
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: "Auto"
        case .cool: "Froid"
        case .heat: "Chaud"
        case .dry: "Déshumidifier"
        case .fan: "Ventiler"
        }
    }
    var symbol: String {
        switch self {
        case .auto: "arrow.triangle.2.circlepath"
        case .cool: "snowflake"
        case .heat: "sun.max"
        case .dry: "drop"
        case .fan: "fan"
        }
    }
    var code: String {
        switch self { case .auto: "0"; case .cool: "3"; case .heat: "4"; case .dry: "2"; case .fan: "6" }
    }
    var limits: ClosedRange<Double>? {
        switch self { case .auto: 18...30; case .cool: 18...32; case .heat: 10...30; case .dry, .fan: nil }
    }
    init?(code: String) {
        switch code {
        case "0", "1", "7": self = .auto
        case "2": self = .dry
        case "3": self = .cool
        case "4": self = .heat
        case "6": self = .fan
        default: return nil
        }
    }
}

enum FanSpeed: String, CaseIterable, Identifiable, Sendable {
    case auto = "A", quiet = "B", one = "3", two = "4", three = "5", four = "6", five = "7"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: "Automatique"
        case .quiet: "Silencieuse"
        case .one: "Niveau 1"
        case .two: "Niveau 2"
        case .three: "Niveau 3"
        case .four: "Niveau 4"
        case .five: "Niveau 5"
        }
    }
}

enum Swing: String, CaseIterable, Identifiable, Sendable {
    case off = "0", vertical = "1", horizontal = "2", both = "3"
    var id: String { rawValue }
    var title: String {
        switch self { case .off: "Fixes"; case .vertical: "Vertical"; case .horizontal: "Horizontal"; case .both: "Deux axes" }
    }
}

struct Capabilities: Sendable, Equatable {
    var temperature: Bool
    var fan: Bool
    var swing: Bool
}

struct DeviceAddress: Codable, Identifiable, Equatable, Sendable {
    var host: String
    var name: String
    var id: String { host }
    static let initial: [DeviceAddress] = []
}

struct DeviceSnapshot: Identifiable, Sendable, Equatable {
    var host: String
    var name: String
    var online = true
    var power: Bool
    var mode: ClimateMode?
    var target: Double?
    var room: Double?
    var outside: Double?
    var fan: FanSpeed?
    var swing: Swing?
    var capabilities: Capabilities
    var observedAt: Date
    var error: String?
    var id: String { host }

    static func make(host: String, basic: Fields, model: Fields, control: Fields, sensors: Fields) throws -> Self {
        guard basic["type"] == "aircon", control["pow"] != nil, control["mode"] != nil else {
            throw ClimateError.invalidResponse
        }
        let mode = ClimateMode(code: control["mode"] ?? "")
        return Self(
            host: host, name: basic["name"].flatMap { $0.isEmpty ? nil : $0 } ?? "Climatisation",
            power: control["pow"] == "1", mode: mode,
            target: mode?.limits != nil ? numeric(control["stemp"]) : nil,
            room: numeric(sensors["htemp"]), outside: numeric(sensors["otemp"]),
            fan: control["f_rate"].flatMap(FanSpeed.init(rawValue:)),
            swing: control["f_dir"].flatMap(Swing.init(rawValue:)),
            capabilities: Capabilities(
                temperature: model["temp"] == "1",
                fan: control["f_rate"] != nil && model["en_frate"] != "0",
                swing: control["f_dir"] != nil && model["en_fdir"] != "0"
            ), observedAt: Date()
        )
    }
}

struct ControlChanges: Sendable, Equatable {
    var power: Bool?
    var mode: ClimateMode?
    var target: Double?
    var fan: FanSpeed?
    var swing: Swing?
    var isEmpty: Bool { power == nil && mode == nil && target == nil && fan == nil && swing == nil }

    func matches(_ snapshot: DeviceSnapshot) -> Bool {
        (power == nil || snapshot.power == power) &&
        (mode == nil || snapshot.mode == mode) &&
        (target == nil || snapshot.target == target) &&
        (fan == nil || snapshot.fan == fan) &&
        (swing == nil || snapshot.swing == swing)
    }
}

func privateHost(_ input: String) throws -> String {
    let parts = input.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4 else { throw ClimateError.invalidHost }
    let numbers = try parts.map { part -> Int in
        guard !part.isEmpty, part.utf8.allSatisfy({ 48...57 ~= $0 }),
              (part.count == 1 || part.first != "0"), let n = Int(part), 0...255 ~= n else {
            throw ClimateError.invalidHost
        }
        return n
    }
    guard numbers[0] == 10 || (numbers[0] == 172 && 16...31 ~= numbers[1]) ||
          (numbers[0] == 192 && numbers[1] == 168), numbers[3] != 0, numbers[3] != 255 else {
        throw ClimateError.invalidHost
    }
    return numbers.map(String.init).joined(separator: ".")
}

func parseFields(_ text: String) -> Fields {
    var result: Fields = [:]
    for part in text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ",") {
        let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        if pair.count == 2 { result[String(pair[0])] = String(pair[1]).removingPercentEncoding ?? String(pair[1]) }
    }
    return result
}

func numeric(_ value: String?) -> Double? {
    guard let value, let n = Double(value), n.isFinite, -60...100 ~= n else { return nil }
    return n
}

func prepareControl(current: Fields, changes: ControlChanges, capabilities: Capabilities) throws -> Fields {
    guard !changes.isEmpty else { throw ClimateError.invalidSetting }
    guard ["pow", "mode", "stemp", "shum"].allSatisfy({ current[$0] != nil }) else {
        throw ClimateError.incompleteState
    }
    guard let oldMode = current["mode"], let mode = changes.mode ?? ClimateMode(code: oldMode) else {
        throw ClimateError.invalidSetting
    }
    var result = current.filter { ["pow", "mode", "stemp", "shum", "f_rate", "f_dir"].contains($0.key) }
    let newMode = changes.mode?.code ?? oldMode
    result["mode"] = newMode
    if changes.mode != nil && newMode != oldMode {
        for (field, prefix) in [("stemp", "dt"), ("shum", "dh"), ("f_rate", "dfr")] {
            if result[field] != nil, let memory = current[prefix + newMode] { result[field] = memory }
        }
    }
    if let power = changes.power { result["pow"] = power ? "1" : "0" }
    if let target = changes.target {
        guard capabilities.temperature, let limits = mode.limits else { throw ClimateError.unsupportedTemperature }
        guard target.isFinite, limits.contains(target), abs(target * 2 - (target * 2).rounded()) < 1e-8 else {
            throw ClimateError.invalidTemperature
        }
        result["stemp"] = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), target)
    }
    if let fan = changes.fan {
        guard capabilities.fan else { throw ClimateError.invalidSetting }
        result["f_rate"] = fan.rawValue
    }
    if let swing = changes.swing {
        guard capabilities.swing else { throw ClimateError.invalidSetting }
        result["f_dir"] = swing.rawValue
    }
    return result
}
