// hibermate-hook: called by AI agent hooks (Claude Code and others).
//
// Contract (invariant 4): it always exits 0, never writes to stdout or
// stderr, finishes fast, and does nothing if Hibermate isn't set up.

import Darwin
import Foundation
import HibermateCore

// Hard stop: whatever happens, exit 0 within one second.
signal(SIGALRM) { _ in _exit(0) }
alarm(1)
// Never let a closed pipe kill us with a non-zero status.
signal(SIGPIPE, SIG_IGN)

// Silence anything the runtime might print.
let devNull = open("/dev/null", O_WRONLY)
if devNull >= 0 {
    dup2(devNull, STDOUT_FILENO)
    dup2(devNull, STDERR_FILENO)
}

let arguments = Array(CommandLine.arguments.dropFirst())
let (parser, _) = HookRunner.parser(for: arguments)
// Only parsers that consume stdin read it; the generic one takes argv only.
let input: Data = parser.agent == .generic ? Data() : FileHandle.standardInput.readDataToEndOfFile()

HookRunner.run(
    arguments: arguments,
    input: input,
    context: HookRunner.Context(
        paths: HibermatePaths(),
        now: Date().timeIntervalSince1970,
        parentPID: getppid(),
        processTable: DarwinProcessTable()
    )
)
exit(0)
