import Foundation

protocol DaikinTransport: Sendable {
    func get(host: String, path: String, parameters: Fields) async throws -> Fields
}

private final class RedirectBlocker: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct HTTPTransport: DaikinTransport {
    private let session: URLSession
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 12
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.connectionProxyDictionary = [:]
        session = URLSession(configuration: configuration, delegate: RedirectBlocker(), delegateQueue: nil)
    }

    func get(host: String, path: String, parameters: Fields = [:]) async throws -> Fields {
        let host = try privateHost(host)
        let allowed = ["/common/basic_info", "/aircon/get_model_info", "/aircon/get_control_info",
                       "/aircon/get_sensor_info", "/aircon/set_control_info"]
        guard allowed.contains(path) else { throw ClimateError.invalidSetting }
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.path = path
        if !parameters.isEmpty {
            components.queryItems = parameters.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw ClimateError.invalidHost }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "GET"
        request.setValue("MonClimat-iOS/1.0", forHTTPHeaderField: "User-Agent")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw ClimateError.invalidResponse
            }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 65536 else { throw ClimateError.invalidResponse }
                data.append(byte)
            }
            guard let text = String(data: data, encoding: .utf8) else { throw ClimateError.invalidResponse }
            let result = parseFields(text)
            guard result["ret"] == "OK" else { throw ClimateError.refused }
            return result
        } catch is CancellationError { throw CancellationError() }
        catch let error as ClimateError { throw error }
        catch { throw ClimateError.unreachable }
    }
}

struct ControlOutcome: Sendable {
    var snapshot: DeviceSnapshot
    var verified: Bool
    var message: String
}

actor DaikinClient {
    private let transport: any DaikinTransport
    private var controlling: Set<String> = []
    init(transport: any DaikinTransport = HTTPTransport()) { self.transport = transport }

    func read(_ host: String) async throws -> DeviceSnapshot {
        let host = try privateHost(host)
        let basic = try await transport.get(host: host, path: "/common/basic_info", parameters: [:])
        guard basic["type"] == "aircon" else { throw ClimateError.invalidResponse }
        let model = try await transport.get(host: host, path: "/aircon/get_model_info", parameters: [:])
        let control = try await transport.get(host: host, path: "/aircon/get_control_info", parameters: [:])
        let sensors = try await transport.get(host: host, path: "/aircon/get_sensor_info", parameters: [:])
        return try DeviceSnapshot.make(host: host, basic: basic, model: model, control: control, sensors: sensors)
    }

    func control(_ host: String, changes: ControlChanges) async throws -> ControlOutcome {
        let host = try privateHost(host)
        guard !controlling.contains(host) else { throw ClimateError.busy }
        controlling.insert(host)
        defer { controlling.remove(host) }
        let before = try await read(host)
        let current = try await transport.get(host: host, path: "/aircon/get_control_info", parameters: [:])
        let params = try prepareControl(current: current, changes: changes, capabilities: before.capabilities)
        // Only this explicit control action can write. Never automatically repeat a write.
        _ = try await transport.get(host: host, path: "/aircon/set_control_info", parameters: params)
        var after = before
        do {
            for delay in [0, 250, 500] {
                if delay > 0 { try await Task.sleep(for: .milliseconds(delay)) }
                after = try await read(host)
                if changes.matches(after) {
                    return ControlOutcome(snapshot: after, verified: true, message: "Réglages confirmés par la clim.")
                }
            }
        } catch {
            after.online = false
            after.error = "La lecture après commande a échoué."
        }
        return ControlOutcome(snapshot: after, verified: false,
                              message: "Commande envoyée, état non confirmé. Actualise avant de réessayer.")
    }
}
