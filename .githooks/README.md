# Commit checks

Run `git config core.hooksPath .githooks` once per clone to enable the local
commit checks. Repository CI runs the same standardized check over all
reachable commit messages alongside the existing repository policy check.

Run `sh .githooks/test-history-guard` to exercise invalid-message rejection,
missing-dependency failure, missing-helper failure, and valid-history acceptance.
