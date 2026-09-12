# Compatibility fixtures

These synthetic fixtures freeze the persisted settings of public V1 and the
pre-release V2 schema. They contain no settings or device names from a
developer machine.

- `v1.2.1-defaults.plist` exercises the public bundle-domain migration.
- `legacy-defaults.plist` exercises the one-time `neverUseDevices` migration.
- `v2.0.0-defaults.plist` captures the pre-release V2 preference schema with
  deterministic `StoredDevice` dates.
