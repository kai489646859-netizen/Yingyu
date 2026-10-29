# Contributing

Thanks for helping improve Yingyu.

1. Open or reference an Issue before a broad behavior change.
2. Keep Android and Windows changes scoped to the affected platform.
3. Preserve working playback, account, progress and update behavior.
4. Add a regression test or a reproducible check when practical.
5. Update user-facing documentation when behavior or compatibility changes.
6. Do not commit signing keys, credentials, tokens, private URLs, user logs, media files, compiled installers or release symbols.

Pull requests should explain the problem, the exact behavioral change, validation performed, remaining device/runtime boundaries and any third-party code or license introduced.

Application-layer snapshots live in `source/android` and `source/windows`. Large pinned dependency closures remain in the matching Release archives. See [`BUILDING.md`](BUILDING.md) before attempting a build.
