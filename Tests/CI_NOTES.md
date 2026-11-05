# CI notes

- `simulator_ui` (build + 5 UI tests) takes about 20 minutes on the `xcode-27` runner.
- A job that is never assigned a runner shows 0 steps and is cancelled after about
  15 minutes. That is runner capacity, not a test result; re-push to rerun
  (the repository token cannot call `rerun-failed-jobs`).
- No automatic test retries. A flaky UI query is rerun by hand and reported as such.

- 2026-11-05: run 42036603268 (fe6a078) failed at "Select Xcode 27.2 RC" before any build or
  test ran: the assigned xcode-27 runner lacked that Xcode. Infrastructure, not code. The PAT
  cannot call the rerun API, so CI is re-triggered with a commit touching this file.
