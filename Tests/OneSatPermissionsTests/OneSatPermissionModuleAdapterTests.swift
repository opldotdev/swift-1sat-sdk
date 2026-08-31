import BSVTransaction
import BSVWallet
import BSVScript
import OneSatClient
import OneSatTemplates
import ToolboxPermissions
import ToolboxStorage
import XCTest
@testable import OneSatPermissions

final class OneSatPermissionModuleAdapterTests: XCTestCase {
    private let tokenID = String(repeating: "a", count: 64) + "_1"
    private let otherTokenID = String(repeating: "b", count: 64) + "_2"

    func test_bsv21FactsComeFromScriptsAndResolvedInputsNotCallerMetadata() async throws {
        let input = String(repeating: "c", count: 64) + ".3"
        let recipientScript = try Script(
            bytes: [0x76, 0xa9, 0x14] + Array(repeating: 0x11, count: 20) + [0x88, 0xac],
            maximumByteCount: 25
        )
        let request = try createAction(
            inputs: [input],
            outputs: [tokenOutput(
                script: try BSV21.transfer(tokenID: tokenID, amount: "125")
                    .lock(lockingScript: recipientScript).bytes,
                description: "EVIL description",
                customInstructions: #"{"id":"not-a-token","amt":"999999","sym":"EVIL"}"#,
                tags: ["bsv21:\(otherTokenID)", "amt:999999", "sym:EVIL"]
            )]
        )
        let resolver: OneSatPermissionInputResolver = { [tokenID] outpoints in
            [OneSatPermissionResolvedInput(
                outpoint: outpoints[0],
                satoshis: 1,
                lockingScript: try BSV21.transfer(tokenID: tokenID, amount: "200").lock().bytes
            )]
        }

        let review = try await dispatch(
            asset: .bsv21,
            request: .action(.createAction(request)),
            verifier: activeVerifier(tokenID: tokenID, validInputs: [canonical(input)]),
            resolver: resolver
        )

        XCTAssertEqual(review.trust, .init(state: .verified, resolvedName: "GOLD"))
        XCTAssertEqual(review.bsv21Verification?.inputOutpoints, [canonical(input)])
        let details = review.panels.flatMap(\.details)
        XCTAssertTrue(details.contains(.init(label: "Token amount", value: "125")))
        XCTAssertTrue(details.contains(.init(label: "Token amount", value: "200")))
        XCTAssertTrue(details.contains(.init(label: "Token ID", value: tokenID)))
        XCTAssertTrue(details.contains(.init(
            label: "Recipient script",
            value: recipientScript.bytes.map { String(format: "%02x", $0) }.joined()
        )))
        XCTAssertTrue(details.contains(where: { $0.label == "Recipient" && !$0.value.isEmpty }))
        XCTAssertFalse(details.contains(where: { $0.value.contains("EVIL") || $0.value == "999999" }))
        XCTAssertEqual(review.summary, "Review BSV21 transaction")
    }

    func test_callerClaimsCannotPromoteANonTokenScript() async throws {
        let request = try createAction(outputs: [tokenOutput(
            script: [0x51],
            description: "Transfer GOLD",
            customInstructions: #"{"id":"\#(tokenID)","amt":"125"}"#,
            tags: ["bsv21:\(tokenID)"]
        )])

        let review = try await dispatch(asset: .bsv21, request: .action(.createAction(request)))

        XCTAssertEqual(review.trust?.state, .mismatch)
        XCTAssertEqual(review.trust?.note, "An output labeled BSV21 is not a valid BSV21 locking script")
        XCTAssertNil(review.bsv21Verification)
    }

    func test_everyRoutedOutputMustParseBeforeGlobalVerification() async throws {
        let valid = try tokenOutput(
            script: try BSV21.transfer(tokenID: tokenID, amount: "1").lock().bytes
        )
        let invalid = try tokenOutput(script: [0x51], tags: ["bsv21:\(tokenID)"])
        let request = try createAction(outputs: [valid, invalid])

        let review = try await dispatch(
            asset: .bsv21,
            request: .action(.createAction(request)),
            verifier: activeVerifier(tokenID: tokenID)
        )

        XCTAssertEqual(review.trust?.state, .mismatch)
    }

