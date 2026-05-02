# Shipping runbook

This runbook is for an operator or future agent preparing a local Sounding Developer ID distribution proof. After reading it, you should be able to run the no-credential readiness and package checks, configure operator-local signing/notary prerequisites, run an optional real release on a credentialed Mac, interpret failures by phase, and copy only sanitized evidence into tracked notes.

The repository never stores Apple credentials, signing identities, notary profiles, generated archives, package artifacts, raw logs, or machine-local paths. The scripts emit redacted human and JSON summaries; private tool output stays inside ignored local workspaces.

## What is safe to run without credentials

Run the readiness check first:

```sh
scripts/distribution/check --json
```

This checks the distribution toolchain, the Xcode project shape, the supported arm64 packaging path, and whether credential-gated checks were skipped. It does not submit anything to Apple and does not require a local signing identity or notary profile.

Then produce the required app verification evidence in ignored local workspaces. Run deterministic fixture verification first, then run live verification with a gitignored local config that contains only authorized operator-local streams:

```sh
swift run sounding app-verify fixture \
  --json app-verify-fixture-evidence/latest.json

swift run sounding app-verify live \
  --config app-verify-live.local.json \
  --json app-verify-live-evidence/latest.json
```

If authorized live streams are unavailable on the machine, do not invent or synthesize live evidence for shipping. Treat the package gate failure as the correct result until real live evidence is produced locally.

Then run a dry-run package into an ignored workspace with both evidence files:

```sh
scripts/distribution/package --dry-run --json \
  --output-dir shipping.local/dry-run \
  --app-verify-fixture-evidence app-verify-fixture-evidence/latest.json \
  --app-verify-live-evidence app-verify-live-evidence/latest.json
```

Dry-run packaging validates fixture and live `AppVerifyEvidence` before archive, build, or disk-image work, then builds a Release app, stages it locally, creates and verifies a disk image when local tools are available, and reports signing, notarization, stapling, and Gatekeeper phases as skipped. Treat a dry-run pass as proof that the local app-verify and packaging paths are healthy, not as proof that Apple accepted a release.

A safe synthetic JSON reference is tracked in [`Docs/shipping-diagnostics.example.json`](shipping-diagnostics.example.json). Use that file to understand the output shape, including `phase: "appVerify"` rows; do not replace it with generated local output.

## Operator-local prerequisites for a real release

A real Developer ID release requires all of the dry-run prerequisites plus credentials installed on the operator's Mac. Keep these values local:

- A local Developer ID Application certificate in the keychain.
- A non-secret selector label for that certificate, not the raw certificate common name.
- A notarytool keychain profile label.
- Full Xcode, including `notarytool`, `stapler`, `codesign`, `hdiutil`, and `spctl`.
- An Apple silicon host for the supported arm64 distribution path.

Store the notary profile in the local keychain using placeholders only in notes:

```sh
xcrun notarytool store-credentials "[local-notary-profile-label]" \
  --apple-id "[apple-account-placeholder]" \
  --team-id "[team-id-placeholder]" \
  --password "[app-specific-password-placeholder]"
```

Do not commit the profile label if it reveals a person, account, team, company, or machine. Do not paste the real Apple account, team identifier, app-specific password, certificate common name, or keychain output into tracked files.

Before running the real workflow, check that local credential labels are available without printing private values:

```sh
scripts/distribution/check --json \
  --developer-id-identity "[local-identity-selector]" \
  --notary-profile "[local-notary-profile-label]"
```

## Optional real release command

Run the real release only on a credentialed operator machine:

```sh
scripts/distribution/package --real --json \
  --output-dir release.local/current \
  --app-verify-fixture-evidence app-verify-fixture-evidence/latest.json \
  --app-verify-live-evidence app-verify-live-evidence/latest.json \
  --developer-id-identity "[local-identity-selector]" \
  --notary-profile "[local-notary-profile-label]"
```

Real mode signs the staged app, verifies the signature, creates and verifies the disk image, submits it to notarytool, staples the app and disk image, and runs Gatekeeper assessment. It is expected to fail fast with redacted diagnostics when credentials or Apple tooling are missing.

## Local artifact layout

Keep generated release material in ignored local workspaces. A practical layout is:

```text
shipping.local/
  dry-run/
  smoke-tests/
release.local/
  current/
  prior/
notary-logs.local/
  private-notary-investigation/
```

Generated app bundles, disk images, archive bundles, export directories, raw command logs, notary logs, screenshots, and command transcripts are private. They may include paths, certificate metadata, submission identifiers, tool output, or machine details. Do not commit them and do not paste their contents into tracked notes.

