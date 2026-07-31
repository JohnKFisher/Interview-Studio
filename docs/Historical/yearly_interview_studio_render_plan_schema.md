# Yearly Interview Studio — Render Plan Schema

This document defines the internal render-plan contract for Phase 1.

The render plan is the bridge between:

```text
Manifest + User Settings → Render Plan → Renderer/FFmpeg
```

The render plan must be deterministic, inspectable, and serializable to JSON.

---

## Top-Level Render Plan

```json
{
  "schema_version": "1.0",
  "app_name": "Yearly Interview Studio",
  "project": {
    "project_id": "uuid-or-stable-id",
    "project_name": "Ellie Interview",
    "manifest_path": "/path/to/final_manifest.json",
    "media_root": "/path/to/export-folder"
  },
  "export_profile": {
    "profile_id": "apple_hlg_4k60",
    "width": 3840,
    "height": 2160,
    "frame_rate": 60,
    "dynamic_range": "hdr_hlg",
    "codec": "hevc_main10",
    "color_primaries": "bt2020",
    "color_transfer": "arib-std-b67",
    "color_matrix": "bt2020nc"
  },
  "settings": {
    "answer_transition": {
      "style": "soft_crossfade",
      "duration_frames": 12,
      "fallback": "clean_cut"
    },
    "question_card_transition": {
      "style": "fade_through_black"
    },
    "audio": {
      "gentle_loudness_match": true,
      "target_lufs": -16.0,
      "true_peak_ceiling_dbtp": -1.0
    },
    "overlays": {
      "show_age_overlay": true,
      "show_question_overlay": false
    }
  },
  "sequence": [],
  "issues": [],
  "summary": {}
}
```

---

## Sequence Node Types

### Opening Card

```json
{
  "node_id": "opening-001",
  "type": "opening_card",
  "text": {
    "title": "Ellie: Yearly Interview",
    "subtitle": ""
  },
  "template": {
    "template_id": "opening_minimal",
    "duration_seconds": 2.0,
    "duration_source": "template_default"
  },
  "transition_out": {
    "style": "fade_through_black",
    "duration_frames": 12
  }
}
```

### Question Card

```json
{
  "node_id": "question-card-what-is-your-name",
  "type": "question_card",
  "question_key": "what-is-your-name",
  "question_text": "What is your name?",
  "template": {
    "template_id": "question_clean_fullscreen",
    "duration_seconds": 1.5,
    "duration_source": "manual_override"
  },
  "transition_in": {
    "style": "fade_through_black",
    "duration_frames": 12
  },
  "transition_out": {
    "style": "cut",
    "duration_frames": 0
  }
}
```

### Answer Clip

```json
{
  "node_id": "answer-what-is-your-name-age-6",
  "type": "answer_clip",
  "clip_ref": {
    "clip_id": "manifest-row-stable-id",
    "clip_number": "5",
    "output_file": "Ellie - What is Your Name/Ellie-What-is-Your-Name-6-Years-Old.mov",
    "resolved_path": "/path/to/Ellie-What-is-Your-Name-6-Years-Old.mov"
  },
  "identity": {
    "person": "Ellie",
    "person_key": "ellie",
    "question_key": "what-is-your-name",
    "question_text": "What is your name?",
    "age": "6 Years Old",
    "age_key": "age-6",
    "age_sort_key": 6.0
  },
  "timing": {
    "answer_start_in_output_us": 2000000,
    "answer_end_in_output_us": 3600000,
    "real_media_start_in_output_us": 0,
    "real_media_end_in_output_us": 5600000,
    "duration_us": 1600000
  },
  "handles": {
    "actual_handle_before_us": 2000000,
    "actual_handle_after_us": 2000000,
    "synthetic_handle_before_us": 0,
    "synthetic_handle_after_us": 0,
    "handle_before_status": "full",
    "handle_after_status": "full",
    "synthetic_handle_before_status": "not_needed",
    "synthetic_handle_after_status": "not_needed"
  },
  "video": {
    "source_is_dolby": true,
    "hdr_dolby_validation": "passed",
    "source_video_signature": {},
    "output_video_signature": {}
  },
  "overlays": [
    {
      "type": "age_overlay",
      "mode": "persistent",
      "text": "6 Years Old",
      "style_id": "age_lower_right"
    },
    {
      "type": "question_overlay",
      "mode": "persistent",
      "enabled": false,
      "text": "What is your name?",
      "style_id": "question_top_left_subtle"
    }
  ],
  "audio": {
    "loudness_match": true,
    "target_lufs": -16.0,
    "true_peak_ceiling_dbtp": -1.0
  },
  "confidence": {
    "level": "high",
    "reasons": []
  },
  "issues": []
}
```

