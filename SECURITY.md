# Security Policy

Mila runs entirely on-device and requests sensitive macOS permissions
(microphone, screen recording, accessibility), so we take security reports
seriously.

## Reporting a vulnerability

**Please do not open a public issue for security vulnerabilities.**

Report privately via GitHub's
[private vulnerability reporting](https://github.com/island-open-source/mila/security/advisories/new),
or email **uri@island.io**. We aim to acknowledge reports within a few
business days.

Please include:
- A description of the issue and its impact.
- Steps to reproduce, plus the Mila version (Mila → About Mila) and your macOS version.
- A proof-of-concept, if available.

## Supported versions

Security fixes target the latest released version — please update to the
newest release before reporting.

## Good to know

- Audio is transcribed locally; nothing is sent to a server.
- Optional LLM features shell out to a CLI **you** install and authenticate;
  Mila ships no API keys.
- Auto-updates are delivered via Sparkle using EdDSA-signed release artifacts.
