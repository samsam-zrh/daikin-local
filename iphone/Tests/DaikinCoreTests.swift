import XCTest
@testable import DaikinCore

private let capabilities = Capabilities(temperature: true, fan: true, swing: true)
private let current: Fields = ["ret":"OK", "pow":"0", "mode":"3", "stemp":"22.0", "shum":"0",
    "f_rate":"A", "f_dir":"3", "dt2":"M", "dh2":"50", "dfr2":"5", "dt4":"26.0", "dh4":"0", "dfr4":"6", "dfr6":"5"]

final class ProtocolTests: XCTestCase {
    func testPrivateAddressesOnly() throws {
        for host in ["192.168.1.13", "10.1.2.3", "172.16.0.1", "172.31.2.3"] {
            XCTAssertEqual(try privateHost(host), host)
        }
        for host in ["127.0.0.1", "8.8.8.8", "169.254.1.1", "172.32.0.1", "localhost", "192.168.1.13:80", "192.168.1.013", "192.168.1.255", "192.168.1.13/path"] {
            XCTAssertThrowsError(try privateHost(host), host)
        }
    }

    func testParsingPercentAndEquals() {
        XCTAssertEqual(parseFields("ret=OK,name=Pi%C3%A8ce%20A,key=a=b\n"), ["ret":"OK", "name":"Pièce A", "key":"a=b"])
    }

    func testPowerPreservesUnrelatedValues() throws {
        let result = try prepareControl(current: current, changes: ControlChanges(power: true), capabilities: capabilities)
        XCTAssertEqual(result, ["pow":"1", "mode":"3", "stemp":"22.0", "shum":"0", "f_rate":"A", "f_dir":"3"])
    }

    func testModeRestoresMemoryWithoutStarting() throws {
        let result = try prepareControl(current: current, changes: ControlChanges(mode: .heat), capabilities: capabilities)
        XCTAssertEqual(result["pow"], "0")
        XCTAssertEqual(result["stemp"], "26.0")
        XCTAssertEqual(result["f_rate"], "6")
        XCTAssertEqual(result["f_dir"], "3")
    }

    func testDryRestoresMAndHumidity() throws {
        let result = try prepareControl(current: current, changes: ControlChanges(mode: .dry), capabilities: capabilities)
        XCTAssertEqual(result["stemp"], "M")
        XCTAssertEqual(result["shum"], "50")
    }

    func testFanDoesNotInventMissingMemory() throws {
        let result = try prepareControl(current: current, changes: ControlChanges(mode: .fan), capabilities: capabilities)
        XCTAssertEqual(result["stemp"], "22.0")
        XCTAssertEqual(result["shum"], "0")
        XCTAssertEqual(result["f_rate"], "5")
    }

    func testAutoVariantIsPreserved() throws {
        var values = current
        values["mode"] = "7"
        XCTAssertEqual(try prepareControl(current: values, changes: ControlChanges(power: true), capabilities: capabilities)["mode"], "7")
    }

    func testTemperatureValidation() throws {
        for value in [17.5, 32.5, 22.25, Double.nan, Double.infinity] {
            XCTAssertThrowsError(try prepareControl(current: current, changes: ControlChanges(target: value), capabilities: capabilities))
        }
        XCTAssertEqual(try prepareControl(current: current, changes: ControlChanges(target: 21.5), capabilities: capabilities)["stemp"], "21.5")
        XCTAssertThrowsError(try prepareControl(current: current, changes: ControlChanges(mode: .dry, target: 22), capabilities: capabilities))
    }

    func testIncompleteAndUnsupportedControls() {
        XCTAssertThrowsError(try prepareControl(current: ["pow":"1"], changes: ControlChanges(power: false), capabilities: capabilities))
        XCTAssertThrowsError(try prepareControl(current: current, changes: ControlChanges(), capabilities: capabilities))
        XCTAssertThrowsError(try prepareControl(current: current, changes: ControlChanges(fan: .quiet), capabilities: Capabilities(temperature: true, fan: false, swing: true)))
    }