### Closing Card

```json
{
  "node_id": "closing-001",
  "type": "closing_card",
  "text": {
    "title": "The End",
    "subtitle": ""
  },
  "template": {
    "template_id": "closing_minimal",
    "duration_seconds": 2.0,
    "duration_source": "template_default"
  }
}
```

---

## Boundary Transition Object

Boundary transitions should be explicit, not implicit.

```json
{
  "boundary_id": "boundary-answer-age-5-to-age-6",
  "from_node_id": "answer-what-is-your-name-age-5",
  "to_node_id": "answer-what-is-your-name-age-6",
  "boundary_type": "answer_to_answer",
  "requested": {
    "style": "soft_crossfade",
    "duration_frames": 12,
    "duration_us": 200000
  },
  "resolved": {
    "style": "soft_crossfade",
    "duration_frames": 12,
    "method": "real_handles",
    "fallback_used": false
  },
  "requirements": {
    "outgoing_handle_after_required_us": 200000,
    "incoming_handle_before_required_us": 200000
  },
  "availability": {
    "outgoing_real_handle_after_us": 2000000,
    "incoming_real_handle_before_us": 2000000,
    "outgoing_synthetic_available": false,
    "incoming_synthetic_available": false
  },
  "issues": []
}
```

Fallback example:

```json
{
  "boundary_id": "boundary-answer-age-8-to-age-9",
  "from_node_id": "answer-what-is-your-name-age-8",
  "to_node_id": "answer-what-is-your-name-age-9",
  "boundary_type": "answer_to_answer",
  "requested": {
    "style": "soft_crossfade",
    "duration_frames": 12,
    "duration_us": 200000
  },
  "resolved": {
    "style": "clean_cut",
    "duration_frames": 0,
    "method": "fallback_clean_cut",
    "fallback_used": true
  },
  "issues": [
    {
      "severity": "warning",
      "code": "TRANSITION_FALLBACK_CLEAN_CUT",
      "human_message": "Soft crossfade was requested, but this boundary will use a clean cut because safe handle synthesis is not available.",
      "ai_context": {
        "from_node_id": "answer-what-is-your-name-age-8",
        "to_node_id": "answer-what-is-your-name-age-9",
        "requested_duration_frames": 12,
        "fallback": "clean_cut"
      }
    }
  ]
}
```

---

## Issue Object

Every issue must be both human-readable and AI-readable.

```json
{
  "severity": "blocker",
  "code": "MISSING_MEDIA_FILE",
  "human_message": "Cannot export: the clip for 'What is your name?' at Age 6 could not be found.",
  "ai_context": {
    "question_key": "what-is-your-name",
    "age_key": "age-6",
    "expected_path": "/path/to/file.mov",
    "manifest_output_file": "Ellie - What is Your Name/Ellie-What-is-Your-Name-6-Years-Old.mov"
  },
  "suggested_fix": "Confirm the export folder is selected correctly or regenerate the missing clip."
}
```

Allowed severities:
- `blocker`
- `warning`
- `info`

---

## Summary Object

```json
{
  "question_count": 18,
  "answer_clip_count": 126,
  "estimated_runtime_seconds": 950.5,
  "blocker_count": 0,
  "warning_count": 4,
  "info_count": 12,
  "confidence_counts": {
    "high": 118,
    "medium": 8,
    "low": 0
  },
  "transition_counts": {
    "real_handle_crossfade": 110,
    "synthetic_crossfade": 8,
    "clean_cut_fallback": 7
  },
  "export_allowed": true
}
```

---

## Render Plan Builder Rules

1. Start with opening card.
2. For each ordered question:
   - insert question card
   - insert answer clips sorted by `age_sort_key`
3. Add closing card.
4. Generate boundary transition objects for each adjacent pair.
5. Evaluate handles and transition fallbacks.
6. Add overlays to answer clips based on project settings.
7. Evaluate confidence per answer clip and per transition boundary.
8. Add info items for missing ages.
9. Add warnings/blockers as needed.
10. Compute summary.

---

## Initial Validation Rules

### Manifest-level Blockers

- file is not valid JSON
- top-level structure is not an array
- required fields missing from usable rows
- no usable clips found

### Clip-level Blockers

- resolved media path missing
- media unreadable
- `hdr_dolby_validation` failed for HDR/Dolby source
- answer timing missing or invalid

### Render-level Blockers

- export destination unwritable
- required FFmpeg capabilities missing
- impossible filter/render graph

---

## Notes for Codex

Implement this schema in typed Swift models, but keep JSON export/import available for debugging.

The first implementation should be able to:
- read a manifest
- produce a render plan JSON file
- produce issue objects
- produce a text summary

Rendering should come later.
