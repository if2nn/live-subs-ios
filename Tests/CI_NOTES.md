# CI notes

- `simulator_ui` (build + 5 UI tests) takes about 20 minutes on the `xcode-27` runner.
- A job that is never assigned a runner shows 0 steps and is cancelled after about
  15 minutes. That is runner capacity, not a test result; re-push to rerun
  (the repository token cannot call `rerun-failed-jobs`).
- No automatic test retries. A flaky UI query is rerun by hand and reported as such.
