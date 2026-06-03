#!/usr/bin/env bash
# Distribution diagnostics helpers for Developer ID packaging.
#
# This file is a sourceable shell library. It intentionally performs no work at
# source time beyond defining constants and functions; downstream scripts call
# the helpers when they need redacted, deterministic diagnostics.

# Phase vocabulary used by distribution checks and packaging scripts.
readonly DISTRIBUTION_PHASE_ENVIRONMENT="environment"
readonly DISTRIBUTION_PHASE_SIGNING_IDENTITY="signingIdentity"
readonly DISTRIBUTION_PHASE_ARCHIVE="archive"
readonly DISTRIBUTION_PHASE_EXPORT="export"
readonly DISTRIBUTION_PHASE_CODESIGN="codesign"
readonly DISTRIBUTION_PHASE_NOTARY_SUBMIT="notarySubmit"
readonly DISTRIBUTION_PHASE_NOTARY_WAIT="notaryWait"
readonly DISTRIBUTION_PHASE_NOTARY_LOG="notaryLog"
readonly DISTRIBUTION_PHASE_STAPLE="staple"
readonly DISTRIBUTION_PHASE_GATEKEEPER="gatekeeper"
readonly DISTRIBUTION_PHASE_DMG="dmg"
readonly DISTRIBUTION_PHASE_APP_VERIFY="appVerify"
readonly DISTRIBUTION_PHASE_OUTPUT="output"
readonly DISTRIBUTION_PHASE_REDACTION="redaction"
readonly DISTRIBUTION_PHASE_UNKNOWN="unknown"

# Status vocabulary used by JSON and human summaries.
readonly DISTRIBUTION_STATUS_READY="ready"
readonly DISTRIBUTION_STATUS_SKIPPED="skipped"
readonly DISTRIBUTION_STATUS_MISSING_CREDENTIAL="missingCredential"
readonly DISTRIBUTION_STATUS_FAILED="failed"
readonly DISTRIBUTION_STATUS_NOTARIZATION_REJECTED="notarizationRejected"
readonly DISTRIBUTION_STATUS_REDACTION_FAILURE="redactionFailure"
readonly DISTRIBUTION_STATUS_UNKNOWN="unknown"

# Fixed guidance strings. Keep these generic: no local paths, identities, team
# identifiers, keychain profile names, or command output should be interpolated.
readonly DISTRIBUTION_GUIDANCE_ENVIRONMENT="Install Xcode command line tools and retry distribution checks."
readonly DISTRIBUTION_GUIDANCE_SIGNING_IDENTITY="Install a local Developer ID Application certificate and rerun the check."
readonly DISTRIBUTION_GUIDANCE_NOTARY_PROFILE="Configure an operator-local notary keychain profile before real notarization."
readonly DISTRIBUTION_GUIDANCE_ARCHIVE="Inspect the local xcodebuild log in the ignored distribution workspace."
readonly DISTRIBUTION_GUIDANCE_CODESIGN="Inspect local codesign verification output and rebuild the archive."
readonly DISTRIBUTION_GUIDANCE_NOTARY="Inspect the local notary log in the ignored distribution workspace."
readonly DISTRIBUTION_GUIDANCE_STAPLE="Retry stapling after notarization succeeds and inspect the local stapler log."
readonly DISTRIBUTION_GUIDANCE_GATEKEEPER="Inspect local Gatekeeper assessment output for the generated artifact."
readonly DISTRIBUTION_GUIDANCE_DMG="Inspect the local DMG creation or verification log in the ignored distribution workspace."
readonly DISTRIBUTION_GUIDANCE_APP_VERIFY="Run fixture and live app verification, then retry packaging with their evidence JSON files."
readonly DISTRIBUTION_GUIDANCE_OUTPUT="Use an ignored writable output directory and retry."
readonly DISTRIBUTION_GUIDANCE_REDACTION="Do not emit raw tool output; inspect ignored local logs instead."

# Escape a string for use inside a JSON string value. The caller is responsible
# for surrounding the returned value with double quotes.
distribution_json_escape() {
    local value="${1-}"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/\\n}"
    value="${value//$'\r'/\\r}"
    value="${value//$'\t'/\\t}"
    printf '%s' "$value"
}

