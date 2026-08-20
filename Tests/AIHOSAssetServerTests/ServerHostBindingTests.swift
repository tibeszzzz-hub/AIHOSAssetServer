import Testing
import Foundation
@testable import AIHOSAssetServer

// MARK: - TAILNET-G1: environment-driven Vapor bind address
//
// Order WFOS-20260818-PSKS-005. Makes the bind address configurable without changing
// today's production behaviour: with the variable absent the server binds to 0.0.0.0
// exactly as before.
//
// Why the allowed set is closed and why an unknown value refuses startup: a bind
// address is a security control. Falling back to a default on an unrecognised value
// could turn an intended loopback-only binding into a broad public one because of a
// typo, and nothing would report it. So the resolver fails closed (§9.3, R17).

@Suite("G1 bind address configuration contract")
struct ServerHostContractTests {

    @Test("Absent variable keeps today's binding exactly")
    func absentVariableKeepsCurrentBehaviour() throws {
        #expect(try resolvedServerHost(fromConfiguredValue: nil) == "0.0.0.0")
        #expect(defaultServerHost == "0.0.0.0")
    }

    @Test("Positive control: both operating modes are accepted")
    func allowedValuesAccepted() throws {
        #expect(try resolvedServerHost(fromConfiguredValue: "0.0.0.0") == "0.0.0.0")
        #expect(try resolvedServerHost(fromConfiguredValue: "127.0.0.1") == "127.0.0.1")

        // Surrounding whitespace in a deployment variable is stripped, as elsewhere.
        #expect(try resolvedServerHost(fromConfiguredValue: "  127.0.0.1 \n") == "127.0.0.1")
    }

    @Test("The allowed set is exactly these two addresses")
    func allowedSetIsClosed() {
        #expect(allowedServerHosts == ["0.0.0.0", "127.0.0.1"])
    }

    @Test("Present but empty or blank refuses startup rather than falling back")
    func emptyValueThrows() {
        // A variable someone took the trouble to set, but set wrongly, must never be
        // silently ignored — that is the difference between absent and empty.
        #expect(throws: ServerHostError.self) {
            _ = try resolvedServerHost(fromConfiguredValue: "")
        }
        #expect(throws: ServerHostError.self) {
            _ = try resolvedServerHost(fromConfiguredValue: "   ")
        }
        #expect(throws: ServerHostError.self) {
            _ = try resolvedServerHost(fromConfiguredValue: " \n\t ")
        }
    }

    @Test("Negative control: unknown, misspelled and wildcard forms all refuse startup")
    func unknownValueThrows() {
        for rejected in [
            "localhost",        // would need DNS interpretation
            "0.0.0.O",          // letter O instead of zero — the typo this guards
            "0.0.0.1",
            "127.0.0.2",
            "::1",
            "::",
            "*",
            "0.0.0.0/0",
            "0.0.0.0:8080",
            "127.0.0.1,0.0.0.0",
            "100.64.0.1",       // a CGNAT address must not become bindable by accident
            "example.com"
        ] {
            #expect(throws: ServerHostError.self, "Accepted an address outside the allowed set: \(rejected)") {
                _ = try resolvedServerHost(fromConfiguredValue: rejected)
            }
        }
    }

    @Test("The error names the variable and the allowed values without echoing the input")
    func errorIsActionableAndDoesNotEcho() {
        let description = ServerHostError().description

        #expect(description.contains("AIHOS_SERVER_HOST"))
        #expect(description.contains("0.0.0.0"))
        #expect(description.contains("127.0.0.1"))

        // The rejected value is deliberately not echoed: with only two valid values the
        // error is already actionable, and echoing whatever ended up in the variable
        // would write it to the boot log if it was pasted there by mistake.
        #expect(ServerHostError().description.contains("secret") == false)
    }

    @Test("The environment key is the reported, stable name")
    func environmentKeyIsStable() {
        #expect(serverHostEnvironmentKey == "AIHOS_SERVER_HOST")
    }
}

// MARK: - Application of the contract

@Suite("G1 binding is applied and the port contract is untouched")
struct ServerHostApplicationTests {

    @Test("main resolves the host and binds to the resolved value, not a literal")
    func bindingUsesTheResolver() throws {
        let lines = trimmedSourceLines(try serverSourceText())

        #expect(lines.contains { $0 == "let serverHost = try resolvedServerHost()" })
        #expect(lines.contains { $0 == "app.http.server.configuration.hostname = serverHost" })

        // The old literal binding must be gone from the assignment.
        #expect(lines.contains { $0 == #"app.http.server.configuration.hostname = "0.0.0.0""# } == false)
    }

    @Test("The PORT contract and the 8080 fallback are byte-identical")
    func portContractUnchanged() throws {
        let lines = trimmedSourceLines(try serverSourceText())

        for expected in [
            #"if let portString = Environment.get("PORT"), let port = Int(portString) {"#,
            "app.http.server.configuration.port = port",
            #"print("HTTP Server Port from Render PORT: \(port)")"#,
            "app.http.server.configuration.port = 8080",
            #"print("HTTP Server Port default: 8080")"#
        ] {
            #expect(lines.contains { $0 == expected }, "Port contract line changed or missing: \(expected)")
        }
    }

