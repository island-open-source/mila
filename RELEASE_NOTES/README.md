# Release notes

One Markdown file per release, named `v<MARKETING_VERSION>.md` (e.g. `v1.8.14.md`).

## Why this is required

The signing/publish pipeline turns this file into the Sparkle appcast
`<description>` for the release — which is **exactly what Mila's in-app
"What's New" popup shows** when a user updates. If it's missing, the popup
degrades to a bare *"a new version of Mila is available"* with no changelog.

To make that impossible to forget, the release pipeline **fails fast — before
the build** — when `RELEASE_NOTES/v<version>.md` is missing, empty, or still
contains boilerplate. The check is [`scripts/check-release-notes.sh`](../scripts/check-release-notes.sh);
run it locally any time: `scripts/check-release-notes.sh 1.8.14`.

## Writing the notes

- Audience is **end users**, not developers — describe what changed for *them*.
- Markdown. A short bulleted list works best (it renders to `<ul><li>` in the
  appcast); bold the lead of each bullet.
- Cover only the user-visible changes in this version.

Example (`v1.8.14.md`):

```md
- **Fixed a cross-recording mix-up in AI summaries** — a recording's summary
  and action items could occasionally include content carried over from a
  previous recording. Each recording now uses a fully isolated AI session.
```

## Where this fits in the release

1. Write `RELEASE_NOTES/v<version>.md` (this step).
2. Bump `MARKETING_VERSION` + `CURRENT_PROJECT_VERSION` in `project.yml`.
3. Commit + push to `main`, tag `v<version>`, push the tag.
4. Trigger the signing/notarize/publish job with `gitRef=v<version>`.

See `CLAUDE.md` › Release Process.
