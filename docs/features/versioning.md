# Versioning

The app and the recipe catalogs each have a version, so it's always clear which build and which catalog a Mac is running, and an older copy never replaces a newer one.

## App version

- `VERSION` at the repo root holds the app's version as semver (`1.0.0`). It is the only copy: the Makefile passes it to every xcodebuild run (`dev`, `test`, `build`, `cli`) as `MARKETING_VERSION`, so Info.plist's `CFBundleShortVersionString` comes from it. The project file's own `MARKETING_VERSION` is only what a build started from Xcode's UI shows.
- The build number (`CURRENT_PROJECT_VERSION`, `CFBundleVersion`) is the commit count (`git rev-list --count HEAD`), so it rises with every commit and is the same for a local and a CI build of one commit.
- `make version` prints both, for example `1.0.0 (95)`.
- `make release` (`BUMP=patch`, `minor` or `major`; patch by default) bumps `VERSION`, commits `Release vX.Y.Z`, tags `vX.Y.Z` and pushes main and the tag. It refuses a dirty tree, a branch other than main, a main behind `origin/main`, or an existing tag. Patch for fixes, minor for new features and UI changes; a major bump is Alex's call. Nothing else bumps `VERSION` (docs/rules/versioning.md).
- CI (`.github/workflows/build.yml`) builds every push with `VERSION` and fails a tag that doesn't match it, so a release is always cut with `make release`. A tag push publishes the GitHub Release (`Takeover-X.Y.Z.dmg` and the CLI zip); other builds are named `X.Y.Z-<sha>`.
- The Settings window (Takeover > Settings) shows the app version and both catalogs' versions at the bottom left, for bug reports.

## Catalog versions

- takeover-site's `public/catalog/apps.yaml` and `mac-defaults.yaml` each have a top-level `version`, an integer raised by one in every change to that file. takeover-site's CI and deploy run `bin/check-catalog-versions`, which fails a push that changes a catalog without raising its version. `mac-defaults.yaml` is `{version, defaults: [...]}`, and `/api/v1/mac_defaults` returns the same shape.
- `RemoteCatalog.load` keeps the copy with the highest version among the fetched, cached (one week) and bundled ones (`VersionedCatalog`, `RemoteCatalog.newest`). An app update that bundles a newer catalog isn't held back by an older cache, and a server that's behind (not yet deployed, or rolled back) doesn't replace a newer cache. A catalog cached before versions existed decodes as version 0, so any versioned copy beats it.
- `make catalog` (run by `make build`) replaces a bundled catalog only with a site copy of the same or a higher version, and keeps the bundled copy when the site's has no version.

## Not versioned here

- The settings folder's own files (`settings.yaml`, `links.yaml`) already carry a schema `version` (`Profile.version`, `LinkConfig.version`); this feature doesn't change them.
- The `takeover` CLI has no Info.plist, so it has no `--version` yet.

## Tests

- `TakeoverTests/CatalogVersionTests.swift`: decoding versioned and bare mac-defaults files, the newest copy winning, and the bundled catalogs having versions.
- takeover-site: `test/integration/catalog_test.rb` and `api_flow_test.rb` check both catalogs' versions and the API shapes.

## History

- Implemented 2026-11-17. The Swift changes were not compiled or tested here (no Swift toolchain); `make version` and `make catalog` were run, and the takeover-site tests pass.
