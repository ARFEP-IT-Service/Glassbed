# Verifying downloads

The Windows files of Glassbed (installer and portable ZIP) are currently **not code-signed**,
so Windows SmartScreen may show a warning.

Every file is built on GitHub from the source code in this public repository by the
[Release build](.github/workflows/release-build.yml) workflow. Its SHA-256 checksum is listed in
the release notes and published next to it as a `.sha256` file.

Compare the checksum of your download with the published one – they must be identical.

**Windows** (Command Prompt or PowerShell):

```
certutil -hashfile Glassbed-<version>-setup.exe SHA256
```

**Linux / macOS:**

```
sha256sum Glassbed-<version>-setup.exe
```

On macOS versions without `sha256sum`, use `shasum -a 256` instead.

With the `.sha256` file in the same folder, `sha256sum -c Glassbed-<version>-setup.exe.sha256`
checks it automatically. Use the same commands for `Glassbed-<version>-windows-portable.zip`.
