import CryptoKit
import Foundation
import Security
import XCTest
@testable import AgentLandCore

final class PinnedTrustEvaluatorTests: XCTestCase {
    /// A throwaway self-signed certificate for `localhost`, valid from
    /// 2026-09-01 to 2027-09-01 and shaped like the host's own (P-256, its own
    /// CA, server authentication). Its private key was discarded.
    private static let certificate = Data(base64Encoded: """
        MIIB7zCCAZWgAwIBAgIUHuut2nEbc+wxdsAhztAYld/P/uwwCgYIKoZIzj0EAwIwLTESMBAGA1UEAwwJbG9jYWxob3N0MRcw\
        FQYDVQQKDA5BZ2VudExhbmQgdGVzdDAeFw0yNjA5MDEwMDAwMDBaFw0yNzA5MDEwMDAwMDBaMC0xEjAQBgNVBAMMCWxvY2Fs\
        aG9zdDEXMBUGA1UECgwOQWdlbnRMYW5kIHRlc3QwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAASmO5voPxaWj78tIv4il9mp\
        z9HvdDEUWeP2KjqI9mgvP9HdiVRp61l35gdsMfX5kgJPm/WgcZhEhd1CY0LbW78lo4GSMIGPMB0GA1UdDgQWBBQhJoMfOhsc\
        piATSWsF6peqsZZ21jAfBgNVHSMEGDAWgBQhJoMfOhscpiATSWsF6peqsZZ21jAUBgNVHREEDTALgglsb2NhbGhvc3QwEwYD\
        VR0lBAwwCgYIKwYBBQUHAwEwDgYDVR0PAQH/BAQDAgKEMBIGA1UdEwEB/wQIMAYBAf8CAQAwCgYIKoZIzj0EAwIDSAAwRQIg\
        cNiqlkkPpQ/2oBT4r2u9kQt/lWJOCTyeccdPlyOCauICIQDUIiOmHmvpVQLWR0KHLQc/ybj/s4WvdStI77LHZgze+Q==
        """)!
    private static let fingerprint = SHA256.hash(data: certificate).map { String(format: "%02x", $0) }.joined()
    /// 2027-01-01, inside the certificate's validity.
    private let validDate = Date(timeIntervalSince1970: 1_798_761_600)
    private let serverTrust = NSURLAuthenticationMethodServerTrust

    func testMatchingPinTrustsTheCertificateForTheExpectedHost() throws {
        let evaluator = PinnedTrustEvaluator(expectedHost: "localhost", certificateSHA256: Self.fingerprint)
        let (disposition, credential) = evaluator.evaluate(authenticationMethod: serverTrust, host: "LocalHost", serverTrust: try trust(at: validDate))
        XCTAssertEqual(disposition, .useCredential)
        XCTAssertNotNil(credential)
    }

    func testPinIgnoresCaseAndSeparators() throws {
        let formatted = stride(from: 0, to: Self.fingerprint.count, by: 2).map { offset -> String in
            let start = Self.fingerprint.index(Self.fingerprint.startIndex, offsetBy: offset)
            return String(Self.fingerprint[start..<Self.fingerprint.index(start, offsetBy: 2)]).uppercased()
        }.joined(separator: ":")
        let evaluator = PinnedTrustEvaluator(expectedHost: "localhost", certificateSHA256: formatted)
        XCTAssertEqual(evaluator.evaluate(authenticationMethod: serverTrust, host: "localhost", serverTrust: try trust(at: validDate)).0, .useCredential)
    }

    func testAnyOtherFingerprintIsRejected() throws {
        let other = String(Self.fingerprint.dropLast()) + (Self.fingerprint.last == "0" ? "1" : "0")
        for pin in [other, String(repeating: "0", count: 64), ""] {
            let evaluator = PinnedTrustEvaluator(expectedHost: "localhost", certificateSHA256: pin)
            let (disposition, credential) = evaluator.evaluate(authenticationMethod: serverTrust, host: "localhost", serverTrust: try trust(at: validDate))
            XCTAssertEqual(disposition, .cancelAuthenticationChallenge, "pin \(pin)")
            XCTAssertNil(credential)
        }
    }

