import Foundation
import Testing

@Suite struct PerfHooksSweepTests {
    private let condition = "#if DEBUG || MXU_PERF_HOOKS"

    @Test func theHooksCompileOnlyUnderTheirCondition() throws {
        let sweep = try SourceSweep.app()
        let hooks = try #require(sweep.file("PerfHooks.swift"))
        let code = hooks.lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        #expect(code.first == condition, "PerfHooks.swift starts with \(condition)")
        #expect(code.last == "#endif")

        let uses = ["PerfHooks.", "perfEditor", "perfPressPoints", "MXU_PERF_SCENARIO"]
        for file in sweep.files where file.name != "PerfHooks.swift" {
            var depth = 0
            var guarded: [Bool] = []
            for (index, line) in file.lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#if") {
                    guarded.append(trimmed == condition)
                    depth += 1
                } else if trimmed.hasPrefix("#else") || trimmed.hasPrefix("#elseif"), depth > 0 {
                    guarded[guarded.count - 1] = false
                } else if trimmed.hasPrefix("#endif"), depth > 0 {
                    guarded.removeLast()
                    depth -= 1
                } else if uses.contains(where: file.code(index).contains) {
                    #expect(guarded.contains(true), "\(file.name):\(index + 1) uses a perf hook outside \(condition)")
                }
            }
        }
    }

    @Test func noShippedBuildDefinesTheCondition() throws {
        let mac = SourceSweep.macRoot()
        for path in ["project.yml", "scripts/release-dmg.sh"] {
            let text = try String(contentsOf: mac.appendingPathComponent(path), encoding: .utf8)
            #expect(!text.contains("MXU_PERF_HOOKS"), "\(path) must not build the perf hooks into a release")
        }
    }

    @Test func theScriptBuildsTheHooksAndLaunchesSafely() throws {
        let run = try String(
            contentsOf: SourceSweep.macRoot().appendingPathComponent("scripts/perf/run.sh"), encoding: .utf8)
        #expect(run.contains("'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) MXU_PERF_HOOKS'"))
        #expect(run.contains("-configuration Release"))

        let launch = try #require(run.range(of: "launch() {"))
        let body = String(run[launch.upperBound...].prefix(400))
        for part in ["CFFIXED_USER_HOME=$1", "MXU_SKIP_KEYCHAIN=1", "sandbox-exec -f \"$HERE/nonet.sb\""] {
            #expect(body.contains(part), "every launch sets \(part)")
        }
        #expect(run.components(separatedBy: "\"$BIN\"").count == 2, "the staged binary starts only in launch()")

        #expect(run.contains("DOMAIN=com.example.mxuslides.perf"))
        #expect(run.contains("Set :CFBundleIdentifier $DOMAIN"))
        let profile = try String(
            contentsOf: SourceSweep.macRoot().appendingPathComponent("scripts/perf/nonet.sb"), encoding: .utf8)
        #expect(profile.contains("(deny network-outbound (remote ip))"))
    }

    @Test func theDefaultKeyVaultHonorsTheKeychainSkip() throws {
        let sweep = try SourceSweep.app()
        let controller = try #require(sweep.file("LocalAPIController.swift")).text
        let vault = try #require(controller.range(of: "static let vault = "))
        let declaration = String(controller[vault.lowerBound...].prefix(600))
        #expect(declaration.contains("honorsSkipKeychain && ProcessInfo.processInfo.environment[\"MXU_SKIP_KEYCHAIN\"] == \"1\""))
        #expect(declaration.contains("APIDefaultKeyVault.inMemory()"))
        #expect(controller.contains("#if DEBUG || MXU_PERF_HOOKS\n    private static let honorsSkipKeychain = true"))
    }
}
