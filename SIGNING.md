# Package identity and signing

## Android

Android 2.6.5 APK SHA-256:

```text
a2f8c3314516ea6173fcedbd77828e20e22a6eea0ab7c9c56a1f2b47f2b518bf
```

Signing-certificate SHA-256:

```text
13f64687afc61988916fb061ffa31ad88116fd62ab64404e8e1170ed2cc2fdb8
```

The current application ID is `com.yingyu.player.release`. Its certificate is continuous from Android 2.2.5 through 2.6.5, but differs from the older 2.2.4 public package. The two lines can coexist; 2.2.4 cannot be directly cover-installed by 2.6.5. Keep the private signing key offline; it is not part of the source archive.

## Windows

Windows 1.7.1 installer SHA-256:

```text
dc36c92e16b22a075476faea9780b4fa579e0d55e7410a5879113ca54a13a22d
```

The current Windows installer is **not Authenticode-signed**. Windows may therefore show an unknown-publisher or reputation warning. Verify the SHA-256 against the Release before running it.

A future Authenticode-signed release must publish the signer subject, certificate thumbprint and timestamp status here. Signing status must never be implied by a checksum alone.