    @Test("The boot log reports the effective host and no other configuration value")
    func bootLogShowsHostOnly() throws {
        let lines = trimmedSourceLines(try serverSourceText())

        #expect(lines.contains { $0 == #"print("HTTP Server Host: \(serverHost)")"# })

        // The bind address is not secret and is useful in the boot log. No other
        // environment value may be printed alongside it.
        #expect(lines.contains { $0.contains("print") && $0.contains("Environment.get") } == false)
    }

    @Test("Resolution happens before the server starts accepting connections")
    func resolutionPrecedesServerStart() throws {
        let lines = trimmedSourceLines(try serverSourceText())

        let resolveIndex = try #require(lines.firstIndex { $0 == "let serverHost = try resolvedServerHost()" })
        let bindIndex = try #require(lines.firstIndex { $0 == "app.http.server.configuration.hostname = serverHost" })
        let executeIndex = try #require(lines.firstIndex { $0 == "try await app.execute()" })

        #expect(resolveIndex < bindIndex)
        #expect(bindIndex < executeIndex)
    }
}

// MARK: - AC-6 absence guard

@Suite("G1 negative guard: no remote-access integration in the production source")
struct RemoteAccessAbsenceTests {

    /// The four shapes G1 must not have introduced, as (label, pattern, options).
    private static let forbiddenPatterns: [(label: String, pattern: String, options: String.CompareOptions)] = [
        ("mesh product name", "tailscale|tailnet", [.regularExpression, .caseInsensitive]),
        ("agent environment variables", #"\bTS_[A-Z0-9]"#, [.regularExpression]),
        ("agent state directory", "/var/lib/tailscale", [.regularExpression, .caseInsensitive]),
        ("CGNAT address range", #"\b100\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\b"#, [.regularExpression])
    ]

    @Test("Positive control: the scan actually reads every production source file")
    func scanReachesTheSource() throws {
        let sources = try productionSourceTexts()

        // Without this control a zero result below could just as well mean the scan
        // looked at the wrong directory, or at nothing at all. Since F-B that means
        // both production targets: the library and the runner.
        #expect(sources.count == 23, "Production sources found: \(sources.map(\.name))")
        #expect(sources.map(\.name) == [
            "AIHOSAssetServer.swift",
            "APIContentDTOs.swift",
            "FileDeliveryRoutes.swift",
            "LaneValidationHelpers.swift",
            "MachineAuthGate.swift",
            "MechanicalGapReadRoutes.swift",
            "NightPhotoStandardRoutes.swift",
            "ObservationDecisionTraceReadRoutes.swift",
            "ObservationRecordReadRoutes.swift",
            "ObservationWindowHelpers.swift",
            "OperationalPulseReadRoutes.swift",
            "OperationalStandardHelpers.swift",
            "OperationalStandardReadRoutes.swift",
            "OperationsTimeHelpers.swift",
            "PayloadTextReadRoutes.swift",
            "RuntimeConfigurationHelpers.swift",
            "SchemaMigrations.swift",
            "ShiftHandoverReadRoutes.swift",
            "StandardStatusTimelineReadRoutes.swift",
            "TimestampDiagnostics.swift",
            "TimestampFormattingHelpers.swift",
            "TriggerMigrations.swift",
            "main.swift"
        ])

        // A term that genuinely exists, matched with the same machinery as the
        // forbidden ones, proving the matcher works and is pointed at real content.
        #expect(matchCount(ofPattern: "MachineAuthGate", options: [.regularExpression], in: sources) > 0)
        #expect(matchCount(ofPattern: #"\bAIHOS_[A-Z0-9_]+"#, options: [.regularExpression], in: sources) > 0)
    }

    @Test("Negative control: the matcher reports a hit when one is planted")
    func matcherCanFindAHit() {
        // Proves each forbidden pattern is capable of matching, so a zero on real
        // sources means absence rather than a broken pattern.
        let planted: [(name: String, text: String)] = [
            ("planted.swift", """
            let a = "tailscale up"
            let b = TS_AUTHKEY
            let c = "/var/lib/tailscale"
            let d = "100.64.0.1"
            """)
        ]

        for forbidden in Self.forbiddenPatterns {
            #expect(matchCount(ofPattern: forbidden.pattern, options: forbidden.options, in: planted) > 0,
                    "Pattern never matches anything: \(forbidden.label)")
        }
    }

    @Test("The production source contains none of the forbidden forms")
    func productionSourceIsClean() throws {
        let sources = try productionSourceTexts()

        for forbidden in Self.forbiddenPatterns {
            let hits = matchCount(ofPattern: forbidden.pattern, options: forbidden.options, in: sources)
            #expect(hits == 0, "\(forbidden.label): \(hits) hit(s) in the production source")
        }
    }
}