distribution_run_bounded() {
    local timeout_seconds="$1"
    shift
    /usr/bin/python3 - "$timeout_seconds" "$@" <<'PY'
import subprocess
import sys

timeout = float(sys.argv[1])
cmd = sys.argv[2:]
try:
    result = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout, check=False)
    sys.stdout.buffer.write(result.stdout)
    sys.stdout.buffer.write(result.stderr)
    sys.exit(result.returncode)
except subprocess.TimeoutExpired as exc:
    if exc.stdout:
        sys.stdout.buffer.write(exc.stdout)
    if exc.stderr:
        sys.stdout.buffer.write(exc.stderr)
    sys.exit(124)
except Exception:
    sys.exit(127)
PY
}

distribution_run_bounded_to_log() {
    local timeout_seconds="$1"
    local log_path="$2"
    shift 2
    /usr/bin/python3 - "$timeout_seconds" "$log_path" "$@" <<'PY'
import subprocess
import sys

timeout = float(sys.argv[1])
log_path = sys.argv[2]
cmd = sys.argv[3:]
try:
    result = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout, check=False)
    with open(log_path, "ab") as handle:
        handle.write(result.stdout)
    sys.exit(result.returncode)
except subprocess.TimeoutExpired as exc:
    with open(log_path, "ab") as handle:
        if exc.stdout:
            handle.write(exc.stdout)
        handle.write(b"\n[distribution-package-timeout]\n")
    sys.exit(124)
except Exception as exc:
    with open(log_path, "ab") as handle:
        handle.write(("[distribution-package-error] " + exc.__class__.__name__ + "\n").encode("utf-8"))
    sys.exit(127)
PY
}

# Return success when the phase is in the supported distribution vocabulary.
distribution_is_known_phase() {
    case "${1-}" in
        "$DISTRIBUTION_PHASE_ENVIRONMENT"|"$DISTRIBUTION_PHASE_SIGNING_IDENTITY"|"$DISTRIBUTION_PHASE_ARCHIVE"|\
        "$DISTRIBUTION_PHASE_EXPORT"|"$DISTRIBUTION_PHASE_CODESIGN"|"$DISTRIBUTION_PHASE_NOTARY_SUBMIT"|\
        "$DISTRIBUTION_PHASE_NOTARY_WAIT"|"$DISTRIBUTION_PHASE_NOTARY_LOG"|"$DISTRIBUTION_PHASE_STAPLE"|\
        "$DISTRIBUTION_PHASE_GATEKEEPER"|"$DISTRIBUTION_PHASE_DMG"|"$DISTRIBUTION_PHASE_APP_VERIFY"|\
        "$DISTRIBUTION_PHASE_OUTPUT"|"$DISTRIBUTION_PHASE_REDACTION"|"$DISTRIBUTION_PHASE_UNKNOWN")
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Return success when the status is in the supported distribution vocabulary.
distribution_is_known_status() {
    case "${1-}" in
        "$DISTRIBUTION_STATUS_READY"|"$DISTRIBUTION_STATUS_SKIPPED"|"$DISTRIBUTION_STATUS_MISSING_CREDENTIAL"|\
        "$DISTRIBUTION_STATUS_FAILED"|"$DISTRIBUTION_STATUS_NOTARIZATION_REJECTED"|\
        "$DISTRIBUTION_STATUS_REDACTION_FAILURE"|"$DISTRIBUTION_STATUS_UNKNOWN")
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Convert arbitrary phase text to a safe supported phase.
distribution_safe_phase() {
    local phase="${1-}"
    if distribution_is_known_phase "$phase"; then
        printf '%s' "$phase"
    else
        printf '%s' "$DISTRIBUTION_PHASE_UNKNOWN"
    fi
}

# Convert arbitrary status text to a safe supported status.
distribution_safe_status() {
    local status="${1-}"
    if distribution_is_known_status "$status"; then
        printf '%s' "$status"
    else
        printf '%s' "$DISTRIBUTION_STATUS_REDACTION_FAILURE"
    fi
}

