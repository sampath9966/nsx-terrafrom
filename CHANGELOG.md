# Changelog

What changed between versions of the generator, and what it means for a
repository already generated from an older one.

An update replaces the generator's own output — `modules/`, `stacks/`,
`scripts/`, schemas, CI and docs. It never touches `data/`, `inventory/` or
`envs/`. So "breaking" here does not mean your files are edited; it means a
module or schema changed in a way that alters what your existing data does, and
you should read the plan carefully.

Take an update with `scripts/update.sh`, which shows this file and a dry-run
diff before changing anything.

## 1.1.0

Interactive, GitOps-capable, and safe to re-run.

**New**

- Menu-driven `bootstrap.sh`: basic, advanced, update, add version control.
- A review pipeline for GitLab and GitHub — a rule edit becomes a merge request
  with a plan on it, approved, then applied from the saved plan.
- `scripts/gitlab-setup.sh` and `scripts/gitlab-up.sh`: create and configure a
  GitLab project, or stand one up in Docker.
- VM tagging from Terraform for estates where nothing else tags:
  `modules/vm-tags`, `stacks/local-tags`, `data/vm-tags/`, `scripts/tag-vm.py`.
- State backend as a flag: `--backend gitlab|s3|azure|local`.
- `make selftest`, `make ready`, `scripts/update.sh`.
- `docs/GITOPS.md`, `docs/ACCEPTANCE.md`, `docs/TAGGING.md`, `docs/SETUP.md`.

**Changed — read before updating**

- **Overwriting now requires a typed phrase** as well as `--force`. Scripted
  callers must pass `--confirm 'wipe everything & start fresh'` or set
  `BOOTSTRAP_CONFIRM`, otherwise a `--force` run in CI aborts rather than
  overwriting. This is the one change that can break an existing automation.
- Which CI files are written now follows the version-control choice rather than
  always writing both. The choice is recorded in `.nsx-bootstrap.conf`; a tree
  updated from 1.0.x keeps whatever it already has and gains nothing it did not
  ask for.
- Without `--dir`, the target is the root of the repository you are inside, not
  the current directory. A script that relied on `cd somewhere && bootstrap.sh`
  scaffolding into `somewhere` will now target the enclosing repository if there
  is one.
- `LM_STACKS` gained `local-tags`, so CI runs one more job per Local Manager.

**Not breaking**

- `data/`, `inventory/` and `envs/` are untouched, as always.
- Existing module inputs are unchanged; nothing in `data/` needs editing.

## 1.0.0

First self-contained generator: modules, stacks, schemas, the data validator,
the CI matrix, credential handling and estate import.
