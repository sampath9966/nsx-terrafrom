# Setting up your own

`scripts/bootstrap.sh` writes a complete NSX Terraform repository into whatever
directory you point it at. This document covers the run, the decisions it
deliberately leaves to you, and the variants it supports.

Nothing here touches a live NSX manager. Everything up to "First contact with a
manager" is offline.

---

## 0. What you need

```bash
bash          # 4.x or later
coreutils
python3       # 3.9+. PyYAML optional — there is a fallback parser.
terraform     # 1.9+
git
```

`make preflight` in the generated tree reports what is missing. The generator
itself needs only bash and coreutils: no network, no package install, no access
back to this repository.

---

## 1. Generate

```bash
git clone https://github.com/sampath9966/nsx-terrafrom
./nsx-terrafrom/scripts/bootstrap.sh --dir ~/work/nsx-estate
cd ~/work/nsx-estate
```

Look before you leap:

```bash
./scripts/bootstrap.sh --dry-run     # report every file, write nothing
```

### Where it goes — three shapes

| You want | Do this |
|---|---|
| A fresh repository of your own | `--dir ~/work/nsx-estate --git-init`, then push it to your own remote. **The usual choice.** |
| To build on top of this one | Run it in place, in a clone: `./scripts/bootstrap.sh`. Generator and generated tree share a history. |
| To evaluate first | `--dir /tmp/try --dry-run`, then without `--dry-run`. Throw it away after. |

The generator copies itself and `docs/ARCHITECTURE.md` into the tree it creates,
so the result is standalone: it can regenerate and update itself with no link
back to here.

### With or without the worked example

The default ships realistic example content — 4 managers, 10 groups, 4 policy
files, a site's network and platform, 2 tagged VMs — describing **no real
site**. It exists so `make validate` and `terraform validate` have something to
chew on, and so you can see the intended shape of each file.

```bash
./scripts/bootstrap.sh --dir PATH                  # with examples (recommended first time)
./scripts/bootstrap.sh --dir PATH --no-examples    # structure and tooling only
```

With examples, replace `inventory/managers.yaml` and everything under `data/`
before you go near a manager. The example inventory uses `gm1`, `lon1`, `nyc1`,
`fra1` — if any of those happen to be your real site ids, be especially careful.

### Re-running it later

Safe, and the intended way to take generator updates:

```bash
./scripts/bootstrap.sh              # unchanged files untouched, edited files kept (exit 2)
./scripts/bootstrap.sh --force      # refresh the generator's own output
./scripts/bootstrap.sh --force-data # ALSO overwrite data/, inventory/, envs/
```

It never deletes. `--force` refreshes modules, stacks, scripts, schemas, CI and
docs, and cannot touch `data/`, `inventory/` or `envs/`. `--force-data` can, but
still **refuses outright** for anything recorded in `data/.import-manifest.json`
— adopted estate is never overwritten by this script, by any flag.

---

## 2. The decisions that are yours

The generator refuses to guess these. They are listed in
`docs/ARCHITECTURE.md` section 14; three block a real apply.

### 2.1 State backend — blocking

`stacks/*/backend.tf` ships a placeholder `backend "local" {}` so the stacks
initialise for offline validation. **It is not acceptable for a real manager**:
state carries the full security posture of the estate and needs encryption at
rest, locking, and access limited to the pipeline identity.

Replace the block in each stack and fill in `envs/<site>.backend.hcl`. For S3:

```hcl
# stacks/*/backend.tf
terraform {
  backend "s3" {}
}
```

```hcl
# envs/lon1.backend.hcl
bucket         = "nsx-tfstate-prod"
key            = "lon1/local-security.tfstate"
region         = "eu-west-1"
dynamodb_table = "nsx-tfstate-lock"
kms_key_id     = "arn:aws:kms:eu-west-1:...:key/..."
encrypt        = true
```

One state per stack per manager. `scripts/tf.sh` refuses to apply through a
local backend unless `ALLOW_LOCAL_STATE=1` is set explicitly.

### 2.2 Credentials — blocking

Credentials never live in this repository, and never pass through a Terraform
data source: the `vault_*` data sources write the fetched secret into state in
plaintext.

`scripts/with-credentials.sh` fetches outside Terraform and execs with `NSXT_*`
in the environment. It assumes Vault KV v2 at the path recorded per manager in
`inventory/managers.yaml`; the mount convention and auth method are yours to
set. `vault_path` records **where the credential lives, never the credential**.

### 2.3 Who tags the workloads — decide before writing group criteria

Group membership resolves from tags, so this decides whether a membership change
is reviewable. Two supported variants, covered in full in `docs/TAGGING.md`:

| | Variant A — *default* | Variant B |
|---|---|---|
| Who writes NSX tags | VCF/vRA automation, CMDB, provisioning | this repository |
| Where it is declared | that system | `data/vm-tags/<site>.yaml` |
| Applied by | that system | `stacks/local-tags` |
| Suits | the estate | bounded exception sets |
| Ceiling | none | a few hundred VMs |

**Neither variant requires the NSX UI.** The question is which system is the
source of truth.

Pick **A** if anything else already writes NSX tags — VCF automation, vSphere
tag sync, a CMDB. Any one of those is decisive: `nsxt_policy_vm_tags` replaces a
VM's *entire* tag set, so two writers overwrite each other forever.

Pick **B** for VMs nothing else tags — hand-built servers, appliances, workloads
not onboarded to a CMDB, and quarantine:

```bash
make tag-vm SITE=lon1 VM=payments-web-01 ARGS='--set workload=payments-web'
make validate
make plan STACK=local-tags SITE=lon1
```

