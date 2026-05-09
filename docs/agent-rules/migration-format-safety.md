# Migration and Format Safety Rules

Read when the task touches data migrations, format conversions, irreversible transformations, or stored-data compatibility.

- One-way or irreversible migrations require Ask-First approval unless already approved by the project.
- Explain rollback impact, compatibility impact, and whether migration is in-place or copy-forward.
- Prefer reversible or copy-forward migration paths where practical.