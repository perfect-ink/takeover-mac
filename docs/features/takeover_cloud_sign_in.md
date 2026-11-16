# Takeover Cloud sign-in

The app asks for a Takeover account only when the user picks **Takeover Cloud** as where their settings are stored. There is no sign-in or account button anywhere else.

## What users see

- **Settings > Storage** (`Takeover/Views/StorageSetupView.swift`, also the first-launch setup sheet): choosing Takeover Cloud shows `CloudAccountView`, with email/password, Create Account and Sign In. Once signed in it shows the account email, trial or subscription state, last sync time or error, and Sign Out. Saving the Takeover Cloud choice is disabled until signed in.
- **iCloud Drive, Dropbox, A Folder**: no sign-in is shown or needed.
- **Restore tab**: works from any Takeover folder without an account; when signed in it also lists the account's Macs (see [restore.md](restore.md)).

## Code

- `TakeoverCloud` (`Takeover/TakeoverCloud.swift`) signs in or registers through `APIClient` and hands the user to `AccountManager.adopt(_:)`, which registers this Mac and syncs (see `ProfileSyncManager`).
- `AccountManager` (`Takeover/Account/AccountManager.swift`) holds the signed-in user; it no longer has its own login methods.
- Removed: `AccountView` (the separate sign-in sheet, including Sign in with Apple) and `AccountButton` (the account chip in the tab bar and Restore toolbar).

## Known limits

- Sign in with Apple is no longer offered, since it lived only in the removed sheet. The API endpoint (`POST /api/v1/auth/apple`) and `APIClient.signInWithApple` remain.
- Switching from Takeover Cloud to another storage option doesn't sign out; the account keeps receiving this Mac's profile for Restore until the user signs out.

## History

- Implemented 2026-11-15, requested by Alex ("I shouldn't see a sign-in button. If someone selects Takeover Cloud, then they have to provide login"). Not compiled locally (Linux session); the GitHub Actions build on main compiles it. Not yet in a release.