    func testChallengeFromAnotherHostIsRejected() throws {
        let evaluator = PinnedTrustEvaluator(expectedHost: "localhost", certificateSHA256: Self.fingerprint)
        XCTAssertEqual(evaluator.evaluate(authenticationMethod: serverTrust, host: "attacker.example", serverTrust: try trust(at: validDate)).0, .cancelAuthenticationChallenge)
        let hostless = PinnedTrustEvaluator(expectedHost: nil, certificateSHA256: Self.fingerprint)
        XCTAssertEqual(hostless.evaluate(authenticationMethod: serverTrust, host: "localhost", serverTrust: try trust(at: validDate)).0, .cancelAuthenticationChallenge)
    }

    func testPinnedCertificateMustStillNameTheValidatedHost() throws {
        // The Mac reaches its own host at 127.0.0.1 and validates the certificate's name separately.
        let loopback = PinnedTrustEvaluator(expectedHost: "127.0.0.1", certificateSHA256: Self.fingerprint, validatedCertificateHost: "localhost")
        XCTAssertEqual(loopback.evaluate(authenticationMethod: serverTrust, host: "127.0.0.1", serverTrust: try trust(at: validDate)).0, .useCredential)
        let wrongName = PinnedTrustEvaluator(expectedHost: "127.0.0.1", certificateSHA256: Self.fingerprint, validatedCertificateHost: "wrong.example")
        XCTAssertEqual(wrongName.evaluate(authenticationMethod: serverTrust, host: "127.0.0.1", serverTrust: try trust(at: validDate)).0, .cancelAuthenticationChallenge)
        let unnamed = PinnedTrustEvaluator(expectedHost: "127.0.0.1", certificateSHA256: Self.fingerprint)
        XCTAssertEqual(unnamed.evaluate(authenticationMethod: serverTrust, host: "127.0.0.1", serverTrust: try trust(at: validDate)).0, .cancelAuthenticationChallenge)
    }

    func testPinnedCertificateOutsideItsValidityIsRejected() throws {
        let evaluator = PinnedTrustEvaluator(expectedHost: "localhost", certificateSHA256: Self.fingerprint)
        for date in [Date(timeIntervalSince1970: 1_822_348_800), Date(timeIntervalSince1970: 1_785_542_400)] { // 2027-10-01, 2026-08-01
            XCTAssertEqual(evaluator.evaluate(authenticationMethod: serverTrust, host: "localhost", serverTrust: try trust(at: date)).0, .cancelAuthenticationChallenge, "\(date)")
        }
    }

    func testPinnedConnectionRejectsOtherChallengesAndMissingTrust() throws {
        let evaluator = PinnedTrustEvaluator(expectedHost: "localhost", certificateSHA256: Self.fingerprint)
        XCTAssertEqual(evaluator.evaluate(authenticationMethod: NSURLAuthenticationMethodHTTPBasic, host: "localhost", serverTrust: try trust(at: validDate)).0, .cancelAuthenticationChallenge)
        XCTAssertEqual(evaluator.evaluate(authenticationMethod: serverTrust, host: "localhost", serverTrust: nil).0, .cancelAuthenticationChallenge)
    }

    func testUnpinnedConnectionUsesPlatformHandling() throws {
        let evaluator = PinnedTrustEvaluator(expectedHost: "localhost", certificateSHA256: nil)
        let (disposition, credential) = evaluator.evaluate(authenticationMethod: serverTrust, host: "localhost", serverTrust: try trust(at: validDate))
        XCTAssertEqual(disposition, .performDefaultHandling)
        XCTAssertNil(credential)
    }

    private func trust(at date: Date) throws -> SecTrust {
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, Self.certificate as CFData))
        var trust: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates(certificate, SecPolicyCreateBasicX509(), &trust), errSecSuccess)
        let created = try XCTUnwrap(trust)
        XCTAssertEqual(SecTrustSetVerifyDate(created, date as CFDate), errSecSuccess)
        return created
    }
}