    func test_nonTokenOutputsRemainVisibleInTheAssetReview() async throws {
        let fundingScript: [UInt8] = [0x51]
        let request = try createAction(outputs: [
            tokenOutput(script: try BSV21.deployMint(symbol: "NEW", amount: "1").lock().bytes),
            try WalletCreateActionOutput(
                lockingScript: fundingScript,
                satoshis: 42,
                outputDescription: "Caller says harmless funding"
            ),
        ])

        let review = try await dispatch(asset: .bsv21, request: .action(.createAction(request)))

        let value = try XCTUnwrap(review.panels.first { $0.title == "Value output" })
        XCTAssertTrue(value.details.contains(.init(label: "Satoshis", value: "42")))
        XCTAssertTrue(value.details.contains(.init(label: "Locking script", value: "51")))
    }

    func test_allParsedTokenLegsMustAgreeOnTokenID() async throws {
        let request = try createAction(outputs: [
            tokenOutput(script: try BSV21.transfer(tokenID: tokenID, amount: "1").lock().bytes),
            tokenOutput(script: try BSV21.transfer(tokenID: otherTokenID, amount: "2").lock().bytes),
        ])

        let review = try await dispatch(asset: .bsv21, request: .action(.createAction(request)))

        XCTAssertEqual(review.trust?.state, .mismatch)
        XCTAssertEqual(review.trust?.note, "BSV21 inputs and outputs refer to different tokens")
    }

    func test_unresolvedInputKeepsOtherwiseValidTokenExplicitlyUnverified() async throws {
        let input = String(repeating: "c", count: 64) + ".3"
        let request = try createAction(
            inputs: [input],
            outputs: [tokenOutput(
                script: try BSV21.transfer(tokenID: tokenID, amount: "1").lock().bytes
            )]
        )

        let review = try await dispatch(
            asset: .bsv21,
            request: .action(.createAction(request)),
            verifier: activeVerifier(tokenID: tokenID)
        )

        XCTAssertEqual(review.trust?.state, .unverified)
        XCTAssertNil(review.bsv21Verification)
    }

    func test_existingTokenOutputWithoutVerifiedTokenInputCannotBecomeVerified() async throws {
        let request = try createAction(outputs: [tokenOutput(
            script: try BSV21.transfer(tokenID: tokenID, amount: "1").lock().bytes
        )])
        let review = try await dispatch(
            asset: .bsv21,
            request: .action(.createAction(request)),
            verifier: activeVerifier(tokenID: tokenID)
        )

        XCTAssertEqual(review.trust?.state, .unverified)
        XCTAssertEqual(review.trust?.note, "An existing-token operation has no verified BSV21 input")
        XCTAssertNil(review.bsv21Verification)
    }

    func test_bsv21ListWithoutTokenIDIsLegitimateButUnverified() async throws {
        let request = try WalletListOutputsRequest(basket: "bsv21")
        let review = try await dispatch(asset: .bsv21, request: .action(.listOutputs(request)))

        XCTAssertEqual(review.trust?.state, .unverified)
        XCTAssertEqual(review.panels.first?.details, [
            .init(label: "Basket", value: "bsv21"),
            .init(label: "Requested filters", value: "All"),
        ])
        XCTAssertNil(review.bsv21Verification)
    }

    func test_deployMintAndDeployAuthNeedNoPreexistingTokenID() async throws {
        for script in [
            try BSV21.deployMint(symbol: "NEW", amount: "100", decimals: 2).lock().bytes,
            try BSV21.deployAuth(symbol: "AUTH", decimals: 0).lock().bytes,
        ] {
            let review = try await dispatch(
                asset: .bsv21,
                request: .action(.createAction(try createAction(outputs: [tokenOutput(script: script)])))
            )
            XCTAssertEqual(review.trust?.state, .unverified)
            XCTAssertTrue(review.trust?.note?.contains("assigned only after") == true)
            XCTAssertNil(review.bsv21Verification)
        }
    }

