# Package identity and signing

## Android

Android 1.9.6 APK SHA-256:

```text
fb70b6a85898a0759e18c0d536501d3f8224eea4487329c291fb8afff92a2d2b
```

Signing-certificate SHA-256:

```text
d7ef5ac3262acbf293df11cd0579f70b253314cd5db60167e92ee34167d06ca6
```

The release audit confirms the certificate matches the previous published application identity. Keep the private signing key offline; it is not part of the source archive.

## Windows

Windows 0.5.8 installer SHA-256:

```text
28e09217f30dfebc44ab54bc9dbb2cdf38bd2262f97b96bd8563cab064052ef4
```

The current Windows installer is **not Authenticode-signed**. Windows may therefore show an unknown-publisher or reputation warning. Verify the SHA-256 against the Release before running it.

A future Authenticode-signed release must publish the signer subject, certificate thumbprint and timestamp status here. Signing status must never be implied by a checksum alone.