# Redact Apple distribution tool output. Inputs are untrusted; never pass raw
# command output directly to console/tracked summaries. This helper deliberately
# replaces broad classes of sensitive values with stable placeholders.
distribution_redact_text() {
    local input="${1-}"
    local output

    if ! output=$(printf '%s' "$input" | /usr/bin/perl -0pe '
        s{\r}{\n}g;
        s{(?i)Developer ID (?:Application|Installer):\s*[^\n\r()]+\s*\([A-Z0-9]{6,12}\)}{[redacted-developer-id]}g;
        s{(?i)Developer ID (?:Application|Installer):\s*[^\n\r]+}{[redacted-developer-id]}g;
        s{(?i)\b(?:team(?:[-_ ]?id)?|teamIdentifier|TeamIdentifier)\s*[:=]\s*[A-Z0-9]{6,12}\b}{$1=[redacted-team-id]}g;
        s{\b[A-Z0-9]{10}\b}{[redacted-team-id]}g;
        s{(?i)\b(?:apple[-_ ]?id|username|user|account)\s*[:=]\s*[^\s"'\''<>]+}{$1=[redacted-account]}g;
        s{\b[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}\b}{[redacted-email]}gi;
        s{(?i)\b(?:keychain[-_ ]?profile|notary[-_ ]?profile|profile)\s*[:=]\s*[^\s"'\''<>]+}{$1=[redacted-profile]}g;
        s{(?i)\b(?:keychain[-_ ]?profile|notary[-_ ]?profile|profile)\s+[^\s"'\''<>]+}{$1 [redacted-profile]}g;
        s{(?i)\b(?:password|passwd|pwd|token|api[-_]?key|secret|app[-_ ]?specific[-_ ]?password)\s*[:=]\s*[^\s"'\''<>]+}{$1=[redacted-secret]}g;
        s{(?i)\b(?:id|submission[-_ ]?id|request[-_ ]?uuid)\s*[:=]\s*[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b}{$1=[redacted-id]}g;
        s{\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b}{[redacted-id]}gi;
        s{[A-Za-z][A-Za-z0-9+.-]*://[^\s"'\''<>]+}{[redacted-url]}g;
        s{(?<![A-Za-z0-9])(?:~|/Users|/private/tmp|/tmp|/var/folders)/[^\s"'\''<>]+}{[redacted-path]}g;
        s{[^\s"'\''<>]*(?:notary-logs\.local|shipping\.local|\.xcarchive|\.dmg|\.pkg|\.app)(?:/[^\s"'\''<>]*)?}{[redacted-artifact]}gi;
        s{(?i)\b(?:log(?:File|Path)?|path|output[-_ ]?dir|output|archive)\s*[:=]\s*[^\s"'\''<>]+}{$1=[redacted-path]}g;
    '); then
        printf '%s' "$DISTRIBUTION_STATUS_REDACTION_FAILURE"
        return 1
    fi

    # Redaction failure guard: if high-risk tokens remain, suppress the whole
    # message rather than leaking a partially redacted diagnostic.
    if printf '%s' "$output" | /usr/bin/perl -0ne '
        exit 0 if m{(?i)(Developer ID Application:|Developer ID Installer:|/Users/|/private/tmp/|/tmp/|notary-logs\.local|shipping\.local|\.xcarchive|\.dmg|[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}|[?#][^\s"'\''<>]+|password\s*[:=]|token\s*[:=]|app[-_ ]?specific[-_ ]?password\s*[:=])};
        exit 1;
    '; then
        printf '%s' "$DISTRIBUTION_STATUS_REDACTION_FAILURE"
        return 1
    fi

    printf '%s' "$output"
}

# Classify raw distribution output into a safe phase/status pair. The first
# field is the phase and the second field is the status, separated by a tab.
distribution_classify_output() {
    local input="${1-}"
    local lowered
    lowered=$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]')

    case "$lowered" in
        *"developer id application"*|*"no signing certificate"*|*"valid signing identity"*|*"signing identity"*)
            printf '%s\t%s' "$DISTRIBUTION_PHASE_SIGNING_IDENTITY" "$DISTRIBUTION_STATUS_MISSING_CREDENTIAL"
            ;;
        *"spctl"*|*"gatekeeper"*|*"assessment"*)
            printf '%s\t%s' "$DISTRIBUTION_PHASE_GATEKEEPER" "$DISTRIBUTION_STATUS_FAILED"
            ;;
        *"rejected"*|*"invalid binary"*)
            printf '%s\t%s' "$DISTRIBUTION_PHASE_NOTARY_WAIT" "$DISTRIBUTION_STATUS_NOTARIZATION_REJECTED"
            ;;
        *"notarytool"*"invalid"*|*"notarytool"*"profile"*|*"keychain profile"*|*"apple id"*)
            printf '%s\t%s' "$DISTRIBUTION_PHASE_NOTARY_SUBMIT" "$DISTRIBUTION_STATUS_MISSING_CREDENTIAL"
            ;;
        *"invalid"*"developer"*"path"*|*"xcode-select"*|*"xcodebuild: error"*"toolchain"*)
            printf '%s\t%s' "$DISTRIBUTION_PHASE_ENVIRONMENT" "$DISTRIBUTION_STATUS_FAILED"
            ;;
        *"exportarchive"*|*"export failed"*)
            printf '%s\t%s' "$DISTRIBUTION_PHASE_EXPORT" "$DISTRIBUTION_STATUS_FAILED"
            ;;
        *"xcodebuild"*|*"archive failed"*|*"archive"*)
            printf '%s\t%s' "$DISTRIBUTION_PHASE_ARCHIVE" "$DISTRIBUTION_STATUS_FAILED"
            ;;
        *"codesign"*|*"code object is not signed"*)
            printf '%s\t%s' "$DISTRIBUTION_PHASE_CODESIGN" "$DISTRIBUTION_STATUS_FAILED"
            ;;
        *"notary log"*|*"logfile"*|*"log file"*)
            printf '%s\t%s' "$DISTRIBUTION_PHASE_NOTARY_LOG" "$DISTRIBUTION_STATUS_FAILED"
            ;;
        *"stapler"*|*"staple"*)
            printf '%s\t%s' "$DISTRIBUTION_PHASE_STAPLE" "$DISTRIBUTION_STATUS_FAILED"
            ;;
        *"hdiutil"*|*"dmg"*)
            printf '%s\t%s' "$DISTRIBUTION_PHASE_DMG" "$DISTRIBUTION_STATUS_FAILED"
            ;;
        *"permission denied"*|*"no such file"*|*"output"*)
            printf '%s\t%s' "$DISTRIBUTION_PHASE_OUTPUT" "$DISTRIBUTION_STATUS_FAILED"
            ;;
        "")
            printf '%s\t%s' "$DISTRIBUTION_PHASE_UNKNOWN" "$DISTRIBUTION_STATUS_REDACTION_FAILURE"
            ;;
        *)
            printf '%s\t%s' "$DISTRIBUTION_PHASE_UNKNOWN" "$DISTRIBUTION_STATUS_REDACTION_FAILURE"
            ;;
    esac
}

# Emit one deterministic JSON object for a phase summary. Values are sanitized;
# unknown phase/status values are converted to safe fallback vocabulary.
distribution_emit_json_summary() {
    local phase status message guidance
    phase=$(distribution_safe_phase "${1-}")
    status=$(distribution_safe_status "${2-}")
    message=$(distribution_redact_text "${3-}") || message="$DISTRIBUTION_STATUS_REDACTION_FAILURE"
    guidance=$(distribution_redact_text "${4-}") || guidance="$DISTRIBUTION_GUIDANCE_REDACTION"

    printf '{"guidance":"%s","message":"%s","phase":"%s","status":"%s"}\n' \
        "$(distribution_json_escape "$guidance")" \
        "$(distribution_json_escape "$message")" \
        "$(distribution_json_escape "$phase")" \
        "$(distribution_json_escape "$status")"
}

# Emit one human-readable summary line with the same safe vocabulary.
distribution_emit_human_summary() {
    local phase status message guidance
    phase=$(distribution_safe_phase "${1-}")
    status=$(distribution_safe_status "${2-}")
    message=$(distribution_redact_text "${3-}") || message="$DISTRIBUTION_STATUS_REDACTION_FAILURE"
    guidance=$(distribution_redact_text "${4-}") || guidance="$DISTRIBUTION_GUIDANCE_REDACTION"

    printf 'Distribution %s: status=%s message=%s guidance=%s\n' "$phase" "$status" "$message" "$guidance"
}
