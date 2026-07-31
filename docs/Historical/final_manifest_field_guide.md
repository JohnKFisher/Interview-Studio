# Final Manifest Field Guide

This file explains `final_manifest.json`, the batch handoff file produced by `filmora-segment-export export`.

`final_manifest.json` is intended for future apps. It contains one JSON object per exported answer clip. Per-clip JSON sidecars are off by default because this batch file contains the same exported-row metadata plus structured nested `source_parts`.

## Core Identity Fields

| Field | Type | Meaning | Assembly App Use |
| --- | --- | --- | --- |
| `clip_number` | string/integer | Row number from the review manifest after grouping. | Display/debug identifier. Do not rely on this as permanent identity across regenerated manifests. |
| `sequence_index` | string/integer | Original export sequence order. | Default sort order if the app wants to mirror the Filmora timeline. |
| `person` | string | Human-readable person name supplied by the user. | Display label. |
| `person_key` | string | Machine-friendly person key. | Grouping/filtering. |
| `question` | string | Human-readable question text. | UI display label. |
| `question_key` | string | Stable machine-friendly question identifier. | Primary grouping key for reassembly. Users may edit this in `review_manifest.csv` to group wording variants together. |
| `question_original_index` | string/integer | Question order as discovered from the original timeline. | Initial/default question ordering in a reorderable UI. |
| `age` | string | Human-readable normalized age label, such as `6 Years Old` or `2.5 Years Old`. | UI display label. |
| `age_raw_text` | string | Age text as found in Filmora, such as `Age 6`, `6 Years Old`, or `21⁄2 Years Old`. | Debug/provenance. |
| `age_key` | string | Machine-friendly age key, such as `age-6` or `age-2-5`. | Grouping/filtering. |
| `age_years` | string/number/null | Parsed numeric age in years. Decimal half-year values are supported. | Age sorting and validation. |
| `age_sort_key` | string/number/null | Sort value for age. Usually same as `age_years`; may be decimal, such as `2.5`. | Sort responses within each question. |

## Output Fields

| Field | Type | Meaning | Assembly App Use |
| --- | --- | --- | --- |
| `output_file` | string | Exported movie path relative to the export folder. Clips are grouped into question folders, such as `Ellie - How old are You/Ellie-How-old-are-You-5-Years-Old.mov`. | Locate clip when reading from the same folder as the manifest. |
| `output_path` | string | Absolute output path used during export. | Useful locally; portable apps should prefer `output_file` when the folder may move. |
| `export_status` | string | `exported`, `skipped_existing`, or a failure status. | Include only successful/skipped rows in assembly. |
| `export_mode_requested` | string | Requested export mode, usually `auto`. | Debug/provenance. |
| `export_mode_used` | string | Actual method used, such as `copy`, `copy_plus_synthetic_freeze_pad`, `avfoundation_passthrough`, `avfoundation_multipart_passthrough`, or `exact`. | Debug/provenance and quality review. |
| `duration_drift_us` | integer/string | Difference between requested handled export duration and actual output duration in microseconds. | Warn if unexpectedly large. Default tolerance is 0.5 seconds. |
| `fallback_summary` | string | Short human-readable summary of `fallback_reason`, with noisy tool logs collapsed. | Useful for UIs, reports, and quick triage. Empty when there is no fallback or failure reason. |
| `fallback_reason` | string | Raw reason the exporter changed strategy or failed. This may include ffmpeg/Swift stderr. | Debug/provenance; use `fallback_summary` for display. |
| `hdr_dolby_validation` | string | Whether HDR/Dolby preservation passed, was not applicable, or failed. | Require `passed` for HDR/Dolby rows before using as replacement source. |
| `sidecar_written` | boolean | Whether a per-clip JSON sidecar was written. | Usually false. `final_manifest.json` is the preferred handoff. |
| `sidecar_path` | string | Absolute sidecar path if sidecars were enabled. | Optional/debug only. |

## Source Provenance Fields

