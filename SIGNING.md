# Package identity and signing

## Android

Android 2.2.4 APK SHA-256:

```text
a22d47b83a6a6b0309b1b8f3dcf25337fb115e678e7327b10ae4e21ed85d59b2
```

Signing-certificate SHA-256:

```text
d7ef5ac3262acbf293df11cd0579f70b253314cd5db60167e92ee34167d06ca6
```

The release audit confirms the certificate matches the previous published application identity. Keep the private signing key offline; it is not part of the source archive.

## Windows

Windows 1.2.2 installer SHA-256:

```text
c5b0015ac8872f2a2a87123aee5c56852483aa4c20643dac559157090dc07278
```

The current Windows installer is **not Authenticode-signed**. Windows may therefore show an unknown-publisher or reputation warning. Verify the SHA-256 against the Release before running it.

A future Authenticode-signed release must publish the signer subject, certificate thumbprint and timestamp status here. Signing status must never be implied by a checksum alone.
