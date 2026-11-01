# Package identity and signing

## Android

Android 2.1.3 APK SHA-256:

```text
7a26d2d99ead5ce6f18277a28c5c703e24b691a8e3a0a6e6b4c3f0b2c93b2b25
```

Signing-certificate SHA-256:

```text
d7ef5ac3262acbf293df11cd0579f70b253314cd5db60167e92ee34167d06ca6
```

The release audit confirms the certificate matches the previous published application identity. Keep the private signing key offline; it is not part of the source archive.

## Windows

Windows 0.8.5 installer SHA-256:

```text
ae7e5cff6cc0f10b835853f4d5004fbf463f05d1caf1ccc96ed5c7e159618770
```

The current Windows installer is **not Authenticode-signed**. Windows may therefore show an unknown-publisher or reputation warning. Verify the SHA-256 against the Release before running it.

A future Authenticode-signed release must publish the signer subject, certificate thumbprint and timestamp status here. Signing status must never be implied by a checksum alone.