| Field | Type | Meaning | Assembly App Use |
| --- | --- | --- | --- |
| `source_project` | string | Original Filmora archive/project path. | Provenance/debug. |
| `source_archive_member` | string | Source media member inside the `.wfpbundle` archive for single-part rows. | Provenance/debug. For multi-part rows, use `source_parts`. |
| `source_file` | string | Source media filename for single-part rows. | Provenance/debug. For multi-part rows, use `source_parts`. |
| `source_uuid` | string | Filmora source UUID for single-part rows. | Provenance/debug. |
| `source_is_dolby` | boolean/string | Whether the source was identified as HDR/Dolby-like from Filmora/ffprobe metadata. | Decide whether HDR/Dolby validation is mandatory. |
| `source_part_count` | string/integer | Number of source parts used to make the exported clip. | If greater than 1, the output preserves Filmora edits such as removed pauses or multi-file answers. |
| `source_parts` | array | Structured list of source parts used for the exported clip. | Preferred source provenance for future apps. |
| `source_parts_json` | string | CSV-compatible JSON string version of `source_parts`. | Ignore in JSON consumers; use `source_parts` instead. |

## Timing And Handles

All `*_us` fields are integer microseconds.

| Field | Type | Meaning | Assembly App Use |
| --- | --- | --- | --- |
| `parsed_source_in_us` | string/integer | Original Filmora source in-point before handles for the primary/merged range. | Provenance/debug. |
| `parsed_source_out_us` | string/integer | Original Filmora source out-point before handles for the primary/merged range. | Provenance/debug. |
| `source_duration_us` | string/integer/null | Source media duration in microseconds when known. | Validate handle clamping. |
| `requested_handle_before_us` | string/integer | Requested leading handle duration. Default: 2,000,000 us. | Understand available pre-roll. |
| `requested_handle_after_us` | string/integer | Requested trailing handle duration. Default: 2,000,000 us. | Understand available post-roll. |
| `actual_handle_before_us` | string/integer | Actual leading handle available in the exported file for the primary range. | Future editors can know how much trim room exists before the answer. |
| `actual_handle_after_us` | string/integer | Actual trailing handle available in the exported file for the primary range. | Future editors can know how much trim room exists after the answer. |
| `handle_before_status` | string | `full`, `partial_source_start`, `none_source_start`, or `disabled`. | UI warning if not full. |
| `handle_after_status` | string | `full`, `partial_source_end`, `none_source_end`, or `disabled`. | UI warning if not full. |
| `export_source_in_us` | string/integer | Actual source start after handles for the primary/merged range. | Provenance/debug. |
| `export_source_out_us` | string/integer | Actual source end after handles for the primary/merged range. | Provenance/debug. |

## Synthetic Freeze-Frame Padding

Synthetic handles are on by default during export. They are only used when the requested handle could not be filled with real source media because the Filmora source range is too close to the beginning or end of the source file.

Synthetic padding is not real handle material. It is display/editing padding made by holding the closest real video frame: the first real exported frame for missing leading handle, and the last real exported frame for missing trailing handle. When the clip has audio, synthetic padding uses silence, not invented room tone.

When synthetic padding is applied, the final output is re-encoded to create the held-frame sections. `export_mode_used` includes `_plus_synthetic_freeze_pad` so future tools do not mistake that output for a pure stream-copy/passthrough result.

HDR/Dolby rows do not receive synthetic freeze-frame padding if doing so would require a transcode that could alter HDR/Dolby metadata. In that case the real clip is preserved and the synthetic status fields explain that padding was skipped.

| Field | Type | Meaning | Assembly App Use |
| --- | --- | --- | --- |
| `synthetic_handles_enabled` | boolean | Whether export was asked to synthesize missing handles. Default: true. | Know whether missing real handles were eligible for freeze padding. |
| `synthetic_handle_method` | string | `freeze_frame` when synthetic padding was applied, otherwise empty. | Explain how synthetic padding was created. |
| `synthetic_handle_before_us` | integer | Leading synthetic padding duration included in `output_file`. | Treat as visual padding only, not source media. |
| `synthetic_handle_after_us` | integer | Trailing synthetic padding duration included in `output_file`. | Treat as visual padding only, not source media. |
| `synthetic_handle_before_status` | string | `applied`, `not_needed`, `disabled`, or a skipped/failed reason. | Warn users when requested padding could not be represented. |
| `synthetic_handle_after_status` | string | `applied`, `not_needed`, `disabled`, or a skipped/failed reason. | Warn users when requested padding could not be represented. |
| `real_media_start_in_output_us` | integer | Timestamp in `output_file` where real exported source media begins. | Do not treat earlier frames as source provenance. |
| `real_media_end_in_output_us` | integer | Timestamp in `output_file` where real exported source media ends. | Do not treat later frames as source provenance. |
| `answer_start_in_output_us` | integer | Timestamp in `output_file` where the actual answer begins, after synthetic and real leading handle. | Use as the default trim-in/edit point. |
| `answer_end_in_output_us` | integer | Timestamp in `output_file` where the actual answer ends, before real and synthetic trailing handle. | Use as the default trim-out/edit point. |

