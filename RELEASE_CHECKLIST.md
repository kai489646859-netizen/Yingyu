# Release checklist

## Common

- [ ] Version, tag, README, changelog and in-app version agree
- [ ] Real-device use has been completed for the release candidate
- [ ] Automated/static checks and their limitations are recorded separately
- [ ] No credentials, signing keys, private URLs, media or user logs are included
- [ ] Matching source, symbols/notices and SHA-256 files are prepared
- [ ] Third-party source and license obligations are satisfied
- [ ] Upgrade preserves application identity and documented user data
- [ ] Release notes describe remaining compatibility boundaries honestly

## Android

- [ ] APK signature continuity and certificate fingerprint verified
- [ ] APK architecture, 16 KiB/native library and symbol checks completed
- [ ] Cover-install from the previous public release tested

## Windows

- [ ] Installer identity and previous installation directory behavior verified
- [ ] Authenticode status explicitly documented
- [ ] Cover-install and preservation of accounts/settings/progress/cache tested

## GitHub

- [ ] Draft release created before large asset uploads
- [ ] GitHub asset byte counts and SHA-256 digests match local artifacts
- [ ] Release asset integrity workflow passes
- [ ] Stable releases are not left marked as Pre-release
