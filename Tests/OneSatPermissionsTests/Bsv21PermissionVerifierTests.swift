import OneSatClient
import XCTest
@testable import OneSatPermissions

final class Bsv21PermissionVerifierTests: XCTestCase {
    private let tokenID = String(repeating: "a", count: 64) + "_1"
    private let input = String(repeating: "b", count: 64) + ".2"

    func test_activeTokenAndValidInputsAreVerified() async {
        let verifier = makeVerifier(outputs: [.init(outpoint: canonical(input))])

        let result = await verifier.verify(.init(
            tokenID: tokenID,
            claimedSymbol: "gold",
            inputOutpoints: [input]
        ))

        XCTAssertEqual(result, .init(state: .verified, resolvedName: "GOLD"))
    }

    func test_inactiveTokenIsMismatch() async {
        let verifier = makeVerifier(active: false)

        let result = await verifier.verify(.init(tokenID: tokenID))

        XCTAssertEqual(result, .init(
            state: .mismatch,
            note: "Token is not active on the overlay"
        ))
    }

    func test_responseTokenIdentifiersMustMatchTheRequestedToken() async {
        let different = String(repeating: "c", count: 64) + "_3"
        let outerMismatch = verifier(detailsTokenID: different, nestedTokenID: tokenID)
        let nestedMismatch = verifier(detailsTokenID: tokenID, nestedTokenID: different)

        let outer = await outerMismatch.verify(.init(tokenID: tokenID))
        let nested = await nestedMismatch.verify(.init(tokenID: tokenID))

        XCTAssertEqual(outer, .init(
            state: .mismatch,
            note: "Token details do not match the requested token"
        ))
        XCTAssertEqual(nested, outer)
    }

    func test_symbolOrInputContradictionsAreMismatch() async {
        let symbol = await makeVerifier().verify(.init(tokenID: tokenID, claimedSymbol: "SILVER"))
        let input = await makeVerifier(outputs: []).verify(.init(
            tokenID: tokenID,
            inputOutpoints: [self.input]
        ))

        XCTAssertEqual(symbol.state, .mismatch)
        XCTAssertEqual(symbol.note, "Token symbol is GOLD, not SILVER")
        XCTAssertEqual(input.state, .mismatch)
        XCTAssertEqual(input.note, "A spent token output is not valid on the overlay")
    }

    func test_serviceFailureAndTimeoutStayUnverified() async {
        enum Expected: Error { case failed }
        let failed = Bsv21PermissionVerifier(services: .init(tokenDetails: { _ in
            throw Expected.failed
        }))
        let slow = Bsv21PermissionVerifier(
            services: .init(tokenDetails: { _ in
                try await Task.sleep(for: .seconds(1))
                throw Expected.failed
            }),
            timeout: .milliseconds(5)
        )
        let validationFailed = Bsv21PermissionVerifier(services: .init(
            tokenDetails: { [tokenID] _ in
                .init(
                    tokenID: tokenID,
                    token: .init(id: tokenID, symbol: "GOLD", decimals: "2", icon: nil),
                    status: .init(isActive: true)
                )
            },
            validateOutputs: { _, _ in throw Expected.failed }
        ))

        let failedResult = await failed.verify(.init(tokenID: tokenID))
        let slowResult = await slow.verify(.init(tokenID: tokenID))
        let validationResult = await validationFailed.verify(.init(
            tokenID: tokenID,
            inputOutpoints: [input]
        ))

        XCTAssertEqual(failedResult.state, .unverified)
        XCTAssertEqual(slowResult.state, .unverified)
        XCTAssertEqual(validationResult.state, .unverified)
    }

    func test_tokenInputsCannotVerifyWithoutAnOutputValidator() async {
        let verifier = Bsv21PermissionVerifier(services: .init(tokenDetails: { [tokenID] _ in
            .init(
                tokenID: tokenID,
                token: .init(id: tokenID, symbol: "GOLD", decimals: "2", icon: nil),
                status: .init(isActive: true)
            )
        }))

        let result = await verifier.verify(.init(
            tokenID: tokenID,
            inputOutpoints: [input]
        ))

        XCTAssertEqual(result, .init(
            state: .unverified,
            note: "Token input validation is unavailable"
        ))
    }

    func test_timeoutDoesNotAwaitAnOperationThatIgnoresCancellation() async {
        let verifier = Bsv21PermissionVerifier(
            services: .init(tokenDetails: { [tokenID] _ in
                let clock = ContinuousClock()
                let finish = clock.now.advanced(by: .milliseconds(300))
                while clock.now < finish {
                    await Task.yield()
                }
                return .init(
                    tokenID: tokenID,
                    token: .init(id: tokenID, symbol: "GOLD", decimals: "2", icon: nil),
                    status: .init(isActive: true)
                )
            }),
            timeout: .milliseconds(10)
        )
        let clock = ContinuousClock()
        let start = clock.now

        let result = await verifier.verify(.init(tokenID: tokenID))
        let elapsed = start.duration(to: clock.now)

        XCTAssertEqual(result.state, .unverified)
        XCTAssertLessThan(elapsed, .milliseconds(150))
    }

    func test_reviewRoundTripsAcrossProcessBoundaryAndAcceptsVerification() throws {
        let review = OneSatAssetPermissionReview(
            requestID: UUID(),
            originator: "example.com",
            summary: "Send BSV21",
            panels: [.init(
                title: "Send GOLD",
                subtitle: "1.00 GOLD",
                variant: .token,
                details: [.init(label: "Token", value: tokenID)]
            )],
            trust: .init(state: .unverified),
            bsv21Verification: .init(tokenID: tokenID, inputOutpoints: [input])
        )

        let decoded = try JSONDecoder().decode(
            OneSatAssetPermissionReview.self,
            from: JSONEncoder().encode(review)
        )
        let verified = decoded.applying(.init(state: .verified, resolvedName: "GOLD"))

        XCTAssertEqual(decoded, review)
        XCTAssertEqual(verified.trust?.state, .verified)
        XCTAssertEqual(verified.panels, review.panels)
    }

    private func makeVerifier(
        active: Bool? = true,
        outputs: [Bsv21ValidatedOutput] = []
    ) -> Bsv21PermissionVerifier {
        Bsv21PermissionVerifier(services: .init(
            tokenDetails: { [tokenID] _ in
                .init(
                    tokenID: tokenID,
                    token: .init(id: tokenID, symbol: "GOLD", decimals: "2", icon: nil),
                    status: .init(isActive: active)
                )
            },
            validateOutputs: { _, _ in outputs }
        ))
    }

    private func verifier(
        detailsTokenID: String,
        nestedTokenID: String
    ) -> Bsv21PermissionVerifier {
        Bsv21PermissionVerifier(services: .init(tokenDetails: { _ in
            .init(
                tokenID: detailsTokenID,
                token: .init(id: nestedTokenID, symbol: "GOLD", decimals: "2", icon: nil),
                status: .init(isActive: true)
            )
        }))
    }

    private func canonical(_ value: String) -> String {
        value.replacingOccurrences(of: ".", with: "_")
    }
}
