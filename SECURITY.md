# Security

## Reporting a vulnerability

Report it privately through GitHub's [private vulnerability
reporting](https://github.com/seriouslysean/grubstake/security/advisories/new), which opens a draft
advisory visible only to you and the maintainer. Do not open a public issue.

That link works only while private vulnerability reporting is enabled in Settings → Advanced
Security. If that page is not available the setting is off, and saying so in a public issue, without
describing what you found, is enough to get it turned on.

This is a solo project. It offers no response-time commitment, because it could not keep one.

## What the pin covers

The pin is the trust boundary and it is checked at download. Every tool is pinned to an exact
version and an exact SHA256; grubstake verifies the bytes it downloads against that pin, and
confirms the archive contains the version it was pinned to, before anything is installed.

In scope is anything that gets an artifact past that check: a hash that is not compared, a
comparison whose failure is swallowed, a fallback to an unpinned binary, or a pin resolved from
somewhere other than the committed pins file.

## What the cache does not cover

The cache is an optimisation, not a boundary. It lives in your home directory, anything that can
write to it can write to all of it, and grubstake does not pretend otherwise. Entries are verified
once, at download, against the pin, before they are published; nothing re-hashes them on read. A
poisoned cache entry is served, and a test asserts that it is, so the claim that it would be caught
cannot quietly return.

An attacker who can write to your home directory already runs as you, and no cache layout changes
that. Reports resting on that access are not vulnerabilities in this model.
