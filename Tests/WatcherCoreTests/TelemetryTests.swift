import XCTest
@testable import WatcherCore

final class TelemetryTests: XCTestCase {
    func testTrafficUsesElapsedTimeAndStartsWithoutInventedZero() {
        var calculator = TrafficCalculator()
        XCTAssertNil(calculator.consume(.init(name: "wifi", received: 100, sent: 200, monotonicTime: 1)))
        let rate = calculator.consume(.init(name: "wifi", received: 1100, sent: 700, monotonicTime: 3))
        XCTAssertEqual(rate?.download, 500)
        XCTAssertEqual(rate?.upload, 250)
    }
    func testCounterResetInterfaceChangeAndWakeUpStartNewBaselines() {
        var calculator = TrafficCalculator()
        _ = calculator.consume(.init(name: "one", received: 1000, sent: 1000, monotonicTime: 1))
        XCTAssertNil(calculator.consume(.init(name: "one", received: 1, sent: 1, monotonicTime: 2)))
        XCTAssertNil(calculator.consume(.init(name: "two", received: 500, sent: 500, monotonicTime: 3)))
        XCTAssertNil(calculator.consume(.init(name: "two", received: 1000, sent: 1000, monotonicTime: 100)))
        XCTAssertEqual(calculator.consume(.init(name: "two", received: 1000, sent: 1000, monotonicTime: 101))?.download, 0)
        XCTAssertNil(calculator.consume(nil))
        XCTAssertNil(calculator.consume(.init(name: "two", received: 2000, sent: 2000, monotonicTime: 102)))
    }
    func testNonIncreasingTimestampDoesNotDivideByZero() {
        var calculator = TrafficCalculator()
        _ = calculator.consume(.init(name: "wifi", received: 1, sent: 1, monotonicTime: 1))
        XCTAssertNil(calculator.consume(.init(name: "wifi", received: 2, sent: 2, monotonicTime: 1)))
    }
    func testSignalMissingValuesAreUnknown() {
        let wifi = WiFiDetails(name: nil, interfaceName: "wifi", rssi: 0, noise: 0, phyMode: 0, transmitMbps: 0)
        XCTAssertNil(wifi.rssi); XCTAssertNil(wifi.noise); XCTAssertNil(wifi.signalToNoise); XCTAssertNil(wifi.transmitMbps)
        XCTAssertEqual(wifi.signalLevel, 0)
        XCTAssertEqual(wifi.generation, "协议未知")
    }
    func testSignalAndWiFiGenerationAreDistinctFromInternetHealth() {
        let wifi = WiFiDetails(name: nil, interfaceName: "wifi", rssi: -57, noise: -97, phyMode: 6, bandGHz: 5, transmitMbps: 344)
        XCTAssertEqual(wifi.signalToNoise, 40)
        XCTAssertEqual(wifi.generation, "Wi-Fi 6")
        XCTAssertEqual(wifi.signalLevel, 3)
        XCTAssertEqual(WiFiDetails(name: nil, interfaceName: nil, rssi: nil, noise: nil, phyMode: 6, bandGHz: 6).generation, "Wi-Fi 6E")
        XCTAssertEqual(WiFiDetails(name: nil, interfaceName: nil, rssi: nil, noise: nil, phyMode: 7).generation, "Wi-Fi 7")
        XCTAssertEqual(WiFiDetails(name: nil, interfaceName: nil, rssi: nil, noise: nil, phyMode: 8).generation, "协议未知")
    }
    func testUnknownAndKnownZeroRatesHaveDifferentLabels() {
        XCTAssertEqual(TrafficFormat.rate(nil), "—")
        XCTAssertEqual(TrafficFormat.rate(0), "0 B/s")
        XCTAssertEqual(TrafficFormat.rate(2048), "2.0 KB/s")
        XCTAssertEqual(TrafficFormat.rate(.infinity), "—")
    }
}
