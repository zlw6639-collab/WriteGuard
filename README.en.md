# WriteGuard — five rules for scripts that modify files

**One line**: if your script edits files **on someone else's behalf**, don't hand-write backup / verify / rollback
in every branch — hand it to this guardrail.

> **Note on language**: this is a **brief** (English). The full docs are in Chinese:
> [`README.md`](README.md) (complete) and [`检查器自证清单.md`](检查器自证清单.md) (the methodology).

## The five rules

| # | Rule | Where it lives |
|---|---|---|
| ① | **Off by default** — no explicit `-Commit` ⇒ nothing is written | `Invoke-WgWrite` returns `DryRun` |
| ② | **Byte-exact backup** — read the original bytes before writing, verify the backup by re-reading it | `Backup-WgSnapshot` |
| ③ | **Whitelist-only edits** — exactly one match, or refuse (0 or 2+ matches never "pick the first") | `Set-WgUniqueSpan` / `Set-WgJsonScalar` + `-MaxChangedLines` |
| ④ | **Read-back verification** — re-read from disk, compare text + BOM, then run *your* assertions (a throwing assertion counts as failure) | `Invoke-WgWrite -Verify` |
| ⑤ | **Automatic rollback** — restore from backup on failed verification, **but only after checking the file is still the one we wrote**; a third party's edit ⇒ `RollbackRefused` (never overwrite it); a failed *rollback* is reported separately | `Restore-WgSnapshot` |

Plus two habits paid for in blood: **"couldn't compute" ≠ "no problem"**, and **diff/cleanup loops must be able to report failure**.

## What makes it different

- **Visible** — every planned change comes with a diff preview (even in dry-run). No blind writes.
- **Auditable** — `-Audit` writes a JSONL line per operation (operation id, time, status, file, SHA256 before **and after**, recovery outcome, changed lines, backup, verification result).
- **Atomic across files** — `Invoke-WgBatch`: either all files are written, or the ones already written are rolled back.
- **Meta-verified** — `tests/MutationCheck.ps1` deliberately breaks the library along each rule and requires the
  self-test to go red (13 scenarios: 12 injections caught + 1 noise case that must stay green).
  *"The check passed" ≠ "the check works."*

## Quick start

```powershell
Import-Module ./WriteGuard.psm1

# dry-run: shows what would change, writes nothing
$r = Invoke-WgWrite -Path ./config.json -Mutator {
        param($s) Set-WgJsonScalar -Text $s.Text -Field 'version' -Value '2.1.0'
      }
$r.Status      # DryRun
$r.DiffText    # preview

# commit: backup → write → read back → verify → rollback on failure
$r = Invoke-WgWrite -Path ./config.json -Commit -Audit -Mutator { ... } -Verify { ... }
```

Command line (no code needed):

```powershell
pwsh -NoProfile -File ./wg.ps1 json    -File ./config.json -Field version -Value 2.1.0   # dry-run
pwsh -NoProfile -File ./wg.ps1 replace -File ./doc.md -Pattern 'old' -Replacement 'new' -Commit
pwsh -NoProfile -File ./wg.ps1 check   -File ./doc.md -Pattern '^## '
pwsh -NoProfile -File ./wg.ps1 audit   -File ./.writeguard/audit.jsonl
```

## Verify it yourself (don't trust me)

```powershell
pwsh -NoProfile -File ./tests/SelfTest.ps1        # expect: PASS 57 / FAIL 0, exit 0
pwsh -NoProfile -File ./tests/MutationCheck.ps1   # expect: OK 30 / 0,         exit 0
pwsh -NoProfile -File ./examples/minimal-checker/run-demo.ps1   # a 40-line checker + 3 injections
pwsh -NoProfile -File ./Start-Here.ps1            # runs the above and lists what's left to do
```

## Requirements & scope

- **PowerShell 7+** only. No third-party modules, no network, no external commands (just `pwsh`).
- **Text files only** (binary: use `Backup-WgSnapshot` / `Restore-WgSnapshot` directly).
- **It is not a sandbox-bypass tool**; it is not version control. TOCTOU is **narrowed, not eliminated**:
  the hash is re-checked *before* writing (so we refuse to clobber someone else's edit) and again *before*
  rolling back (if a third party changed the file meanwhile ⇒ `RollbackRefused`, we do **not** overwrite it).
- The diff / changed-line algorithm is deliberately **conservative**: it never under-reports, and may over-report —
  over-reporting means "refuse to write", not "corrupt the file".

MIT licensed. See [`LICENSE`](LICENSE).
