# NSX Terraform architecture

Architecture, conventions, and operating rules for this repository.

## Current state of this repository — read this first

**This repository is empty.** As of the latest commit it contains exactly two files:

```
LICENSE      Apache License 2.0
docs/ARCHITECTURE.md    this file
```

There is no Terraform code, no modules, no CI configuration, no tests, and no
build tooling yet. The GitHub repository has no description and no topics.

What this means in practice:

- **Do not assume a layout exists.** Everything under "Intended conventions"
  below is a proposal for when code lands, not a description of code that is
  already here. Verify with `ls` before referring to any path.
- **Do not fabricate commands.** There is currently no `make`, no `npm`, no CI
  workflow, and no wrapper script. If asked how to build or test, say that no
  tooling exists yet rather than inventing a command.
- **Keep this file honest.** The first change that adds real code should also
  replace the speculative sections here with what was actually built. Prune
  anything that turned out not to apply — a stale docs/ARCHITECTURE.md is worse than a
  short one.

### About the repository name

The repository is named `nsx-terrafrom` — "terrafrom" is a typo for
"terraform". Reproduce the name verbatim in clone URLs, remotes, and CI
config; do not silently "correct" it. Renaming the repository is the owner's
call, not something to fix in passing.

## What this repository is for

Based on the name, this is intended to hold Terraform configuration for
**VMware NSX** (NSX-T / NSX policy API) infrastructure. Nothing in the commit
history confirms a narrower scope than that — confirm with the owner before
building on an assumption about which NSX deployment, environment count, or
state backend is targeted.

## Intended conventions (apply once code exists)

### Provider

Use the official provider, `vmware/nsxt`, from the Terraform Registry. Pin it:

```hcl
terraform {
  required_version = ">= 1.5"
  required_providers {
    nsxt = {
      source  = "vmware/nsxt"
      version = "~> 3.4"
    }
  }
}
```

Prefer the **policy** resources (`nsxt_policy_*`) over the older imperative
manager resources (`nsxt_logical_switch`, `nsxt_firewall_section`, …). The
policy API is the declarative surface NSX-T is built around and is what VMware
recommends for new work. Common ones: `nsxt_policy_tier0_gateway`,
`nsxt_policy_tier1_gateway`, `nsxt_policy_segment`, `nsxt_policy_group`,
`nsxt_policy_security_policy`, `nsxt_policy_nat_rule`, `nsxt_policy_vm_tags`.

### Credentials — never commit them

NSX manager credentials are configured through environment variables, never
in `.tf` files and never in committed `.tfvars`:

```
NSXT_MANAGER_HOST
NSXT_USERNAME
NSXT_PASSWORD
```

Rules that apply without exception:

- Never write a password, API token, or certificate into a tracked file.
- Never commit `*.tfstate` or `*.tfstate.backup` — state contains secrets in
  plaintext. Add a `.gitignore` covering `.terraform/`, `*.tfstate*`,
  `*.tfvars` (except `*.example.tfvars`), and `.terraform.lock.hcl` only if the
  team decides not to pin (usually it **should** be committed).
- `NSXT_ALLOW_UNVERIFIED_SSL=true` is acceptable in a lab, but do not set
  `allow_unverified_ssl = true` in committed configuration for anything that
  looks like production.

### Suggested layout

Nothing here exists yet; adopt it when the first real config is written.

```
modules/            reusable modules (segment, tier1, security-policy, …)
environments/       one directory per environment, each with its own backend
  dev/
  prod/
examples/           runnable examples for each module
```

Each module gets `main.tf`, `variables.tf`, `outputs.tf`, and a `README.md`
describing inputs and outputs. Give every variable a `description` and a
`type`; give defaults only where a sane default genuinely exists.

### Naming

Use `snake_case` for resource, variable, and output names. Name resources for
their role, not their type — `nsxt_policy_segment.app_tier`, not
`nsxt_policy_segment.segment_1`. Use `this` for a module's single primary
resource.

## Workflow

Standard Terraform flow, once configuration exists:

```bash
terraform init
terraform fmt -recursive     # run before every commit
terraform validate
terraform plan -out=tfplan
terraform apply tfplan
```

- **Always run `terraform fmt -recursive` and `terraform validate`** before
  committing. These are the only checks available until CI exists.
- **Never run `terraform apply` against real infrastructure on your own
  initiative.** NSX changes affect live networking and firewall policy. Produce
  a plan, show it, and let a human decide. The same goes for `terraform
  destroy` and for `terraform state rm` / `state mv`, which can orphan real
  objects.
- `terraform plan` needs live credentials and reachability to the NSX manager.
  In a sandboxed session it will usually fail to connect — that is expected,
  not a bug to work around by disabling TLS verification.

## Git conventions

- Development happens on feature branches; `main` is the default branch.
- Write imperative commit subjects: "Add tier-1 gateway module", not "Added…".
- Open pull requests as drafts until the change is ready for review.
- There is no PR template and no CODEOWNERS file in the repository.

## When you add tooling

If you introduce CI, a linter (`tflint`), a security scanner (`tfsec` /
`checkov`), or a `Makefile`, document the exact invocation in this file in the
same commit. The value of this file is that every command in it is one someone
has actually run.
