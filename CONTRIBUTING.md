# Contributing

Thanks for helping improve Audio Priority Bar.

1. Open an issue first for a substantial change.
2. Fork the repository and branch from `develop`. `main` is the latest
   release; `develop` is next.
3. Open your pull request against `develop`, not `main`. GitHub bases new pull
   requests on `main`, so switch the base before submitting.

Every pull request runs both Swift Testing suites and a universal build. See
[Build from source](README.md#build-from-source) to run the app locally.

## Releases

Releases are tagged and published manually. The release workflow signs the
update feed with the `SPARKLE_PRIVATE_KEY` secret, the Sparkle EdDSA key
exported with `generate_keys --account app.audioprioritybar -x`.
