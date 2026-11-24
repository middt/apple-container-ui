import Foundation
import Testing
@testable import AppleContainerUI

@Suite struct ShellWordsTests {
    @Test func splitsQuotedArguments() {
        #expect(ShellWords.split(#"sh -c "echo 'a b'  && ls""#) == ["sh", "-c", "echo 'a b'  && ls"])
        #expect(ShellWords.split("nginx -g 'daemon off;'") == ["nginx", "-g", "daemon off;"])
        #expect(ShellWords.split(#"echo a\ b "" ''"#) == ["echo", "a b", "", ""])
        #expect(ShellWords.split("   ") == [])
    }

    @Test func quoteRoundTripsThroughSplit() {
        let nasty = ["plain", "two words", "it's", "$(rm -rf /)", "a;b", "\"dq\"", "", "tab\there", "ünïcode ✓"]
        #expect(ShellWords.split(ShellWords.join(nasty)) == nasty)
    }

    @Test func quotedArgumentsSurviveARealShell() async {
        let nasty = ["x'; echo INJECTED; '", "$(echo INJECTED)", "`echo INJECTED`", "a b"]
        let line = "printf '%s\\n' " + ShellWords.join(nasty)
        let result = await ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", line], displayCommand: "sh")
        #expect(result.stdout == nasty.joined(separator: "\n") + "\n")
    }

    @Test func terminalScriptCannotBeEscaped() {
        let script = ContainerCLIService.terminalScriptSource(arguments: [
            "/usr/local/bin/container", "exec", "-it", "web\"; do shell script \"rm -rf ~", "/bin/sh"
        ])
        // The hostile name must stay inside one AppleScript string: every inner quote is escaped.
        let body = script.components(separatedBy: "do script ")[1].components(separatedBy: "\nend tell")[0]
        #expect(body.hasPrefix("\"") && body.hasSuffix("\""))
        let inner = String(body.dropFirst().dropLast())
        #expect(!inner.replacingOccurrences(of: "\\\\", with: "").replacingOccurrences(of: "\\\"", with: "").contains("\""))
        #expect(inner.contains("'web"))
    }
}

@Suite struct ProcessRunnerTests {
    @Test func largeOutputDoesNotDeadlock() async {
        // 1 MB on stdout and 1 MB on stderr: far beyond the 64 KB pipe buffer.
        let script = "head -c 1048576 /dev/zero | tr '\\0' 'a'; head -c 1048576 /dev/zero | tr '\\0' 'b' 1>&2"
        let result = await ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", script], displayCommand: "sh", timeout: 30)
        #expect(result.exitCode == 0)
        #expect(result.stdout.count == 1_048_576)
        #expect(result.stderr.count == 1_048_576)
    }

    @Test func reportsExitCodeAndStderr() async {
        let result = await ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", "echo oops 1>&2; exit 3"], displayCommand: "sh")
        #expect(result.exitCode == 3)
        #expect(!result.succeeded)
        #expect(result.failureMessage == "oops")
    }

    @Test func missingBinaryFailsInsteadOfCrashing() async {
        let result = await ProcessRunner.run(executable: "/nonexistent/container", arguments: ["list"], displayCommand: "container list")
        #expect(result.exitCode == -1)
        #expect(!result.stderr.isEmpty)
    }

    @Test func timeoutTerminatesTheProcess() async {
        let result = await ProcessRunner.run(executable: "/bin/sleep", arguments: ["30"], displayCommand: "sleep 30", timeout: 0.5)
        #expect(!result.succeeded)
        #expect(result.stderr.contains("Timed out"))
        #expect(result.durationMs < 10_000)
    }

    @Test func doesNotWaitForStandardInput() async {
        let result = await ProcessRunner.run(executable: "/bin/cat", arguments: [], displayCommand: "cat", timeout: 10)
        #expect(result.exitCode == 0)
    }

    @Test func commandLabelUsesTheRealToolName() async {
        let docker = LiveCLIRuntime(backend: .dockerEngine, path: "/bin/echo")
        let result = await docker.run(["compose", "-p", "my stack", "up", "-d"])
        #expect(result.command == "docker compose -p 'my stack' up -d")
        let apple = LiveCLIRuntime(backend: .appleContainer, path: "/bin/echo")
        #expect(await apple.run(["list"]).command == "container list")
    }

    @Test func missingCLIFailsEveryCommandWithAClearMessage() async {
        let runtime = UnavailableRuntime(backend: .appleContainer)
        let result = await runtime.run(["start", "web"])
        #expect(!result.succeeded && !runtime.isAvailable)
        #expect(result.command == "container start web")
        #expect(result.stderr.contains("not found"))
        #expect(LiveCLIRuntime(backend: .dockerEngine, path: "/bin/echo").isAvailable)
    }
}
