# Diagnostics and Privacy Rules

Read when the task touches diagnostics, logging, crash handling, persistent logs, redaction, or user-sensitive debug output.

- Persistent logs should be local, minimal, redacted, and opt-in unless explicitly approved otherwise.
- Do not expose filenames, paths, identifiers, metadata, or user data unless necessary for diagnosis.
- Never commit sensitive logs, crash artifacts, or sample user data without approval.