## Pre-release health checks

Before a real release, prove the runtime and database surfaces are healthy:

```sh
sounding soak proof \
  --db "[redacted-db-path]" \
  --evidence-out "[redacted-evidence-path]" \
  --duration-seconds 0.3 \
  --sample-interval-seconds 0.1 \
  --json

sounding database health --db "[redacted-db-path]" --json
sounding database checkpoint --db "[redacted-db-path]" --mode passive --json
```

For long unattended evidence, follow [`Docs/soak-evidence.md`](soak-evidence.md) instead of duplicating raw local evidence here. Tracked release notes should summarize only aggregate pass/fail facts and redacted phases.

## Interpreting distribution failures

Every script summary uses a `phase`, `status`, `message`, and `guidance` field. Use the phase to decide where to look locally:

| Phase | Typical meaning | Safe next step |
| --- | --- | --- |
| `environment` | Xcode, distribution tools, project inspection, or supported architecture is not ready. | Install or select the required local tools and rerun the check. |
| `signingIdentity` | A Developer ID identity selector was skipped, missing, or did not match a local certificate. | Install the local certificate or choose a non-secret selector label. |
| `appVerify` | Fixture or live app verification evidence is missing, malformed, failed, or incomplete. | Produce fresh fixture and authorized live app-verify JSON evidence in ignored local workspaces, then rerun packaging with both evidence flags. |
| `archive` | Release build or staging failed. | Inspect the local xcodebuild log in the ignored workspace. |
| `export` | Export-style packaging failed if that phase is added to a local workflow. | Inspect local export logs only; copy no raw paths. |
| `codesign` | Signing or signature verification failed. | Inspect local codesign output and rebuild after fixing the local identity or entitlements. |
| `notarySubmit` | Notary credentials are missing, invalid, timed out, or submission failed. | Verify the local keychain profile and inspect ignored notary logs. |
| `notaryWait` | Apple rejected or failed the submitted artifact while waiting for a result. | Inspect the local notary log and fix the app, signing, or package issue. |
| `notaryLog` | Additional notary diagnostics were preserved locally. | Read the ignored local log; copy only phase/status/count facts. |
| `staple` | Stapling failed after notarization. | Retry after notarization succeeds and inspect the local stapler log. |
| `gatekeeper` | Gatekeeper assessment failed. | Inspect local spctl output for the generated app or disk image. |
| `dmg` | Disk image creation or verification failed. | Inspect local hdiutil output and rerun package creation. |
| `output` | The ignored output workspace could not be created or written. | Use a writable ignored workspace and retry. |
| `redaction` or `unknown` | Raw tool text could not be safely classified or redacted. | Do not copy the raw text; inspect ignored local logs privately. |

Statuses are intentionally small: `ready`, `skipped`, `missingCredential`, `failed`, `notarizationRejected`, `redactionFailure`, or `unknown`. A `missingCredential` status is expected on machines without local Apple distribution credentials.

## Redaction checklist

Before copying distribution evidence into tracked notes, scan candidate text and replace or remove:

- App-verify JSON evidence files, app-verify configs, raw app-runtime diagnostics, and any evidence artifact contents. Keep only controlled `appVerify` phase/status facts in tracked notes.
- Apple accounts, email-looking strings, team identifiers, submission identifiers, passwords, tokens, app-specific passwords, and keychain profile values.
- Raw Developer ID certificate common names or any value beginning with a certificate prefix plus a colon.
- Local machine paths, temporary paths, database paths, generated archive paths, generated disk image paths, and log paths.
- URLs, query strings, fragments, private stream sources, screenshots, transcripts, app bundles, archives, disk images, and raw tool output.
- Private workspace contents under `shipping.local/`, `release.local/`, `notary-logs.local/`, `app-verify-fixture-evidence/`, `app-verify-live-evidence/`, or `app-verify-live-proof.local/`.

Safe tracked evidence includes command shape, exit code, bounded run mode, dry-run versus real mode, schema version, overall status, redacted phase/status rows, aggregate counts, `appVerify` ready/failed gate outcomes, and generic guidance strings.

## Security review notes

The distribution scripts are local CLI surfaces. Their sensitive inputs are CLI arguments and raw Apple/Xcode tool output. The scripts reject high-risk argument shapes, do not echo rejected secret-like values, write raw tool output only to ignored workspaces, and emit summaries through the shared redaction helpers. If a script ever prints a raw Apple account, local path, certificate name, generated artifact path, token, or notary response, treat it as a redaction bug and do not preserve the output in tracked files.
