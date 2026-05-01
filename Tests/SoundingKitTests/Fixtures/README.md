# SoundingKit Test Fixtures

This directory is intentionally tracked for reusable SoundingKit fixtures.

Guidelines for future slices:

- Store small deterministic fixtures that are safe to commit.
- Prefer source-control-friendly names that describe the stream type and marker format.
- Do not commit secrets, private stream URLs, raw credentials, or user-specific captures.
- Large generated or environment-specific artifacts belong outside the repository.

## MPEGTS

- `MPEGTS/scte35_splice_null.ts` is a tiny generated test-only transport stream fixture containing one PAT, one PMT with SCTE-35 stream type `0x86`, and one deterministic `splice_null()` SCTE-35 section.
- The fixture is synthetic, contains no private source data, and exists only to keep MPEG-TS/UDP extraction tests deterministic.