    func test_authHasNoAmountButCanVerifyItsExistingTokenID() async throws {
        let input = String(repeating: "d", count: 64) + ".4"
        let script = try BSV21.auth(tokenID: tokenID).lock().bytes
        let request = try createAction(inputs: [input], outputs: [tokenOutput(script: script)])
        let review = try await dispatch(
            asset: .bsv21,
            request: .action(.createAction(request)),
            verifier: activeVerifier(tokenID: tokenID, validInputs: [input]),
            resolver: { outpoints in
                [.init(outpoint: outpoints[0], satoshis: 1, lockingScript: script)]
            }
        )

        XCTAssertEqual(review.trust?.state, .verified)
        let details = review.panels.flatMap(\.details)
        XCTAssertTrue(details.contains(.init(label: "Operation", value: "auth")))
        XCTAssertFalse(details.contains(where: { $0.label == "Token amount" }))
    }

    func test_currentDeploymentLabelsMapWithoutChangingPlainBaskets() throws {
        XCTAssertEqual(OneSatPermissionAsset.oneSat.basket, "1sat")
        XCTAssertEqual(OneSatPermissionAsset.bsv21.basket, "bsv21")
        XCTAssertEqual(OneSatPermissionAsset.oneSat.deployedSchemeLabels, ["1sat"])
        XCTAssertEqual(OneSatPermissionAsset.bsv21.deployedSchemeLabels, ["bsv21"])
        XCTAssertEqual(try OneSatPermissionAsset.oneSat.registryScheme.rawValue, "onesat")
        XCTAssertEqual(try OneSatPermissionAsset.bsv21.registryScheme.rawValue, "bsv21")
    }

    func test_deployedModuleLabelsAreRoutingMetadataButUnknownSchemesStillDeny() throws {
        let classifier = classifier()
        let routed = WalletRequest.action(.createAction(try WalletCreateActionRequest(
            description: "Routed token action",
            outputs: [tokenOutput(
                script: try BSV21.deployMint(symbol: "NEW", amount: "1").lock().bytes
            )],
            labels: ["p bsv21 action", "ordinary"]
        )))
        let classification = OneSatPermissionAsset.bsv21.canonicalClassification(
            for: routed,
            originator: "example.com",
            classifier: classifier
        )
        guard case .authorizationRequired(let plan) = classification.decision else {
            return XCTFail("Known deployed module labels must reach BRC-116 authorization")
        }
        XCTAssertTrue(plan.requirements.contains { requirement in
            guard case .basketAccess(let scope) = requirement.scope else { return false }
            return scope.basket == "bsv21"
        })
        XCTAssertTrue(plan.requirements.contains { requirement in
            guard case .protocolAccess(let scope) = requirement.scope else { return false }
            return scope.protocolName == "action label ordinary"
        })

        let unknown = WalletRequest.action(.createAction(try WalletCreateActionRequest(
            description: "Unknown route",
            outputs: [tokenOutput(
                script: try BSV21.deployMint(symbol: "NEW", amount: "1").lock().bytes
            )],
            labels: ["p unknown action"]
        )))
        XCTAssertEqual(
            OneSatPermissionAsset.bsv21.canonicalClassification(
                for: unknown,
                originator: "example.com",
                classifier: classifier
            ).decision,
            .denied(.unsupportedPermissionScheme(kind: "label", scheme: "unknown"))
        )
    }

    func test_plainOneSatBasketUsesOrdinalStylingButRemainsUnverified() async throws {
        let request = try WalletListOutputsRequest(basket: "1sat", tags: ["collection:example"])
        let review = try await dispatch(asset: .oneSat, request: .action(.listOutputs(request)))

        XCTAssertEqual(review.panels.first?.variant, .ordinal)
        XCTAssertEqual(review.trust?.state, .unverified)
        XCTAssertTrue(review.trust?.note?.contains("no scripts to verify") == true)
        XCTAssertEqual(review.summary, "View 1sat outputs")
    }

    func test_plainOneSatCreateActionDoesNotPromoteBasketMetadataToOrdinalFact() async throws {
        let review = try await dispatch(asset: .oneSat, request: .action(.createAction(.init(
            description: "Untrusted app description",
            outputs: [.init(
                lockingScript: [0x51],
                satoshis: 1,
                outputDescription: "Caller says Ordinal",
                basket: "1sat",
                customInstructions: "untrusted"
            )]
        ))))

        XCTAssertEqual(review.summary, "Review 1Sat basket transaction")
        XCTAssertEqual(review.panels.first?.title, "Basket-labeled output")
        XCTAssertEqual(review.trust?.state, .unverified)
        XCTAssertTrue(review.trust?.note?.contains("not proof") == true)
    }