Mixing is per **VM**, never per tag. The boundary is enforced: every scope in
`data/schema/tag-scopes.yaml` records its owning system, and `make validate`
errors if `data/vm-tags/` writes a scope not owned by `terraform`.

### 2.4 The rest

| Decision | Default taken | Revisit when |
|---|---|---|
| Terragrunt vs CI matrix | CI matrix over `inventory/managers.yaml` | the matrix demonstrably hurts |
| GM owns the Application category, or delegated per site | GM owns it | site teams need independent app policy |
| One federation or several | one — `global-security` is a single state | a second GM appears; it becomes one state per federation |
| Import scope and pilot site | none chosen | before the first adoption tranche |

---

## 3. Describe your estate

Everything derives from one file.

```yaml
# inventory/managers.yaml
managers:
  gm1:
    role: gm
    host: gm1.nsx.example.com
    site: global
    vcf_instance: vcf-lon
    vault_path: secret/nsx/gm1      # a path. Never a secret.
    tier: prod
  lon1:
    role: lm
    host: lon1-nsx.example.com
    site: lon1
    vcf_instance: vcf-lon
    vault_path: secret/nsx/lon1
    tier: prod
```

Then one `envs/<site>.backend.hcl` per manager — the filename must match the
manager key, which is how `scripts/tf.sh` finds it.

```bash
make validate     # schemas + conventions, offline
make matrix       # exactly what CI will run
```

Adding an eleventh Local Manager later is these two files and nothing else.

---

## 4. Greenfield or brownfield

### Greenfield — no NSX objects exist yet

Write data files and plan. Start with one site and one application; expand once
a plan has been reviewed against a real manager.

### Brownfield — adopt what is already there

The common case, and the one to take slowly. `docs/IMPORT.md` in the generated
tree is the full walkthrough.

```bash
# 1. capture, read-only (reports/ is gitignored)
scripts/with-credentials.sh lon1 -- scripts/import-estate.py --site lon1 --dump-only reports/lon1-raw.json

# 2. convert offline, iterating as often as you like
scripts/import-estate.py --site lon1 --from-dump reports/lon1-raw.json

# 3. verify, then import one tranche
make plan STACK=local-security SITE=lon1
```

Two rules that matter more than the rest:

- **A tranche is done when `plan` reports *no changes*.** Not "only small
  changes".
- **A *create* in an import plan means stop.** Terraform is about to build a
  duplicate beside the object you meant to adopt — almost always an `nsx_id`
  that does not match. Imported objects keep their real id verbatim, mixed case
  and underscores included.

Imported files are recorded in `data/.import-manifest.json` and are never
overwritten by the generator, by any flag. Re-running the importer writes a
`.new` sidecar rather than clobbering your edits.

---

## 5. First contact with a manager

Everything above is offline. From here a mistake reaches a live firewall.

```bash
make preflight
make validate
scripts/with-credentials.sh lon1 -- scripts/tf.sh init local-security lon1
scripts/with-credentials.sh lon1 -- scripts/tf.sh plan local-security lon1
scripts/tf.sh show local-security lon1        # review the rendered plan
```

Commit the `.terraform.lock.hcl` from that first `init`. An unpinned provider
across 10+ managers means different sites realize different behaviour.

Review the plan against the checklist in `.github/pull_request_template.md`. The
two that catch real damage:

- **No unexpected destroys.** A destroy on a rule you did not touch means map
  keys shifted — stop and find out why.
- **The resource count delta matches the intent.**

Then, and only then:

```bash
APPROVE=yes scripts/tf.sh apply local-security lon1
```

`apply` requires a saved plan and an explicit `APPROVE=yes`. There is no path
that plans and applies in one step, deliberately.

### Suggested order

1. `local-security` at one non-production site — smallest blast radius.
2. `local-tags` at the same site, if you chose variant B.
3. `local-network` at that site.
4. `global-security` — every site at once. Do this last, and with the security
   reviewer present.
5. `platform` only under change advisory.

---

## 6. Daily use, once it is running

```bash
make add-rule POLICY=prod-payments RULE=allow-web-to-app \
  ARGS='--source prod-payments-web --destination prod-payments-app --service https --scope prod-payments-app'
make tag-vm SITE=lon1 VM=payments-web-01 ARGS='--set workload=payments-web'
make validate
```

Open a pull request. CI validates and posts a plan per site. A human approves;
the pipeline applies.

`make drift STACK=local-security SITE=lon1` reports what changed outside
Terraform. It writes a report and never reverts anything and never writes
`data/` — drift is a ticket for a person, not something to auto-fix.

---

## 7. If something is wrong

| Symptom | Cause |
|---|---|
| `make validate` errors on a tag scope | The scope is not in `data/schema/tag-scopes.yaml`, or `data/vm-tags/` is writing a scope another system owns. `docs/TAGGING.md`. |
| Plan shows a *create* during an import | The `nsx_id` does not match the live object. **Stop** — do not apply. |
| Plan destroys rules you did not touch | Map keys shifted. Never `count` for rules; check what renamed. |
| `apply` refuses | No saved plan, no `APPROVE=yes`, or the local backend is still in place. All three are deliberate. |
| Generator reports "kept" and exits 2 | You edited a generated file. Take the update with `--force`, or keep your edit. |
| Group is empty and traffic drops | A tag scope was renamed. That is a restricted change and needs proof that no criteria reference it. |

`docs/ARCHITECTURE.md` section 2 lists the ten failure modes worth internalising
before the first change.
