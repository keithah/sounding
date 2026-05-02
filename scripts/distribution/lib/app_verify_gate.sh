#!/usr/bin/env bash
# App verification evidence gate helpers for local distribution packaging.
#
# Sourceable library: defines controlled vocabulary and validation helpers only.
# The validator intentionally emits only stable status/code/message triples; it
# never prints evidence paths, parser exceptions, raw JSON values, or snippets.

readonly APP_VERIFY_GATE_KIND_FIXTURE="fixture"
readonly APP_VERIFY_GATE_KIND_LIVE="live"

readonly APP_VERIFY_GATE_STATUS_READY="ready"
readonly APP_VERIFY_GATE_STATUS_FAILED="failed"

readonly APP_VERIFY_GATE_CODE_READY="app_verify_evidence_ready"
readonly APP_VERIFY_GATE_CODE_MISSING="app_verify_evidence_missing"
readonly APP_VERIFY_GATE_CODE_UNREADABLE="app_verify_evidence_unreadable"
readonly APP_VERIFY_GATE_CODE_TOO_LARGE="app_verify_evidence_too_large"
readonly APP_VERIFY_GATE_CODE_MALFORMED="app_verify_evidence_malformed"
readonly APP_VERIFY_GATE_CODE_WRONG_SCHEMA="app_verify_evidence_wrong_schema"
readonly APP_VERIFY_GATE_CODE_FAILED_SUMMARY="app_verify_evidence_failed_summary"
readonly APP_VERIFY_GATE_CODE_FAILED_REQUIRED="app_verify_evidence_failed_required_checks"
readonly APP_VERIFY_GATE_CODE_MISSING_CHECKS="app_verify_evidence_missing_required_checks"
readonly APP_VERIFY_GATE_CODE_VALIDATOR="app_verify_evidence_validator_unavailable"

readonly APP_VERIFY_GATE_MESSAGE_READY="App verification evidence is ready for packaging."
readonly APP_VERIFY_GATE_MESSAGE_MISSING="App verification evidence is missing."
readonly APP_VERIFY_GATE_MESSAGE_UNREADABLE="App verification evidence could not be read."
readonly APP_VERIFY_GATE_MESSAGE_TOO_LARGE="App verification evidence is larger than the supported compact evidence limit."
readonly APP_VERIFY_GATE_MESSAGE_MALFORMED="App verification evidence is malformed or incomplete."
readonly APP_VERIFY_GATE_MESSAGE_WRONG_SCHEMA="App verification evidence uses an unsupported schema version."
readonly APP_VERIFY_GATE_MESSAGE_FAILED_SUMMARY="App verification evidence did not report an acceptable summary status."
readonly APP_VERIFY_GATE_MESSAGE_FAILED_REQUIRED="App verification evidence reported failed required checks."
readonly APP_VERIFY_GATE_MESSAGE_MISSING_CHECKS="App verification evidence is missing required check names."
readonly APP_VERIFY_GATE_MESSAGE_VALIDATOR="App verification evidence could not be validated by the local validator."

readonly APP_VERIFY_GATE_MAX_BYTES="1048576"

# Keep these in sync with Sources/SoundingKit/AppVerification/AppVerifyEvidence.swift.
readonly APP_VERIFY_GATE_FIXTURE_REQUIRED_CHECKS=(
    "fixture_source_created"
    "database_opened"
    "stream_registered"
    "runtime_started"
    "decode_completed"
    "avfoundation_playback_scheduled"
    "runtime_stopped"
    "diagnostics_written"
    "playback_muted"
    "playback_unmuted"
    "playback_volume_changed"
    "runtime_stop_observed"
    "runtime_restart_observed"
    "transcript_persistence"
    "transcript_timeline_projection"
    "transcript_search_projection"
    "song_metadata_projection"
    "ad_metadata_projection"
)

readonly APP_VERIFY_GATE_LIVE_REQUIRED_CHECKS=(
    "live_config_validated"
    "live_stream_registered"
    "live_runtime_started"
    "live_decode_opened"
    "live_playback_scheduled"
    "live_runtime_stopped"
    "live_diagnostics_written"
    "live_transcript_observed"
    "live_metadata_observed"
)

