# Qodana Global Project Configuration

Shared [Qodana](https://www.jetbrains.com/help/qodana/) settings for several repositories, kept in one place and
delivered through Qodana Cloud's
[global configuration](https://www.jetbrains.com/help/qodana/global-configuration.html) feature.

## Layout

| Path | What it is |
|---|---|
| `qodana-global-configurations.yaml` | The catalog: the configurations a Qodana Cloud project can be connected to. |
| `base/qodana.yaml` | Defaults for every stack. Imported by each stack file; not in the catalog. |
| `java-quarkus/qodana.yaml` | Java services built with Quarkus (linter `qodana-jvm`). |
| `dart-flutter/qodana.yaml` | Flutter and Dart applications (linter `qodana-poly`, native mode). |
| `angular/qodana.yaml` | Angular front ends (linter `qodana-js`). |
| `scripts/validate.sh` | Checks everything above without uploading. |
| `.github/workflows/upload-global-configuration.yml` | Validates pull requests; uploads from `main`. |

## How the layers combine

A scan uses, from strongest to weakest: command-line options, the repository's own `qodana.yaml`, its stack file,
the base.

- A single value (`bootstrap`, a threshold, `profile.name`) comes from the strongest layer that sets it.
- Lists (`include`, `exclude`, `profile.inspections`, `licenseRules`) are joined, base first. A layer can add
  entries but cannot remove one it inherited. `plugins` is merged by id.
- The uploader flattens each catalog entry with everything it imports into one file per configuration id.
  That is why the base needs no catalog entry, and why a change to the base reaches projects only after an upload.
- A global configuration provides defaults, not enforcement: a repository can override any of it.

## Rules for shared files

1. **No `linter`, `ide`, `image` or `withinDocker`.** Qodana picks the linter and the Docker or native mode in the
   repository, before anything is merged. In a shared file these keys select nothing, and a shared `linter` stops
   the scan of every repository whose own `qodana.yaml` does not repeat it.
2. **Only keys Qodana knows.** The uploader accepts anything, but the linter stops with
   `Unexpected keys in qodana.yaml` on a top-level key it does not know, so a mistyped key would fail the scan of
   every connected project.
3. **No key with an empty value.** A key with nothing after the colon cannot be merged: the configuration fails
   to build and nothing is uploaded.
4. **`imports` is always a list.** Written as plain text it is dropped without any message, and the base with it.
5. **Select a profile with `profile.name` only.** A `profile.path` or `profile.base` in a stack file would end up
   next to the base's `profile.name` in the uploaded file.
6. **Exclude paths with `profile.inspections`**: `group: ALL` plus `ignore` globs such as `"docs/**"`. This is
   the form the Qodana reference documents, and its entries have a defined order. Going by the linter's code a
   later layer should be able to bring a path back with `"!docs/**"`, which the older `exclude` key does not
   allow; that has not been confirmed in a scan yet.
7. **Keep lists short.** Every entry applies to every repository of the stack.
8. **No secrets.** The contents of these files are included in the Qodana report of each connected project.

`scripts/validate.sh` checks rules 1 to 5.

## What stays in each repository

- A `qodana.yaml` with `version`, `linter` and `profile.name: qodana.recommended`. Keep the profile name even though
  the base sets it: when a scan cannot load the global configuration it continues with the repository's file alone
  and reports success, and without a profile name it would run the smaller `qodana.starter` profile.
- Exclusions that name the repository's own paths, and its documented false positives.
- The workflow: dependency installation, tests and coverage, the Qodana token, triggers, and native mode
  (`--within-docker false`) for Flutter.

## Changing a configuration

1. Edit the files and run `scripts/validate.sh` (needs bash, curl and Java 21 or newer). It builds every
   configuration with Qodana's own configuration loader and prints the file each one flattens to.
2. Open a pull request. The workflow runs the same check and uploads nothing.
3. Merge. The workflow validates again and uploads to Qodana Cloud. Connected projects pick the change up on
   their next scan, with no commit in their own repository, so run their Qodana workflow afterwards to see the
   effect.

The upload needs the secret `QODANA_CONFIGURATIONS_TOKEN`, created in Qodana Cloud under the organization's
Settings, Global configurations.

## Connecting a project

In Qodana Cloud, open the organization's Settings, then Global configurations, choose a configuration and use
Connect projects. Nothing in the repository selects the configuration. The feature requires the Ultimate Plus
license.

A scan that applied a global configuration prints
`Global configuration '<name>' (ID: <id>) was successfully loaded`. A scan that prints
`Global configuration was not loaded, using local configuration` ran with the repository's file alone.
