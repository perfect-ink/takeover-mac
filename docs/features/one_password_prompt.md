# One password prompt per install

Steps that need administrator rights (moving a folder out of `/Library`, creating the link there, installing a .pkg or copying an app into /Applications) go through `PrivilegedShell.run` in `Shared/Lib/SystemOps.swift`.

- It runs `do shell script … with administrator privileges` in the app's own process through NSAppleScript, on the main thread. macOS remembers that authorization for about five minutes, so an install that needs several privileged steps asks for the password once.
- Before this, each step started its own `osascript` process, and each one asked again: installing a sync setting under `/Library` asked twice (move, then link).
- Arguments are single-quoted for the shell and the command escaped as an AppleScript string, so paths with quotes, spaces or `$(…)` stay literal.

## Known limits

- After about five minutes, the next privileged step asks again.
- Not checked on a Mac in this change (written in a Linux session); the GitHub Actions build compiles it.

## History

- Implemented 2026-11-15, after Alex saw two password prompts for one install. Not yet in a release.