app_verify_gate_message_for_code() {
    case "${1-}" in
        "$APP_VERIFY_GATE_CODE_READY") printf '%s' "$APP_VERIFY_GATE_MESSAGE_READY" ;;
        "$APP_VERIFY_GATE_CODE_MISSING") printf '%s' "$APP_VERIFY_GATE_MESSAGE_MISSING" ;;
        "$APP_VERIFY_GATE_CODE_UNREADABLE") printf '%s' "$APP_VERIFY_GATE_MESSAGE_UNREADABLE" ;;
        "$APP_VERIFY_GATE_CODE_TOO_LARGE") printf '%s' "$APP_VERIFY_GATE_MESSAGE_TOO_LARGE" ;;
        "$APP_VERIFY_GATE_CODE_MALFORMED") printf '%s' "$APP_VERIFY_GATE_MESSAGE_MALFORMED" ;;
        "$APP_VERIFY_GATE_CODE_WRONG_SCHEMA") printf '%s' "$APP_VERIFY_GATE_MESSAGE_WRONG_SCHEMA" ;;
        "$APP_VERIFY_GATE_CODE_FAILED_SUMMARY") printf '%s' "$APP_VERIFY_GATE_MESSAGE_FAILED_SUMMARY" ;;
        "$APP_VERIFY_GATE_CODE_FAILED_REQUIRED") printf '%s' "$APP_VERIFY_GATE_MESSAGE_FAILED_REQUIRED" ;;
        "$APP_VERIFY_GATE_CODE_MISSING_CHECKS") printf '%s' "$APP_VERIFY_GATE_MESSAGE_MISSING_CHECKS" ;;
        *) printf '%s' "$APP_VERIFY_GATE_MESSAGE_VALIDATOR" ;;
    esac
}

app_verify_gate_emit_result() {
    local status="${1-}"
    local code="${2-}"
    local message
    message=$(app_verify_gate_message_for_code "$code")
    printf '%s\t%s\t%s\n' "$status" "$code" "$message"
}

