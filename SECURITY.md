# Security

mzdiff compares files that come from instruments, converters, and other people. A file must not be able to crash mzdiff, corrupt its memory, make it use unbounded memory or time, or put markup, script, or terminal control sequences into its output. If you find input that does, please report it privately.

## Supported versions

Until 1.0, only the latest version receives security fixes.

## Reporting a vulnerability

Report it through GitHub's private vulnerability reporting: open the repository's **Security** tab and choose **Report a vulnerability**. Please do not open a public issue, pull request, or discussion about it.

An input that triggers the problem is enough to start with; attach it to the report rather than linking it. If you have them, the mzdiff and Zig versions, the command line, the target and build mode, and what happens (a crash, a hang, memory growth, wrong output) help me reproduce it faster.

## What to expect

- A first response within 14 days.
- An update at least every 14 days until the report is resolved.
- A fix in a new version, and an advisory under the repository's **Security** tab that credits you unless you prefer not to be named.

When the cause is in [zmz](https://github.com/eneskemalergin/zmz), the mzML reader mzdiff is built on, I report it there privately too, and mzdiff takes the fixed release.

## Scope

In scope: anything in `mzdiff` (`src/`) that untrusted input can drive into a crash, undefined behavior, out-of-bounds access, memory or work beyond the bounds the [Untrusted input](https://github.com/eneskemalergin/mzDiff/wiki/Untrusted-input) page describes, a difference it reports wrongly or not at all, or text, TSV, or HTML output that runs as markup, script, or terminal control.

The scripts in `tools/` and the build script are development tools, not meant to face untrusted input; a problem in them is an ordinary bug, so please open an issue.
