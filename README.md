# nsx-terrafrom

Terraform for **NSX across a multi-VCF estate** — one Global Manager owning the
federated distributed firewall, 10+ Local Managers owning their own networking,
and every day-to-day change made as reviewed data rather than as an HCL edit or
a click in the NSX UI.

This repository is the **generator and the design**. `scripts/bootstrap.sh`
writes the working tree — modules, stacks, schemas, tooling, CI and worked
example data — into whatever directory you point it at.

```bash
./scripts/bootstrap.sh --dir ~/work/nsx     # scaffold a working tree
cd ~/work/nsx && make validate              # offline checks, no credentials
```

`docs/SETUP.md` walks the whole thing, including the choices you have to make.

> The repository name contains a typo for "terraform". It is reproduced verbatim
> in remotes and CI config; renaming is the owner's call.

## What problem it solves

In an estate of this size the firewall is edited daily, by several people,
across more than ten managers. Doing that through the NSX UI gives you no
review, no history, and no way to answer *why does this rule exist*. Doing it as
hand-written HCL gives you review, but a rule change becomes a code change and
the blast radius of a mistake is a live datacenter.

So rules are **data**:

```yaml
# data/policies/payments.yaml
rules:
  allow-web-to-app:
    sequence_number: 300
    source_groups: [prod-payments-web]
    destination_groups: [prod-payments-app]
    services: [https]
    scope: [prod-payments-app]     # mandatory: bounds where the rule is pushed
    action: ALLOW
```

and nobody writes even that by hand:

```bash
make add-rule POLICY=prod-payments RULE=allow-web-to-app \
  ARGS='--source prod-payments-web --destination prod-payments-app --service https --scope prod-payments-app'
make validate
make plan STACK=global-security SITE=gm1
```

Group membership comes from tags, so it follows the workload instead of being
maintained by hand. Tagging is automated too — either from your provisioning
system or from this repository — so **no part of the daily loop needs the NSX
UI**. That choice is `docs/TAGGING.md`.

## What the generator produces

| | |
|---|---|
| **7 modules** | `dfw-policy`, `group`, `service`, `segment`, `vm-tags`, `tier1`, `tier0`. `for_each` over stable keys, never `count`. |
| **5 stacks** | `global-security`, `local-security`, `local-tags`, `local-network`, `platform`. One state boundary each, instantiated once per manager. |
| **Schemas** | JSON Schema for every data file, plus the tag scope vocabulary. Enforced in CI. |
| **Tooling** | Validation, CI matrix, credential handling, estate import, rule and tag editing, drift reporting. |
| **CI** | Validate on every PR; plan per site from a matrix derived from the inventory. |

It is self-contained: no network, no package install, and no dependency on this
repository once generated. It copies itself and `docs/ARCHITECTURE.md` into the
tree it creates, so that tree can regenerate and update itself.

It is also idempotent and non-destructive. `--force` refreshes only the
generator's own output; estate data needs `--force-data`, and anything recorded
as imported from a live manager is never overwritten by any flag.

## Why the state is split five ways

By **change cadence and blast radius**, not topology — a daily rule edit must
never force Terraform to refresh transport zones.

| Stack | Runs on | Cadence | Blast radius | Approver |
|---|---|---|---|---|
| `global-security` | GM | daily | all sites | security review |
| `local-security` | each LM | weekly | one site | site owner |
| `local-tags` | each LM | daily | the VMs listed | site owner |
| `local-network` | each LM | weekly | one site | network owner |
| `platform` | each LM | rarely | one site, total | change advisory |

Adding an eleventh Local Manager is a data change in `inventory/managers.yaml`,
not a code change: CI derives its run matrix from there.

## Repository contents

| Path | What it is |
|---|---|
| `scripts/bootstrap.sh` | The generator. Every file it writes is embedded in it. |
| `docs/ARCHITECTURE.md` | The design, the conventions, and the operating rules. Copied into every generated tree. |
| `docs/SETUP.md` | How to stand up your own, and the variants on offer. |
| `LICENSE` | Apache-2.0. |

`docs/IMPORT.md`, `docs/STRUCTURE.md` and `docs/TAGGING.md` are referenced from
`docs/ARCHITECTURE.md` but are written by the generator — you will find them in
the tree it creates, not here.

## Status — read before acting

**The scaffold exists and has never touched a live manager.** What has been
verified, offline:

- `terraform fmt -check` clean; all five stacks pass `terraform validate`
  against the real `vmware/nsxt` provider (3.12.0, resolved from `~> 3.9`).
- Data wiring evaluated with `terraform console`; group and policy filtering by
  owner and site confirmed.
- `scripts/validate-data.py` passes on the example data and was tested against
  deliberately planted defects.
- The generator reproduces itself byte-for-byte.

What that does **not** cover:

- **No `terraform plan` has run against an NSX manager.** Provider schema
  validity is not API validity.
- **The state backend is a placeholder** `backend "local"`. It is not acceptable
  for a real manager, and `scripts/tf.sh` refuses to apply through it.
- **All example data describes no real site.** Replace it, or generate with
  `--no-examples`.

`docs/ARCHITECTURE.md` section 14 lists every decision deliberately left to the
owner. Section 2 — ten things that will break this repository — is worth reading
before the first change.
