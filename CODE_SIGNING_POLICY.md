# Code signing policy

## Windows releases

Windows releases of Glassbed (installer and portable ZIP) are to be code-signed through
the [SignPath Foundation](https://signpath.org/) program for open-source projects.

**Status:** application in progress. Until it is approved, releases are **not signed**, and
Windows SmartScreen may show a warning. Each release lists SHA-256 checksums for verification.

## What gets signed

Only binaries that are built by the [Release build](.github/workflows/release-build.yml)
GitHub Actions workflow from the source code in this public repository are signed. Nothing
built on a personal machine, and nothing from outside this repository, is signed.

## Roles

| Role | Person |
|---|---|
| Author | Halil Ayberk Bulut |
| Reviewer | Halil Ayberk Bulut |
| Approver (signing requests) | Halil Ayberk Bulut |

## Privacy

Glassbed does not transfer any data to other systems, except to the printer in your local
network that you use it with. It has no telemetry, no account and no cloud service; web pages
open only when you click a link.