    func test_irrelevantBasketProducesNoReview() async throws {
        let codec = try makeCodec()
        let registry = try PermissionModuleRegistry()
        try await registry.register(
            OneSatPermissionModuleAdapter(asset: .bsv21, codec: codec),
            for: OneSatPermissionAsset.bsv21.registryScheme
        )
        let request = WalletRequest.action(.listOutputs(try WalletListOutputsRequest(basket: "1sat")))
        let result = try await registry.dispatch(
            scheme: OneSatPermissionAsset.bsv21.registryScheme,
            request: request,
            originator: "example.com",
            canonicalDecision: classifier().classify(request, originator: "example.com").decision,
            codec: codec
        )
        guard case .reviewed(let moduleReview) = result else { return XCTFail("Expected review") }
        XCTAssertNil(moduleReview.serializedReview)
    }

    private func tokenOutput(
        script: [UInt8],
        description: String = "Caller supplied description",
        customInstructions: String? = nil,
        tags: [String] = []
    ) throws -> WalletCreateActionOutput {
        try WalletCreateActionOutput(
            lockingScript: script,
            satoshis: 1,
            outputDescription: description,
            basket: "bsv21",
            customInstructions: customInstructions,
            tags: tags
        )
    }

    private func createAction(
        inputs: [String] = [],
        outputs: [WalletCreateActionOutput]
    ) throws -> WalletCreateActionRequest {
        try WalletCreateActionRequest(
            description: "Caller supplied transaction description",
            inputs: try inputs.map {
                try WalletCreateActionInput(
                    outpoint: Outpoint($0),
                    inputDescription: "Caller supplied input description",
                    unlockingScriptLength: 108
                )
            },
            outputs: outputs,
            labels: []
        )
    }

    private func activeVerifier(
        tokenID: String,
        validInputs: [String] = []
    ) -> Bsv21PermissionVerifier {
        Bsv21PermissionVerifier(services: .init(
            tokenDetails: { requested in
                .init(
                    tokenID: requested,
                    token: .init(id: requested, symbol: "GOLD", decimals: "2", icon: nil),
                    status: .init(isActive: true)
                )
            },
            validateOutputs: { _, _ in validInputs.map { .init(outpoint: $0) } }
        ))
    }

    private func dispatch(
        asset: OneSatPermissionAsset,
        request: WalletRequest,
        verifier: Bsv21PermissionVerifier? = nil,
        resolver: OneSatPermissionInputResolver? = nil
    ) async throws -> OneSatAssetPermissionReview {
        let codec = try makeCodec()
        let registry = try PermissionModuleRegistry()
        try await registry.register(
            OneSatPermissionModuleAdapter(
                asset: asset,
                codec: codec,
                verifier: verifier,
                resolveInputs: resolver
            ),
            for: asset.registryScheme
        )
        let classification = classifier().classify(request, originator: "Example.COM")
        let result = try await registry.dispatch(
            scheme: asset.registryScheme,
            request: request,
            originator: "Example.COM",
            canonicalDecision: classification.decision,
            codec: codec
        )
        guard case .reviewed(let moduleReview) = result,
              let data = moduleReview.serializedReview else { throw TestError.missingReview }
        return try JSONDecoder().decode(OneSatAssetPermissionReview.self, from: data)
    }

    private func canonical(_ outpoint: String) -> String {
        outpoint.replacingOccurrences(of: ".", with: "_")
    }

    private func makeCodec() throws -> WalletBRC100JSONCodec {
        try WalletBRC100JSONCodec(
            beefLimits: StorageLimits.beef,
            maximumJSONByteCount: 1 << 20
        )
    }

    private func classifier() -> WalletPermissionClassifier {
        try! WalletPermissionClassifier(
            policy: WalletPermissionPolicy(adminOriginator: "admin.onesat.wallet")
        )
    }

    private enum TestError: Error { case missingReview }
}
