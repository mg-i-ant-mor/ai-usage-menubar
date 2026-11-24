# Releasing AI Usage (mg-i-ant-mor fork)

This fork ships its own universal DMG and Sparkle 2 feed, separate from
upstream `burakgon/ai-usage-menubar`. Installed fork builds read
`https://raw.githubusercontent.com/mg-i-ant-mor/ai-usage-menubar/main/appcast.xml`
and accept only updates signed with the fork's Sparkle key, so upstream
releases never replace them.

## Prerequisites

- Xcode 27 or newer
- GitHub CLI authenticated for `mg-i-ant-mor/ai-usage-menubar`
- The `ai-usage-menubar-mg` Sparkle EdDSA key in the login Keychain

The Sparkle private key is never stored in this repository. The public key is
embedded in `AIUsage/Info.plist`. Back up the private key in a secure secret
manager (OpenBao) and restore it on another Mac with:

```bash
generate_keys --account ai-usage-menubar-mg -x <exported-private-key-file>
```

```bash
generate_keys --account ai-usage-menubar-mg -f <exported-private-key-file>
```

The first command exports, the second imports. To sign without Keychain
prompts, set `SPARKLE_PRIVATE_KEY_FILE` to the exported key file when
packaging; the public key is still checked against Keychain.

## Versions

A fork version is the upstream version it is built on plus a fork revision:
`0.5.0.1`, `0.5.0.2`, then `0.6.0.1` after merging upstream 0.6.0.
`CURRENT_PROJECT_VERSION` starts at 1001 and goes up by one for every fork
release. Sparkle compares this build number, so fork builds always rank above
upstream's (17 for 0.5.0). When merging upstream, keep the fork's values in the
Xcode project, `Info.plist` and `scripts/package_release.sh`.

## Signing

Releases are signed ad-hoc and not notarized: there is no Developer ID
certificate. Sparkle verifies every update with the EdDSA signature, and
updates installed by Sparkle open without a Gatekeeper prompt. A DMG
downloaded with a browser needs a right-click → Open the first time, or:

```bash
xattr -dr com.apple.quarantine "/Applications/AI Usage.app"
```

## Prepare a version

1. Update `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in the Xcode
   project.
2. Add `docs/releases/<version>.md`.
3. Commit and test the source changes.

## Build the DMG and appcast

```bash
version=0.5.0.1
./scripts/package_release.sh "$version"
```

The script builds a universal Release app, checks the feed URL and that the
embedded public key matches the Keychain key, runs a launch smoke test,
creates `dist/v<version>/AI-Usage.dmg`, and updates the signed `appcast.xml`.

## Publish

1. Commit `appcast.xml` on a branch, open a PR to `develop` and merge it.
2. Tag the merge commit `v<version>` (annotated), push the tag, and upload the
   DMG:

   ```bash
   gh release create "v$version" -R mg-i-ant-mor/ai-usage-menubar \
     "dist/v$version/AI-Usage.dmg" \
     "dist/v$version/AI-Usage.dmg.sha256" \
     --title "AI Usage $version" \
     --notes-file "docs/releases/$version.md"
   ```

3. Open a PR from `develop` to `main` and merge it. The feed goes live only
   now, after the DMG is downloadable.
4. Check that the raw appcast and the DMG enclosure URL both return HTTP 200,
   then use Check for Updates in the installed app.