The real handle fields remain authoritative for provenance. For example, if `actual_handle_before_us` is `500000` and `synthetic_handle_before_us` is `1500000`, the file has two seconds of visible pre-roll, but only the final half-second before the answer is real source media.

For multi-part rows, each entry in `source_parts` has its own parsed/export ranges and handle status. Handles are applied only to the beginning of the first part and the end of the last part, so removed pauses do not get reintroduced.

## Timeline Provenance Fields

| Field | Type | Meaning | Assembly App Use |
| --- | --- | --- | --- |
| `timeline_start_us` | string/integer | Original Filmora timeline start for this answer segment. | Provenance/default sorting. |
| `timeline_end_us` | string/integer | Original Filmora timeline end for this answer segment. | Provenance/default sorting. |
| `original_question_timeline_start_us` | string/integer | Timeline position of the question/title card. | Debug/provenance. |
| `original_age_overlay_timeline_start_us` | string/integer/null | Timeline position of the matched age overlay. | Debug/provenance. |

## Review And Parser Fields

| Field | Type | Meaning | Assembly App Use |
| --- | --- | --- | --- |
| `status` | string | Review status from `review_manifest.csv`, usually `ready`. | Export only uses ready rows. |
| `confidence` | string | Parser confidence: `high`, `medium`, or `low`. | Display warnings or require human review. |
| `warnings` | string | Semicolon-separated notes from grouping/export preparation. | Show non-blocking caveats. Important examples include `merged_source_clips`, `merged_contiguous_source_clips`, `merged_edited_source_clips`, `merged_multiple_source_files`, and partial handle warnings. |
| `notes` | string | User-editable notes from the review manifest. | Display or preserve as user metadata. |

## Video Signature Fields

| Field | Type | Meaning | Assembly App Use |
| --- | --- | --- | --- |
| `source_video_signature` | object/array | ffprobe-derived codec/color/HDR metadata from source media. Multi-part rows may contain an array. | Technical validation/provenance. |
| `output_video_signature` | object | ffprobe-derived codec/color/HDR metadata from exported output. | Confirm output stayed compatible with source expectations. |

## `source_parts` Entry Fields

Each `source_parts` entry describes one source range that contributed to the final exported clip.

| Field | Type | Meaning |
| --- | --- | --- |
| `part_index` | integer | 1-based part order inside the exported clip. |
| `source_archive_member` | string | Media path inside the `.wfpbundle`. |
| `source_file` | string | Source media filename. |
| `source_uuid` | string | Filmora source UUID. |
| `source_is_dolby` | boolean | Whether this part appears HDR/Dolby-like. |
| `parsed_source_in_us` / `parsed_source_out_us` | integer | Filmora source range before handles. |
| `export_source_in_us` / `export_source_out_us` | integer | Actual source range exported after available handles. |
| `source_duration_us` | integer/null | Source media duration when known. |
| `actual_handle_before_us` / `actual_handle_after_us` | integer | Actual handle included for this part. |
| `handle_before_status` / `handle_after_status` | string | Handle availability for this part. |

## Recommended Assembly-App Interpretation

1. Load `final_manifest.json`.
2. Keep rows where `export_status` is `exported` or `skipped_existing`.
3. Group by `person_key`, then `question_key`.
4. Use `question` as the display title, but let users rename/reorder questions in the new app.
5. Sort responses inside each question by `age_sort_key`.
6. Locate media by `output_file` relative to the manifest folder when possible.
7. Use `source_parts` only for provenance and diagnostics; the exported movie is already assembled.
8. Use `answer_start_in_output_us` and `answer_end_in_output_us` as the default answer boundaries inside `output_file`.
9. Treat `synthetic_handle_before_us` and `synthetic_handle_after_us` as visual padding only. Do not present synthetic padding as recoverable source media.
10. Show warnings when `source_part_count > 1`, handle status is not `full`, synthetic handle status is skipped/failed, or `hdr_dolby_validation` is not `passed` for HDR/Dolby rows.