app_verify_gate_known_code() {
    case "${1-}" in
        "$APP_VERIFY_GATE_CODE_READY"|"$APP_VERIFY_GATE_CODE_MISSING"|"$APP_VERIFY_GATE_CODE_UNREADABLE"|\
        "$APP_VERIFY_GATE_CODE_TOO_LARGE"|"$APP_VERIFY_GATE_CODE_MALFORMED"|"$APP_VERIFY_GATE_CODE_WRONG_SCHEMA"|\
        "$APP_VERIFY_GATE_CODE_FAILED_SUMMARY"|"$APP_VERIFY_GATE_CODE_FAILED_REQUIRED"|\
        "$APP_VERIFY_GATE_CODE_MISSING_CHECKS"|"$APP_VERIFY_GATE_CODE_VALIDATOR")
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Validate compact AppVerifyEvidence JSON for the requested kind.
# Output: <status> TAB <controlled-code> TAB <controlled-message>
# Return: 0 when ready, non-zero when packaging must not proceed.
app_verify_gate_validate_evidence() {
    local kind="${1-}"
    local evidence_path="${2-}"
    local required_checks=()
    local allowed_statuses=()
    local byte_count output status code message

    case "$kind" in
        "$APP_VERIFY_GATE_KIND_FIXTURE")
            required_checks=("${APP_VERIFY_GATE_FIXTURE_REQUIRED_CHECKS[@]}")
            allowed_statuses=("pass")
            ;;
        "$APP_VERIFY_GATE_KIND_LIVE")
            required_checks=("${APP_VERIFY_GATE_LIVE_REQUIRED_CHECKS[@]}")
            allowed_statuses=("pass" "warn")
            ;;
        *)
            app_verify_gate_emit_result "$APP_VERIFY_GATE_STATUS_FAILED" "$APP_VERIFY_GATE_CODE_VALIDATOR"
            return 1
            ;;
    esac

    if [[ -z "$evidence_path" || ! -e "$evidence_path" ]]; then
        app_verify_gate_emit_result "$APP_VERIFY_GATE_STATUS_FAILED" "$APP_VERIFY_GATE_CODE_MISSING"
        return 1
    fi
    if [[ ! -f "$evidence_path" || ! -r "$evidence_path" ]]; then
        app_verify_gate_emit_result "$APP_VERIFY_GATE_STATUS_FAILED" "$APP_VERIFY_GATE_CODE_UNREADABLE"
        return 1
    fi

    byte_count=$(wc -c < "$evidence_path" 2>/dev/null | tr -d '[:space:]') || byte_count=""
    case "$byte_count" in
        ''|*[!0-9]*)
            app_verify_gate_emit_result "$APP_VERIFY_GATE_STATUS_FAILED" "$APP_VERIFY_GATE_CODE_UNREADABLE"
            return 1
            ;;
    esac
    if (( byte_count > APP_VERIFY_GATE_MAX_BYTES )); then
        app_verify_gate_emit_result "$APP_VERIFY_GATE_STATUS_FAILED" "$APP_VERIFY_GATE_CODE_TOO_LARGE"
        return 1
    fi

    output=$(/usr/bin/python3 - "$evidence_path" "${allowed_statuses[@]}" -- "${required_checks[@]}" <<'PY' 2>/dev/null
import json
import sys

READY = "app_verify_evidence_ready"
MALFORMED = "app_verify_evidence_malformed"
WRONG_SCHEMA = "app_verify_evidence_wrong_schema"
FAILED_SUMMARY = "app_verify_evidence_failed_summary"
FAILED_REQUIRED = "app_verify_evidence_failed_required_checks"
MISSING_CHECKS = "app_verify_evidence_missing_required_checks"
VALIDATOR = "app_verify_evidence_validator_unavailable"


def emit(status, code):
    print(f"{status}\t{code}")

try:
    separator = sys.argv.index("--")
except ValueError:
    emit("failed", VALIDATOR)
    sys.exit(0)

path = sys.argv[1]
allowed_statuses = set(sys.argv[2:separator])
required_names = set(sys.argv[separator + 1:])

try:
    with open(path, "rb") as handle:
        evidence = json.load(handle)
except Exception:
    emit("failed", MALFORMED)
    sys.exit(0)

if not isinstance(evidence, dict):
    emit("failed", MALFORMED)
    sys.exit(0)

if evidence.get("schemaVersion") != 1:
    emit("failed", WRONG_SCHEMA)
    sys.exit(0)

summary = evidence.get("summary")
checks = evidence.get("checks")
if not isinstance(summary, dict) or not isinstance(checks, list):
    emit("failed", MALFORMED)
    sys.exit(0)

summary_status = summary.get("status")
failed_required = summary.get("failedRequiredCheckCount")
if not isinstance(summary_status, str) or not isinstance(failed_required, int):
    emit("failed", MALFORMED)
    sys.exit(0)
if summary_status not in allowed_statuses:
    emit("failed", FAILED_SUMMARY)
    sys.exit(0)
if failed_required != 0:
    emit("failed", FAILED_REQUIRED)
    sys.exit(0)

seen = set()
for check in checks:
    if not isinstance(check, dict):
        emit("failed", MALFORMED)
        sys.exit(0)
    name = check.get("name")
    if isinstance(name, str):
        seen.add(name)

if not required_names.issubset(seen):
    emit("failed", MISSING_CHECKS)
    sys.exit(0)

emit("ready", READY)
PY
    ) || {
        app_verify_gate_emit_result "$APP_VERIFY_GATE_STATUS_FAILED" "$APP_VERIFY_GATE_CODE_VALIDATOR"
        return 1
    }

    status=${output%%$'\t'*}
    code=${output#*$'\t'}
    code=${code%%$'\t'*}
    message=$(app_verify_gate_message_for_code "$code")

    if [[ "$status" == "$APP_VERIFY_GATE_STATUS_READY" && "$code" == "$APP_VERIFY_GATE_CODE_READY" ]]; then
        printf '%s\t%s\t%s\n' "$status" "$code" "$message"
        return 0
    fi

    if [[ "$status" == "$APP_VERIFY_GATE_STATUS_FAILED" ]] && app_verify_gate_known_code "$code"; then
        printf '%s\t%s\t%s\n' "$status" "$code" "$message"
        return 1
    fi

    app_verify_gate_emit_result "$APP_VERIFY_GATE_STATUS_FAILED" "$APP_VERIFY_GATE_CODE_VALIDATOR"
    return 1
}