    func testMissingSensorIsNotZero() {
        XCTAssertNil(numeric("M"))
        XCTAssertNil(numeric("nan"))
        XCTAssertNil(numeric(nil))
        XCTAssertEqual(numeric("0"), 0)
    }
}

private actor FakeTransport: DaikinTransport {
    var values = current
    var writes = 0
    var rejectWrite = false
    var ignoreWrite = false
    var failReadAfterWrite = false

    init(rejectWrite: Bool = false, ignoreWrite: Bool = false, failReadAfterWrite: Bool = false) {
        self.rejectWrite = rejectWrite
        self.ignoreWrite = ignoreWrite
        self.failReadAfterWrite = failReadAfterWrite
    }

    func get(host: String, path: String, parameters: Fields) async throws -> Fields {
        if path == "/aircon/set_control_info" {
            writes += 1
            if rejectWrite { throw ClimateError.refused }
            if !ignoreWrite { values.merge(parameters) { _, new in new } }
            return ["ret":"OK"]
        }
        if writes > 0 && failReadAfterWrite { throw ClimateError.unreachable }
        switch path {
        case "/common/basic_info": return ["ret":"OK", "type":"aircon", "name":"Test uniquement"]
        case "/aircon/get_model_info": return ["ret":"OK", "temp":"1", "en_frate":"1", "en_fdir":"1"]
        case "/aircon/get_control_info": return values
        case "/aircon/get_sensor_info": return ["ret":"OK", "htemp":"24", "otemp":"14"]
        default: throw ClimateError.invalidResponse
        }
    }
}

final class ClientTests: XCTestCase, @unchecked Sendable {
    func testReadNeverWrites() async throws {
        let fake = FakeTransport()
        let snapshot = try await DaikinClient(transport: fake).read("192.168.1.101")
        let writes = await fake.writes
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(snapshot.room, 24)
    }

    func testOneWriteWithVerifiedReadback() async throws {
        let fake = FakeTransport()
        let outcome = try await DaikinClient(transport: fake).control("192.168.1.101", changes: ControlChanges(target: 21.5))
        let writes = await fake.writes
        XCTAssertEqual(writes, 1)
        XCTAssertTrue(outcome.verified)
        XCTAssertEqual(outcome.snapshot.target, 21.5)
    }

    func testRefusedWriteIsNotRetried() async {
        let fake = FakeTransport(rejectWrite: true)
        do {
            _ = try await DaikinClient(transport: fake).control("192.168.1.101", changes: ControlChanges(power: true))
            XCTFail("Should throw")
        } catch {}
        let writes = await fake.writes
        XCTAssertEqual(writes, 1)
    }

    func testInvalidChangeDoesNotWrite() async {
        let fake = FakeTransport()
        do {
            _ = try await DaikinClient(transport: fake).control("192.168.1.101", changes: ControlChanges(target: 99))
            XCTFail("Should throw")
        } catch {}
        let writes = await fake.writes
        XCTAssertEqual(writes, 0)
    }

    func testAcceptedButUnconfirmedIsNotSuccess() async throws {
        let fake = FakeTransport(ignoreWrite: true)
        let outcome = try await DaikinClient(transport: fake).control("192.168.1.101", changes: ControlChanges(power: true))
        let writes = await fake.writes
        XCTAssertFalse(outcome.verified)
        XCTAssertEqual(writes, 1)
    }

    func testReadbackFailureRetainsOldStateAsOffline() async throws {
        let fake = FakeTransport(failReadAfterWrite: true)
        let outcome = try await DaikinClient(transport: fake).control("192.168.1.101", changes: ControlChanges(power: true))
        XCTAssertFalse(outcome.verified)
        XCTAssertFalse(outcome.snapshot.online)
        let writes = await fake.writes
        XCTAssertEqual(writes, 1)
    }
}
