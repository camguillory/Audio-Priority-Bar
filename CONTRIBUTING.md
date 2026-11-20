# Contributing

Thanks for helping improve Audio Priority Bar.

1. Open an issue first for a substantial change.
2. Branch from `develop`.
3. Open your pull request against `develop`.

Every pull request runs both Swift Testing suites and a universal build. See
[Build from source](README.md#build-from-source) to run the app locally.

Contributions are accepted under the [GPL-3.0](LICENSE) license.

## Releases

Run the Release workflow on an existing version tag. The tag must belong to the repository's default branch, or the branch named in the `RELEASE_BRANCH` repository variable. The workflow builds an unsigned universal ZIP and checksum by default. Use `scripts/package-release.sh --unsigned` to enforce the unsigned configuration when running locally.

To distribute automatic updates, select **Sign the app and publish automatic updates**. Set `CODESIGN_IDENTITY` to your signing certificate's SHA-1 fingerprint and `SPARKLE_PUBLIC_KEY` to your Sparkle EdDSA public key in repository variables. Set `CODESIGN_CERTIFICATE_P12`, `CODESIGN_CERTIFICATE_PASSWORD`, and the corresponding `SPARKLE_PRIVATE_KEY` in repository secrets. The workflow selects this repository's feed and archive URLs. The first such release provides a full archive. Later releases can also provide deltas.
