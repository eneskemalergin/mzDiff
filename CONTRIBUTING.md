# Contributing to mzdiff

Thanks for considering a contribution. Bug reports, fixes, tests, documentation, and ideas are all welcome.

Report security problems privately, as [SECURITY.md](SECURITY.md) describes, not in a public issue.

## Issues

A useful bug report says what you ran, what mzdiff printed, and what you expected. The two files help most; if you cannot share them, the tools that wrote them (converter and version) and the records involved still help. For a difference mzdiff misses or rates wrongly, say what a reader of the file does with it: a search engine that fails or finds other matches is the strongest case for a severity.

## Pull requests

For anything larger than a small fix, open an issue first, so we can agree on the direction before you spend time on it.

A change is ready to merge when:

- `zig build test --summary all` passes and `zig fmt --check build.zig src` is clean;
- a fix or new behavior comes with a test that shows it;
- a new check also has a case in `tools/mutate.py` that injects its defect and shows mzdiff reporting it ([Development](https://github.com/eneskemalergin/mzDiff/wiki/Development#defect-harness));
- untrusted input still cannot crash mzdiff, grow its memory without bound, or reach its output unescaped.

Commit messages, branch names, and how you split commits are up to you; I may squash or reword them when merging.

A change to the output (a kind, a JSON key, a TSV column, the exit status, or a severity) is a change scripts will notice. Say so in the pull request, and update the wiki page that documents it.

## Conventions in the code

You will see a few conventions; follow them where it is convenient, and I will adjust the rest in review:

- tests sit beside the code in `src/`, build their inputs in memory, and never read files outside the repository;
- tests are named `[type] - [target]: behavior`, for example `test "[unit] - [severity]: exact keys win over ancestry and the default"`;
- the only comments are a module overview of at most 10 lines at the top of each file and `// --- Name ---` dividers that split a file, such as the one before its tests; anything else a reader needs goes into names and types, or into the wiki.

## License

By contributing, you agree that your contribution is licensed under the [MIT License](LICENSE), as the rest of the project is.
