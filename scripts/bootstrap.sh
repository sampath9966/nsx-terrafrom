#!/usr/bin/env bash
#
# bootstrap.sh — scaffold the NSX/VCF Terraform repository described in docs/ARCHITECTURE.md.
#
# The script is self-contained: every file it writes is embedded here. It has no
# dependency on the repository it came from, on the network, or on any tool
# beyond bash, coreutils and (for the generated validator) python3. Run it in an
# empty directory, in an existing repository, or anywhere else — it scaffolds
# relative to the target directory, never to a hardcoded path.
#
#   ./scripts/bootstrap.sh                 # scaffold into the current directory
#   ./scripts/bootstrap.sh --dir ~/work/x  # scaffold into another directory
#   ./scripts/bootstrap.sh --dry-run       # show what would happen, write nothing
#   ./scripts/bootstrap.sh --force         # overwrite files that already differ
#
# It is idempotent: an unchanged file is left alone, an existing file that
# differs is kept and reported unless --force is given. Nothing is ever deleted.

set -euo pipefail

VERSION="1.0.0"

ROOT="$PWD"
FORCE=0
DRY_RUN=0
QUIET=0
WITH_EXAMPLES=1
WITH_GIT=0

created=0
updated=0
unchanged=0
skipped=0
EXECUTABLES=""

usage() {
	cat <<'USAGE'
bootstrap.sh — scaffold the NSX/VCF Terraform repository layout.

Usage: bootstrap.sh [options]

Options:
  -d, --dir PATH      Target directory (default: current working directory).
                      Created if it does not exist.
  -f, --force         Overwrite existing files whose content differs.
      --no-examples   Skip the example data files (inventory entry, groups,
                      policies, services, network and platform data). The
                      structure, modules, stacks, schemas and tooling are
                      still written.
      --git-init      Run 'git init' in the target directory if it is not
                      already inside a git working tree.
  -n, --dry-run       Report what would be written; change nothing.
  -q, --quiet         Only print the summary and any warnings.
  -h, --help          Show this help.
      --version       Print the bootstrap script version.

Exit status is 0 on success, 1 on error, 2 if files were skipped because they
already exist with different content (re-run with --force to overwrite).
USAGE
}

log() { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

while [ $# -gt 0 ]; do
	case "$1" in
	-d | --dir)
		[ $# -ge 2 ] || die "--dir requires a path"
		ROOT="$2"
		shift 2
		;;
	--dir=*)
		ROOT="${1#*=}"
		shift
		;;
	-f | --force)
		FORCE=1
		shift
		;;
	--no-examples)
		WITH_EXAMPLES=0
		shift
		;;
	--git-init)
		WITH_GIT=1
		shift
		;;
	-n | --dry-run)
		DRY_RUN=1
		shift
		;;
	-q | --quiet)
		QUIET=1
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	--version)
		printf 'bootstrap.sh %s\n' "$VERSION"
		exit 0
		;;
	*) die "unknown option: $1 (try --help)" ;;
	esac
done

if [ ! -d "$ROOT" ]; then
	if [ "$DRY_RUN" = 1 ]; then
		log "would create directory $ROOT"
	else
		mkdir -p "$ROOT" || die "cannot create $ROOT"
	fi
fi
[ "$DRY_RUN" = 1 ] || ROOT="$(cd "$ROOT" && pwd)"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/nsx-bootstrap.XXXXXX")"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

# write_file <relative-path> — content is read from stdin.
write_file() {
	local rel="$1"
	local dest="$ROOT/$rel"
	local tmp="$STAGE/staged"

	cat >"$tmp"

	if [ -e "$dest" ]; then
		if [ "$DRY_RUN" = 1 ]; then
			# cmp against the real file even in dry-run: it is read-only.
			if cmp -s "$tmp" "$dest"; then
				log "  ok       $rel"
				unchanged=$((unchanged + 1))
			elif [ "$FORCE" = 1 ]; then
				log "  would overwrite $rel"
				updated=$((updated + 1))
			else
				warn "exists with different content, kept: $rel (use --force to overwrite)"
				skipped=$((skipped + 1))
			fi
			return 0
		fi
		if cmp -s "$tmp" "$dest"; then
			log "  ok       $rel"
			unchanged=$((unchanged + 1))
		elif [ "$FORCE" = 1 ]; then
			cat "$tmp" >"$dest"
			log "  updated  $rel"
			updated=$((updated + 1))
		else
			warn "exists with different content, kept: $rel (use --force to overwrite)"
			skipped=$((skipped + 1))
			return 0
		fi
	else
		if [ "$DRY_RUN" = 1 ]; then
			log "  would create $rel"
			created=$((created + 1))
			return 0
		fi
		mkdir -p "$(dirname "$dest")"
		cat "$tmp" >"$dest"
		log "  created  $rel"
		created=$((created + 1))
	fi
}

# mark_executable <relative-path> ... — chmod +x applied at the end of the run.
mark_executable() { EXECUTABLES="$EXECUTABLES $*"; }

make_dir() {
	local rel="$1"
	if [ "$DRY_RUN" = 1 ]; then
		[ -d "$ROOT/$rel" ] || log "  would mkdir $rel/"
		return 0
	fi
	mkdir -p "$ROOT/$rel"
}

# A .gitkeep keeps an intentionally empty directory in git.
keep_dir() {
	make_dir "$1"
	write_file "$1/.gitkeep" </dev/null
}

log "nsx-terraform bootstrap $VERSION"
log "target: $ROOT"
[ "$DRY_RUN" = 1 ] && log "(dry run — nothing will be written)"
log ""

# ---------------------------------------------------------------------------
# 1. Directory structure (docs/ARCHITECTURE.md section 4, plus data/network and
#    data/platform for the per-site network and platform stacks).
# ---------------------------------------------------------------------------

log "directories"
for d in \
	inventory \
	data/groups data/policies data/services data/schema data/network data/platform \
	modules/dfw-policy modules/group modules/service modules/segment modules/tier1 modules/tier0 \
	stacks/global-security stacks/local-security stacks/local-network stacks/platform \
	envs scripts docs .github/workflows; do
	make_dir "$d"
done
log ""

log "files"

# ---------------------------------------------------------------------------
# 2. Repository root
# ---------------------------------------------------------------------------

write_file .gitignore <<'SCAFFOLD_EOF'
# Terraform working directories and state. State contains the full security
# posture of the estate — it never lands in git. See docs/ARCHITECTURE.md section 9.
.terraform/
*.tfstate
*.tfstate.*

# Variable files may carry site specifics; examples are committed.
*.tfvars
!*.example.tfvars

# Saved plans are sensitive artifacts, not review attachments.
tfplan
*.tfplan
plan.json
plan.txt

crash.log
crash.*.log
override.tf
override.tf.json
*_override.tf
*_override.tf.json

# Placeholder local backend output. Never a real manager's state.
.local-state/

# Local tool output.
.bin/
__pycache__/
*.pyc
.venv/

# .terraform.lock.hcl IS committed — it is the provider pin, not a secret.
SCAFFOLD_EOF

write_file Makefile <<'SCAFFOLD_EOF'
# Entry points for this repository. Every target here has been run; if you add
# one, document it in docs/ARCHITECTURE.md section 16 in the same commit.
#
# Usage:
#   make help
#   make validate
#   make plan SITE=lon1 STACK=global-security

SHELL := /bin/bash
.DEFAULT_GOAL := help

PYTHON ?= python3
SITE   ?=
STACK  ?=

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

.PHONY: preflight
preflight: ## Check that the tools this repository needs are present
	@scripts/preflight.sh

.PHONY: validate
validate: schema-validate fmt-check ## Run every offline check (no credentials, no network)

.PHONY: schema-validate
schema-validate: ## Validate everything under data/ and inventory/ against the schemas
	@$(PYTHON) scripts/validate-data.py

.PHONY: fmt
fmt: ## Rewrite all Terraform files in canonical format
	@terraform fmt -recursive .

.PHONY: fmt-check
fmt-check: ## Fail if any Terraform file is not canonically formatted
	@terraform fmt -recursive -check -diff .

.PHONY: matrix
matrix: ## Print the CI matrix derived from inventory/managers.yaml
	@$(PYTHON) scripts/ci-matrix.py

.PHONY: init
init: ## terraform init for STACK against SITE
	@scripts/tf.sh init "$(STACK)" "$(SITE)"

.PHONY: plan
plan: ## terraform plan -out=tfplan for STACK against SITE
	@scripts/tf.sh plan "$(STACK)" "$(SITE)"

.PHONY: show
show: ## Render the saved plan for STACK/SITE in human-readable form
	@scripts/tf.sh show "$(STACK)" "$(SITE)"

.PHONY: apply
apply: ## Apply the SAVED plan for STACK/SITE. Requires APPROVE=yes and a human decision.
	@scripts/tf.sh apply "$(STACK)" "$(SITE)"

.PHONY: clean
clean: ## Remove local plan files and python caches (never touches state)
	@find . -name 'tfplan' -o -name '*.tfplan' -o -name 'plan.json' | xargs -r rm -f
	@find . -name '__pycache__' -type d | xargs -r rm -rf
SCAFFOLD_EOF

write_file .editorconfig <<'SCAFFOLD_EOF'
root = true

[*]
charset = utf-8
end_of_line = lf
insert_final_newline = true
trim_trailing_whitespace = true

[*.{tf,tfvars,hcl}]
indent_style = space
indent_size = 2

[*.{yaml,yml,json}]
indent_style = space
indent_size = 2

[*.py]
indent_style = space
indent_size = 4

[Makefile]
indent_style = tab
SCAFFOLD_EOF

write_file docs/STRUCTURE.md <<'SCAFFOLD_EOF'
# Repository structure

Generated by `scripts/bootstrap.sh`. This describes what each directory is for
and, more importantly, what must *not* go in it.

```
inventory/managers.yaml    Single registry of every GM and LM. Adding a manager
                           is a data change here — never a code change.
data/
  groups/                  Group definitions (dynamic criteria and static).
  policies/                DFW policies and their rules, one file per app.
  services/                Reusable service definitions and predefined aliases.
  network/                 Per-site segments and T1 gateways.
  platform/                Per-site T0, transport zones, edge clusters.
  schema/                  JSON Schema + the tag scope vocabulary. Enforced in CI.
modules/
  dfw-policy/              Parent policy + standalone rules, built from data.
  group/                   Groups with tag criteria or static membership.
  service/                 Custom L4/ICMP services.
  segment/                 Segments (Terraform-owned, so segment tags live here).
  tier1/                   T1 gateways.
  tier0/                   T0 gateways.
stacks/
  global-security/         GM: federated DFW. One state for the federation.
  local-security/          Per-LM: site-local DFW exceptions. One state per LM.
  local-network/           Per-LM: segments, T1s. One state per LM.
  platform/                Per-LM: T0, transport zones, edge clusters.
envs/<site>.backend.hcl    Partial backend config, one file per manager.
scripts/                   Bootstrap, validation, CI matrix, credential handling.
.github/workflows/         Validate on every PR; plan per site from the matrix.
```

## Why the split

State boundaries follow change cadence and blast radius, not topology. A daily
DFW rule edit must never force Terraform to refresh transport zones.

| Stack | Cadence | Blast radius | Approver |
|---|---|---|---|
| `global-security` | daily | all sites | security review |
| `local-security` | weekly | one site | site owner |
| `local-network` | weekly | one site | network owner |
| `platform` | rarely | one site, total | change advisory |

## Adding a manager

1. Add an entry to `inventory/managers.yaml`.
2. Add `envs/<id>.backend.hcl` (copy `envs/example.backend.hcl.example`).
3. Nothing else. CI derives its matrix from the inventory.

## Adding a rule

Edit one file under `data/policies/`. No HCL changes. `make validate` then a PR.
SCAFFOLD_EOF

# ---------------------------------------------------------------------------
# 3. Schemas and the tag vocabulary
# ---------------------------------------------------------------------------

write_file data/schema/tag-scopes.yaml <<'SCAFFOLD_EOF'
# Closed vocabulary of NSX tag scopes.
#
# A tag scope is an API contract between whatever system tags workloads and the
# group criteria in this repository. Renaming a scope silently empties every
# group that matches it, which silently drops traffic — that is a RESTRICTED
# change (docs/ARCHITECTURE.md section 11), not a routine one.
#
# Adding a scope is a reviewed change. Removing or renaming one requires proving
# that no group criteria reference it:
#   grep -R "<scope>|" data/groups/
#
# scopes:
#   <scope>:
#     description: what the scope means
#     owner:       the system that authoritatively writes this tag
#     values:      optional closed list; omit for free-form values
#     applies_to:  VirtualMachine | Segment | ... (member types that carry it)

scopes:
  env:
    description: Deployment environment.
    owner: vcf-automation
    applies_to: [VirtualMachine, Segment]
    values: [prod, preprod, nonprod, dev]
  app:
    description: Application identity.
    owner: cmdb-sync
    applies_to: [VirtualMachine, Segment]
  tier:
    description: Role of the workload within its application.
    owner: cmdb-sync
    applies_to: [VirtualMachine]
    values: [web, app, db, mgmt]
  zone:
    description: Trust zone.
    owner: network-team
    applies_to: [VirtualMachine, Segment]
    values: [dmz, internal, restricted]
  owner:
    description: Accountable team.
    owner: cmdb-sync
    applies_to: [VirtualMachine, Segment]
  compliance:
    description: Regulatory scope.
    owner: grc-sync
    applies_to: [VirtualMachine]
    values: [pci, sox, none]
  quarantine:
    description: >
      Incident response. The only scope Terraform itself may write, via the
      Emergency-category mechanism in docs/ARCHITECTURE.md section 11.
    owner: incident-response
    applies_to: [VirtualMachine]
    values: [active]
SCAFFOLD_EOF

write_file data/schema/managers.schema.json <<'SCAFFOLD_EOF'
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://nsx-terraform/schema/managers.json",
  "title": "Manager inventory",
  "type": "object",
  "required": ["managers"],
  "additionalProperties": false,
  "properties": {
    "managers": {
      "type": "object",
      "minProperties": 1,
      "propertyNames": { "pattern": "^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$" },
      "additionalProperties": {
        "type": "object",
        "required": ["role", "host", "site", "vcf_instance", "vault_path", "tier"],
        "additionalProperties": false,
        "properties": {
          "role": { "enum": ["gm", "lm"] },
          "host": { "type": "string", "minLength": 1 },
          "site": { "type": "string", "minLength": 1 },
          "region": { "type": "string" },
          "vcf_instance": { "type": "string", "minLength": 1 },
          "sddc_manager": { "type": "string" },
          "vault_path": {
            "type": "string",
            "minLength": 1,
            "description": "Path only. Never the secret itself."
          },
          "tier": { "enum": ["prod", "preprod", "nonprod", "lab"] },
          "domain": { "type": "string" },
          "standby_for": { "type": "string" },
          "enabled": { "type": "boolean" },
          "stacks": {
            "type": "array",
            "items": {
              "enum": ["global-security", "local-security", "local-network", "platform"]
            }
          },
          "description": { "type": "string" }
        }
      }
    }
  }
}
SCAFFOLD_EOF

write_file data/schema/group.schema.json <<'SCAFFOLD_EOF'
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://nsx-terraform/schema/group.json",
  "title": "Group definitions",
  "type": "object",
  "required": ["groups"],
  "additionalProperties": false,
  "properties": {
    "groups": {
      "type": "object",
      "propertyNames": { "pattern": "^[a-z0-9][a-z0-9-]{1,62}[a-z0-9]$" },
      "additionalProperties": {
        "type": "object",
        "required": ["display_name", "owner"],
        "additionalProperties": false,
        "properties": {
          "display_name": { "type": "string", "minLength": 1 },
          "description": { "type": "string" },
          "owner": {
            "enum": ["gm", "lm"],
            "description": "gm: created on the Global Manager, usable by GM policies. lm: site-local."
          },
          "domain": { "type": "string" },
          "sites": {
            "type": "array",
            "items": { "type": "string" },
            "description": "Required for owner=lm. Site ids from inventory/managers.yaml."
          },
          "why_static": {
            "type": "string",
            "description": "Required when the group has static membership. Explain what would let it become dynamic."
          },
          "conjunction": { "enum": ["AND", "OR"] },
          "tags": {
            "type": "array",
            "items": {
              "type": "object",
              "required": ["scope", "tag"],
              "additionalProperties": false,
              "properties": {
                "scope": { "type": "string" },
                "tag": { "type": "string" }
              }
            }
          },
          "criteria": {
            "type": "array",
            "minItems": 1,
            "items": {
              "type": "object",
              "additionalProperties": false,
              "properties": {
                "conditions": {
                  "type": "array",
                  "items": {
                    "type": "object",
                    "required": ["key", "member_type", "operator", "value"],
                    "additionalProperties": false,
                    "properties": {
                      "key": {
                        "enum": ["Tag", "Name", "OSName", "ComputerName", "NodeType", "GroupType"]
                      },
                      "member_type": {
                        "enum": [
                          "VirtualMachine", "Segment", "SegmentPort", "LogicalPort",
                          "LogicalSwitch", "IPSet", "IPAddress", "Group", "DVPG",
                          "DVPort", "TransportNode", "BareMetalServer"
                        ]
                      },
                      "operator": {
                        "enum": [
                          "EQUALS", "NOTEQUALS", "CONTAINS", "STARTSWITH",
                          "ENDSWITH", "IN", "NOTIN", "MATCHES"
                        ]
                      },
                      "value": { "type": "string", "minLength": 1 }
                    }
                  }
                },
                "ip_addresses": {
                  "type": "array",
                  "items": { "type": "string" }
                },
                "member_groups": {
                  "type": "array",
                  "items": { "type": "string" },
                  "description": "Logical group names, resolved to paths by the module."
                }
              }
            }
          }
        }
      }
    }
  }
}
SCAFFOLD_EOF

write_file data/schema/policy.schema.json <<'SCAFFOLD_EOF'
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://nsx-terraform/schema/policy.json",
  "title": "DFW policy and rules",
  "type": "object",
  "required": ["policy", "rules"],
  "additionalProperties": false,
  "properties": {
    "policy": {
      "type": "object",
      "required": ["id", "name", "category", "owner", "scope", "rule_management"],
      "additionalProperties": false,
      "properties": {
        "id": {
          "type": "string",
          "pattern": "^[a-z0-9][a-z0-9-]{1,62}[a-z0-9]$",
          "description": "Deterministic nsx_id. Never changes; renaming display_name stays metadata-only."
        },
        "name": { "type": "string", "minLength": 1 },
        "description": { "type": "string" },
        "category": {
          "enum": ["Ethernet", "Emergency", "Infrastructure", "Environment", "Application"]
        },
        "owner": { "enum": ["gm", "lm"] },
        "domain": { "type": "string" },
        "sites": { "type": "array", "items": { "type": "string" } },
        "sequence_number": { "type": "integer", "minimum": 1 },
        "stateful": { "type": "boolean" },
        "tcp_strict": { "type": "boolean" },
        "locked": { "type": "boolean" },
        "scope": {
          "type": "array",
          "minItems": 1,
          "items": { "type": "string" },
          "description": "Mandatory Apply To. Logical group names."
        },
        "rule_management": {
          "enum": ["standalone", "inline"],
          "description": "Never both on one policy — the provider forbids it."
        }
      }
    },
    "rules": {
      "type": "object",
      "minProperties": 1,
      "propertyNames": { "pattern": "^[a-z0-9][a-z0-9-]{1,62}[a-z0-9]$" },
      "additionalProperties": {
        "type": "object",
        "required": ["sequence_number", "action", "direction", "scope"],
        "additionalProperties": false,
        "properties": {
          "name": { "type": "string" },
          "description": { "type": "string" },
          "sequence_number": { "type": "integer", "minimum": 1 },
          "action": { "enum": ["ALLOW", "DROP", "REJECT", "JUMP_TO_APPLICATION"] },
          "direction": { "enum": ["IN", "OUT", "IN_OUT"] },
          "ip_version": { "enum": ["IPV4", "IPV6", "IPV4_IPV6"] },
          "disabled": { "type": "boolean" },
          "logged": { "type": "boolean" },
          "notes": { "type": "string" },
          "log_label": { "type": "string" },
          "profiles": { "type": "array", "items": { "type": "string" } },
          "source_groups": { "type": "array", "items": { "type": "string" } },
          "destination_groups": { "type": "array", "items": { "type": "string" } },
          "sources_excluded": { "type": "boolean" },
          "destinations_excluded": { "type": "boolean" },
          "services": { "type": "array", "items": { "type": "string" } },
          "scope": {
            "type": "array",
            "minItems": 1,
            "items": { "type": "string" },
            "description": "Mandatory. An unscoped rule is pushed to every host in the span."
          }
        }
      }
    }
  }
}
SCAFFOLD_EOF

write_file data/schema/service.schema.json <<'SCAFFOLD_EOF'
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://nsx-terraform/schema/service.json",
  "title": "Service definitions",
  "type": "object",
  "additionalProperties": false,
  "properties": {
    "predefined": {
      "type": "object",
      "propertyNames": { "pattern": "^[a-z0-9][a-z0-9-]{0,62}[a-z0-9]$" },
      "additionalProperties": {
        "type": "string",
        "description": "display_name of a service that already exists in NSX; looked up, not created."
      }
    },
    "custom": {
      "type": "object",
      "propertyNames": { "pattern": "^[a-z0-9][a-z0-9-]{0,62}[a-z0-9]$" },
      "additionalProperties": {
        "type": "object",
        "required": ["display_name"],
        "additionalProperties": false,
        "properties": {
          "display_name": { "type": "string", "minLength": 1 },
          "description": { "type": "string" },
          "owner": { "enum": ["gm", "lm"] },
          "l4_port_set": {
            "type": "array",
            "items": {
              "type": "object",
              "required": ["protocol", "destination_ports"],
              "additionalProperties": false,
              "properties": {
                "display_name": { "type": "string" },
                "protocol": { "enum": ["TCP", "UDP"] },
                "destination_ports": { "type": "array", "items": { "type": "string" } },
                "source_ports": { "type": "array", "items": { "type": "string" } }
              }
            }
          },
          "icmp": {
            "type": "array",
            "items": {
              "type": "object",
              "required": ["protocol"],
              "additionalProperties": false,
              "properties": {
                "display_name": { "type": "string" },
                "protocol": { "enum": ["ICMPv4", "ICMPv6"] },
                "icmp_type": { "type": "string" },
                "icmp_code": { "type": "string" }
              }
            }
          }
        }
      }
    }
  }
}
SCAFFOLD_EOF

write_file data/schema/network.schema.json <<'SCAFFOLD_EOF'
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://nsx-terraform/schema/network.json",
  "title": "Per-site segments and tier-1 gateways",
  "type": "object",
  "required": ["site"],
  "additionalProperties": false,
  "properties": {
    "site": { "type": "string", "minLength": 1 },
    "tier1s": {
      "type": "object",
      "propertyNames": { "pattern": "^[a-z0-9][a-z0-9-]{1,62}[a-z0-9]$" },
      "additionalProperties": {
        "type": "object",
        "required": ["display_name"],
        "additionalProperties": false,
        "properties": {
          "display_name": { "type": "string", "minLength": 1 },
          "description": { "type": "string" },
          "tier0_display_name": { "type": "string" },
          "edge_cluster_display_name": { "type": "string" },
          "failover_mode": { "enum": ["PREEMPTIVE", "NON_PREEMPTIVE"] },
          "route_advertisement_types": { "type": "array", "items": { "type": "string" } },
          "enable_standby_relocation": { "type": "boolean" },
          "pool_allocation": { "type": "string" },
          "tags": {
            "type": "array",
            "items": {
              "type": "object",
              "required": ["scope", "tag"],
              "additionalProperties": false,
              "properties": {
                "scope": { "type": "string" },
                "tag": { "type": "string" }
              }
            }
          }
        }
      }
    },
    "segments": {
      "type": "object",
      "propertyNames": { "pattern": "^[a-z0-9][a-z0-9-]{1,62}[a-z0-9]$" },
      "additionalProperties": {
        "type": "object",
        "required": ["display_name", "transport_zone_display_name", "tags"],
        "additionalProperties": false,
        "properties": {
          "display_name": { "type": "string", "minLength": 1 },
          "description": { "type": "string" },
          "tier1": { "type": "string", "description": "Logical tier1 key from this file." },
          "transport_zone_display_name": { "type": "string", "minLength": 1 },
          "vlan_ids": { "type": "array", "items": { "type": "string" } },
          "domain_name": { "type": "string" },
          "subnets": {
            "type": "array",
            "items": {
              "type": "object",
              "required": ["cidr"],
              "additionalProperties": false,
              "properties": {
                "cidr": { "type": "string", "minLength": 1 },
                "dhcp_ranges": { "type": "array", "items": { "type": "string" } }
              }
            }
          },
          "tags": {
            "type": "array",
            "minItems": 1,
            "description": "Segments are Terraform-owned, so their tags live here and drive subnet-based group membership.",
            "items": {
              "type": "object",
              "required": ["scope", "tag"],
              "additionalProperties": false,
              "properties": {
                "scope": { "type": "string" },
                "tag": { "type": "string" }
              }
            }
          }
        }
      }
    }
  }
}
SCAFFOLD_EOF

write_file data/schema/platform.schema.json <<'SCAFFOLD_EOF'
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://nsx-terraform/schema/platform.json",
  "title": "Per-site platform objects (RESTRICTED — docs/ARCHITECTURE.md section 11)",
  "type": "object",
  "required": ["site"],
  "additionalProperties": false,
  "properties": {
    "site": { "type": "string", "minLength": 1 },
    "tier0s": {
      "type": "object",
      "propertyNames": { "pattern": "^[a-z0-9][a-z0-9-]{1,62}[a-z0-9]$" },
      "additionalProperties": {
        "type": "object",
        "required": ["display_name", "edge_cluster_display_name"],
        "additionalProperties": false,
        "properties": {
          "display_name": { "type": "string", "minLength": 1 },
          "description": { "type": "string" },
          "ha_mode": { "enum": ["ACTIVE_ACTIVE", "ACTIVE_STANDBY"] },
          "failover_mode": { "enum": ["PREEMPTIVE", "NON_PREEMPTIVE"] },
          "transit_subnets": { "type": "array", "items": { "type": "string" } },
          "edge_cluster_display_name": { "type": "string", "minLength": 1 },
          "bgp": {
            "type": "object",
            "additionalProperties": false,
            "properties": {
              "enabled": { "type": "boolean" },
              "local_as_num": { "type": "string" },
              "ecmp": { "type": "boolean" },
              "inter_sr_ibgp": { "type": "boolean" },
              "graceful_restart_mode": { "type": "string" }
            }
          },
          "tags": {
            "type": "array",
            "items": {
              "type": "object",
              "required": ["scope", "tag"],
              "additionalProperties": false,
              "properties": {
                "scope": { "type": "string" },
                "tag": { "type": "string" }
              }
            }
          }
        }
      }
    }
  }
}
SCAFFOLD_EOF

# ---------------------------------------------------------------------------
# 4. Modules
# ---------------------------------------------------------------------------

for m in dfw-policy group service segment tier1 tier0; do
	write_file "modules/$m/versions.tf" <<'SCAFFOLD_EOF'
terraform {
  required_version = ">= 1.9"

  required_providers {
    nsxt = {
      source  = "vmware/nsxt"
      version = "~> 3.9"
    }
  }
}
SCAFFOLD_EOF
done

# --- modules/group ---------------------------------------------------------

write_file modules/group/variables.tf <<'SCAFFOLD_EOF'
variable "groups" {
  description = <<-EOT
    Map of group definitions keyed by stable logical name. The key is the
    Terraform address and the nsx_id — renaming it destroys and recreates the
    group, which drops it out of every policy that references it. Never rename.
  EOT
  type        = any

  validation {
    condition     = alltrue([for k, v in var.groups : can(v.display_name)])
    error_message = "Every group needs a display_name."
  }
}

variable "domain" {
  description = "Default NSX domain. On a Global Manager this is a domain id or a site id; set it explicitly, an accidental 'default' has estate-wide span."
  type        = string
}

variable "group_paths" {
  description = "Paths of groups defined elsewhere, for nested group membership. Logical name => policy path."
  type        = map(string)
  default     = {}
}
SCAFFOLD_EOF

write_file modules/group/main.tf <<'SCAFFOLD_EOF'
# Groups, built from data. Membership is dynamic wherever it can be: tags are
# written by the system that owns the workload, and this repository only
# consumes them (docs/ARCHITECTURE.md section 7).

locals {
  # Nested group references arrive as logical names and are resolved to policy
  # paths from var.group_paths, so no data file ever contains a raw /infra/...
  # path. A name nothing supplies is a plan-time error, not an API rejection.
  unresolved_member_groups = {
    for k, g in var.groups : k => sort(tolist(setsubtract(
      toset(flatten([for c in try(g.criteria, []) : try(c.member_groups, [])])),
      toset(keys(var.group_paths)),
    )))
  }
}

resource "nsxt_policy_group" "this" {
  for_each = var.groups

  nsx_id       = each.key
  display_name = each.value.display_name
  description  = try(each.value.description, null)
  domain       = try(each.value.domain, var.domain)

  dynamic "criteria" {
    for_each = try(each.value.criteria, [])

    content {
      dynamic "condition" {
        for_each = try(criteria.value.conditions, [])

        content {
          key         = condition.value.key
          member_type = condition.value.member_type
          operator    = condition.value.operator
          value       = condition.value.value
        }
      }

      dynamic "ipaddress_expression" {
        for_each = length(try(criteria.value.ip_addresses, [])) > 0 ? [1] : []

        content {
          ip_addresses = criteria.value.ip_addresses
        }
      }

      dynamic "path_expression" {
        for_each = length(try(criteria.value.member_groups, [])) > 0 ? [1] : []

        content {
          member_paths = [
            for name in criteria.value.member_groups : lookup(var.group_paths, name, name)
          ]
        }
      }
    }
  }

  # The provider pairs criteria[i] with conjunction[i] in order, so one
  # conjunction is needed between every adjacent pair of criteria blocks.
  dynamic "conjunction" {
    for_each = range(max(length(try(each.value.criteria, [])) - 1, 0))

    content {
      operator = try(each.value.conjunction, "OR")
    }
  }

  dynamic "tag" {
    for_each = try(each.value.tags, [])

    content {
      scope = tag.value.scope
      tag   = tag.value.tag
    }
  }

  lifecycle {
    precondition {
      condition     = length(try(each.value.criteria, [])) > 0
      error_message = "Group ${each.key} has no criteria. A group with no membership matches nothing and silently drops traffic."
    }

    precondition {
      condition     = length(local.unresolved_member_groups[each.key]) == 0
      error_message = "Group ${each.key} nests undefined group(s): ${join(", ", local.unresolved_member_groups[each.key])}."
    }
  }
}
SCAFFOLD_EOF

write_file modules/group/outputs.tf <<'SCAFFOLD_EOF'
output "paths" {
  description = "Logical group name => NSX policy path. Feed this to the dfw-policy module so data files can reference groups by name."
  value       = { for k, g in nsxt_policy_group.this : k => g.path }
}

output "ids" {
  description = "Logical group name => nsx_id."
  value       = { for k, g in nsxt_policy_group.this : k => g.nsx_id }
}
SCAFFOLD_EOF

write_file modules/group/README.md <<'SCAFFOLD_EOF'
# module: group

Creates NSX policy groups from data. Keyed by `for_each` over a map with stable
string keys — never `count`.

## Input shape

```yaml
prod-payments-web:
  display_name: prod-payments-web
  owner: gm
  conjunction: AND          # joins adjacent criteria blocks; default OR
  criteria:
    - conditions:
        - key: Tag
          member_type: VirtualMachine
          operator: EQUALS
          value: "app|payments"   # scope|value
        - key: Tag
          member_type: VirtualMachine
          operator: EQUALS
          value: "tier|web"
```

Conditions inside one `criteria` block are ANDed by NSX. Separate `criteria`
blocks are joined by `conjunction`.

## Notes

- `nsx_id` is the map key, so a `display_name` change is metadata-only rather
  than a destroy-and-recreate.
- Prefer `EQUALS` over `CONTAINS`/`STARTSWITH`: `app|payments` must not also
  match `app|payments-test`.
- For subnet-based membership match `member_type: Segment` against a segment
  tag instead of hardcoding a CIDR. Segments are Terraform-owned, so their tags
  are reliable and a CIDR here would be a duplicated fact.
- Static membership (`ip_addresses`, `member_groups`) requires `why_static` in
  the data file; CI enforces it.
SCAFFOLD_EOF

# --- modules/service -------------------------------------------------------

write_file modules/service/variables.tf <<'SCAFFOLD_EOF'
variable "services" {
  description = "Map of custom service definitions keyed by stable logical name."
  type        = any
  default     = {}
}
SCAFFOLD_EOF

write_file modules/service/main.tf <<'SCAFFOLD_EOF'
# Custom services. Anything NSX ships with is looked up as a data source in the
# stack instead of being recreated here.

resource "nsxt_policy_service" "this" {
  for_each = var.services

  nsx_id       = each.key
  display_name = each.value.display_name
  description  = try(each.value.description, null)

  dynamic "l4_port_set_entry" {
    for_each = try(each.value.l4_port_set, [])

    content {
      display_name      = try(l4_port_set_entry.value.display_name, "${each.key}-${l4_port_set_entry.key}")
      protocol          = l4_port_set_entry.value.protocol
      destination_ports = l4_port_set_entry.value.destination_ports
      source_ports      = try(l4_port_set_entry.value.source_ports, null)
    }
  }

  dynamic "icmp_entry" {
    for_each = try(each.value.icmp, [])

    content {
      display_name = try(icmp_entry.value.display_name, "${each.key}-icmp-${icmp_entry.key}")
      protocol     = icmp_entry.value.protocol
      icmp_type    = try(icmp_entry.value.icmp_type, null)
      icmp_code    = try(icmp_entry.value.icmp_code, null)
    }
  }
}
SCAFFOLD_EOF

write_file modules/service/outputs.tf <<'SCAFFOLD_EOF'
output "paths" {
  description = "Logical service name => NSX policy path."
  value       = { for k, s in nsxt_policy_service.this : k => s.path }
}
SCAFFOLD_EOF

write_file modules/service/README.md <<'SCAFFOLD_EOF'
# module: service

Creates custom NSX services (L4 port sets, ICMP entries) from
`data/services/*.yaml`.

Predefined NSX services (HTTPS, SSH, …) are *not* created here — the stack
resolves them with a `nsxt_policy_service` data source, so there is one
definition of HTTPS in the estate rather than one per repository.

```yaml
custom:
  payments-api:
    display_name: payments-api
    l4_port_set:
      - protocol: TCP
        destination_ports: ["8443"]
```
SCAFFOLD_EOF

# --- modules/dfw-policy ----------------------------------------------------

write_file modules/dfw-policy/variables.tf <<'SCAFFOLD_EOF'
variable "policy" {
  description = "Policy header from the data file: id, name, category, scope, and options."
  type        = any

  validation {
    condition     = length(try(var.policy.scope, [])) > 0
    error_message = "policy.scope is mandatory. An unscoped policy is pushed to every hypervisor in its span."
  }

  validation {
    condition     = try(var.policy.rule_management, "standalone") == "standalone"
    error_message = "This module implements the parent-policy + standalone-rule pattern. Set rule_management: standalone, or manage the policy elsewhere — the provider forbids mixing the two on one policy."
  }
}

variable "rules" {
  description = <<-EOT
    Map of rules keyed by stable rule id. The key is the Terraform address:
    changing a value updates the rule in place, renaming a key destroys and
    recreates it. Never use count or list indices here — inserting a rule in
    the middle of an indexed list recreates every rule below it, which on a
    live DFW is a traffic outage.
  EOT
  type        = any
}

variable "domain" {
  description = "NSX domain for this policy. On a Global Manager, a domain id or a site id — set it explicitly."
  type        = string
}

variable "group_paths" {
  description = "Logical group name => NSX policy path. Data files reference groups by name only."
  type        = map(string)
}

variable "service_paths" {
  description = "Logical service name => NSX policy path."
  type        = map(string)
  default     = {}
}
SCAFFOLD_EOF

write_file modules/dfw-policy/main.tf <<'SCAFFOLD_EOF'
# Parent policy + one resource per rule.
#
# This is what makes daily rule churn safe: adding or removing a single rule
# touches exactly one resource. The alternative — nsxt_policy_security_policy
# with inline rule blocks — rewrites the whole policy on every change. The two
# must never be mixed on the same policy; the provider says so explicitly.

locals {
  # "ANY" is the one literal allowed in a data file. Everything else is a
  # logical name resolved to a policy path here, so no raw /infra/... path ever
  # appears in data/.
  resolvable = concat(keys(var.group_paths), ["ANY"])

  policy_scope = [for g in var.policy.scope : var.group_paths[g] if g != "ANY"]

  rule_sources = {
    for k, r in var.rules : k => [
      for g in try(r.source_groups, []) : lookup(var.group_paths, g, g) if g != "ANY"
    ]
  }

  rule_destinations = {
    for k, r in var.rules : k => [
      for g in try(r.destination_groups, []) : lookup(var.group_paths, g, g) if g != "ANY"
    ]
  }

  rule_scopes = {
    for k, r in var.rules : k => [
      for g in try(r.scope, []) : lookup(var.group_paths, g, g) if g != "ANY"
    ]
  }

  rule_services = {
    for k, r in var.rules : k => [
      for s in try(r.services, []) : lookup(var.service_paths, s, s) if s != "ANY"
    ]
  }

  # Names referenced by a rule that nothing in this stack defines. Surfaced as a
  # plan-time error rather than a confusing API rejection at apply time.
  unresolved_groups = {
    for k, r in var.rules : k => sort(tolist(setsubtract(
      toset(concat(
        try(r.source_groups, []),
        try(r.destination_groups, []),
        try(r.scope, []),
      )),
      toset(local.resolvable),
    )))
  }

  unresolved_services = {
    for k, r in var.rules : k => sort(tolist(setsubtract(
      toset(try(r.services, [])),
      toset(concat(keys(var.service_paths), ["ANY"])),
    )))
  }

  sequence_numbers = [for k, r in var.rules : r.sequence_number]
}

resource "nsxt_policy_parent_security_policy" "this" {
  nsx_id       = var.policy.id
  display_name = var.policy.name
  description  = try(var.policy.description, null)
  domain       = try(var.policy.domain, var.domain)
  category     = var.policy.category

  sequence_number = try(var.policy.sequence_number, 100)
  stateful        = try(var.policy.stateful, true)
  tcp_strict      = try(var.policy.tcp_strict, null)
  locked          = try(var.policy.locked, false)

  # Apply To. Mandatory — see the validation on var.policy.
  scope = local.policy_scope

  lifecycle {
    precondition {
      condition     = length(local.sequence_numbers) == length(distinct(local.sequence_numbers))
      error_message = "Duplicate sequence_number in policy ${var.policy.id}. Sequence numbers are allocated, not guessed."
    }
  }
}

resource "nsxt_policy_security_policy_rule" "this" {
  for_each = var.rules

  nsx_id       = each.key
  display_name = try(each.value.name, each.key)
  description  = try(each.value.description, null)
  policy_path  = nsxt_policy_parent_security_policy.this.path

  sequence_number = each.value.sequence_number
  action          = each.value.action
  direction       = each.value.direction
  ip_version      = try(each.value.ip_version, "IPV4_IPV6")
  disabled        = try(each.value.disabled, false)
  logged          = try(each.value.logged, true)
  notes           = try(each.value.notes, null)
  log_label       = try(each.value.log_label, null)

  source_groups         = local.rule_sources[each.key]
  destination_groups    = local.rule_destinations[each.key]
  sources_excluded      = try(each.value.sources_excluded, false)
  destinations_excluded = try(each.value.destinations_excluded, false)
  services              = local.rule_services[each.key]
  profiles              = try(each.value.profiles, null)

  # Apply To. Without it the rule is distributed to every hypervisor in the
  # policy's span; host rule capacity is finite and this is a multi-site span.
  scope = local.rule_scopes[each.key]

  lifecycle {
    precondition {
      condition     = length(try(each.value.scope, [])) > 0
      error_message = "Rule ${each.key} in policy ${var.policy.id} has an empty scope. Every rule must set Apply To."
    }

    precondition {
      condition     = length(local.unresolved_groups[each.key]) == 0
      error_message = "Rule ${each.key} references undefined group(s): ${join(", ", local.unresolved_groups[each.key])}. Groups referenced by a Global Manager policy must be created on the Global Manager."
    }

    precondition {
      condition     = length(local.unresolved_services[each.key]) == 0
      error_message = "Rule ${each.key} references undefined service(s): ${join(", ", local.unresolved_services[each.key])}."
    }
  }
}
SCAFFOLD_EOF

write_file modules/dfw-policy/outputs.tf <<'SCAFFOLD_EOF'
output "policy_path" {
  description = "Policy path of the parent security policy."
  value       = nsxt_policy_parent_security_policy.this.path
}

output "rule_paths" {
  description = "Rule key => NSX policy path."
  value       = { for k, r in nsxt_policy_security_policy_rule.this : k => r.path }
}

output "rule_count" {
  description = "Number of rules under this policy. Compare against the plan's count delta."
  value       = length(nsxt_policy_security_policy_rule.this)
}
SCAFFOLD_EOF

write_file modules/dfw-policy/README.md <<'SCAFFOLD_EOF'
# module: dfw-policy

One `nsxt_policy_parent_security_policy` plus one
`nsxt_policy_security_policy_rule` per rule, built from a data file.

## Why standalone rules

Inline `rule` blocks on `nsxt_policy_security_policy` rewrite the entire policy
on every change. With one resource per rule, adding or removing a rule touches
exactly that rule. The provider forbids managing the same policy both ways —
choose per policy and record it as `rule_management` in the data file.

## Contract

- Rules arrive as a **map** keyed by stable rule id. Never a list, never
  `count`. Rename a key only if you intend a destroy-and-recreate.
- `scope` is mandatory at policy and rule level, enforced by a variable
  validation and a per-rule precondition.
- Groups and services are referenced by **logical name**; this module resolves
  them to policy paths from `group_paths` / `service_paths`. A name nothing
  defines fails at plan time with the offending rule named — in particular this
  is what catches a Global Manager policy referencing a site-local group, which
  Federation cannot span.
- `nsx_id` is set from the data key, so renaming `display_name` is
  metadata-only rather than a destroy-and-recreate.
- Sequence numbers are checked for duplicates within the policy at plan time.

## Not handled here

The **default rule** is deliberately not managed by this module. Flipping it
from ALLOW to DROP, or deleting it, black-holes a datacenter; it is a
restricted change with its own review path.
SCAFFOLD_EOF

# --- modules/segment -------------------------------------------------------

write_file modules/segment/variables.tf <<'SCAFFOLD_EOF'
variable "segments" {
  description = "Map of segment definitions keyed by stable logical name."
  type        = any
  default     = {}
}

variable "tier1_paths" {
  description = "Logical tier-1 name => NSX policy path, for segment connectivity."
  type        = map(string)
  default     = {}
}
SCAFFOLD_EOF

write_file modules/segment/main.tf <<'SCAFFOLD_EOF'
# Segments are Terraform-owned infrastructure, so tagging them here is correct —
# unlike VM tags, which belong to whatever system provisions the VM.
#
# Segment tags are what makes subnet-based group membership possible without
# hardcoding CIDRs into group criteria.

data "nsxt_policy_transport_zone" "this" {
  for_each = toset([for k, s in var.segments : s.transport_zone_display_name])

  display_name = each.value
}

resource "nsxt_policy_segment" "this" {
  for_each = var.segments

  nsx_id       = each.key
  display_name = each.value.display_name
  description  = try(each.value.description, null)

  transport_zone_path = data.nsxt_policy_transport_zone.this[each.value.transport_zone_display_name].path
  connectivity_path   = try(var.tier1_paths[each.value.tier1], null)
  domain_name         = try(each.value.domain_name, null)
  vlan_ids            = try(each.value.vlan_ids, null)

  dynamic "subnet" {
    for_each = try(each.value.subnets, [])

    content {
      cidr        = subnet.value.cidr
      dhcp_ranges = try(subnet.value.dhcp_ranges, null)
    }
  }

  dynamic "tag" {
    for_each = try(each.value.tags, [])

    content {
      scope = tag.value.scope
      tag   = tag.value.tag
    }
  }

  lifecycle {
    precondition {
      condition     = length(try(each.value.tags, [])) > 0
      error_message = "Segment ${each.key} has no tags. Segment tags drive subnet-based group membership; an untagged segment cannot be matched by a group."
    }
  }
}
SCAFFOLD_EOF

write_file modules/segment/outputs.tf <<'SCAFFOLD_EOF'
output "paths" {
  description = "Logical segment name => NSX policy path."
  value       = { for k, s in nsxt_policy_segment.this : k => s.path }
}
SCAFFOLD_EOF

write_file modules/segment/README.md <<'SCAFFOLD_EOF'
# module: segment

Creates NSX segments from `data/network/<site>.yaml`.

Transport zones are resolved by display name through a data source, so no raw
policy path appears in a data file and the same data works against any manager.

Tags are mandatory: a group that selects workloads by subnet does it by matching
`member_type: Segment` against a segment tag, never by embedding a CIDR. A CIDR
in a group is a duplicated fact that drifts from the segment's real definition.
SCAFFOLD_EOF

# --- modules/tier1 ---------------------------------------------------------

write_file modules/tier1/variables.tf <<'SCAFFOLD_EOF'
variable "tier1s" {
  description = "Map of tier-1 gateway definitions keyed by stable logical name."
  type        = any
  default     = {}
}
SCAFFOLD_EOF

write_file modules/tier1/main.tf <<'SCAFFOLD_EOF'
data "nsxt_policy_tier0_gateway" "this" {
  for_each = toset(compact([for k, t in var.tier1s : try(t.tier0_display_name, "")]))

  display_name = each.value
}

data "nsxt_policy_edge_cluster" "this" {
  for_each = toset(compact([for k, t in var.tier1s : try(t.edge_cluster_display_name, "")]))

  display_name = each.value
}

resource "nsxt_policy_tier1_gateway" "this" {
  for_each = var.tier1s

  nsx_id       = each.key
  display_name = each.value.display_name
  description  = try(each.value.description, null)

  tier0_path        = try(data.nsxt_policy_tier0_gateway.this[each.value.tier0_display_name].path, null)
  edge_cluster_path = try(data.nsxt_policy_edge_cluster.this[each.value.edge_cluster_display_name].path, null)

  failover_mode             = try(each.value.failover_mode, null)
  route_advertisement_types = try(each.value.route_advertisement_types, null)
  enable_standby_relocation = try(each.value.enable_standby_relocation, null)
  pool_allocation           = try(each.value.pool_allocation, null)

  dynamic "tag" {
    for_each = try(each.value.tags, [])

    content {
      scope = tag.value.scope
      tag   = tag.value.tag
    }
  }
}
SCAFFOLD_EOF

write_file modules/tier1/outputs.tf <<'SCAFFOLD_EOF'
output "paths" {
  description = "Logical tier-1 name => NSX policy path."
  value       = { for k, t in nsxt_policy_tier1_gateway.this : k => t.path }
}
SCAFFOLD_EOF

write_file modules/tier1/README.md <<'SCAFFOLD_EOF'
# module: tier1

Tier-1 gateways for one site, from `data/network/<site>.yaml`.

T0 gateways and edge clusters are referenced by display name and resolved
through data sources — they are owned by the `platform` stack and read here.
That read is a data-source lookup against the live manager, not a
`terraform_remote_state` read: a network change must not depend on the platform
state being available or correct.
SCAFFOLD_EOF

# --- modules/tier0 ---------------------------------------------------------

write_file modules/tier0/variables.tf <<'SCAFFOLD_EOF'
variable "tier0s" {
  description = "Map of tier-0 gateway definitions keyed by stable logical name. RESTRICTED — see docs/ARCHITECTURE.md section 11."
  type        = any
  default     = {}
}
SCAFFOLD_EOF

write_file modules/tier0/main.tf <<'SCAFFOLD_EOF'
# Tier-0 gateways. This is the platform layer: the slowest thing in the estate
# and the most dangerous. Every change here is a restricted change.

data "nsxt_policy_edge_cluster" "this" {
  for_each = toset([for k, t in var.tier0s : t.edge_cluster_display_name])

  display_name = each.value
}

resource "nsxt_policy_tier0_gateway" "this" {
  for_each = var.tier0s

  nsx_id       = each.key
  display_name = each.value.display_name
  description  = try(each.value.description, null)

  ha_mode           = try(each.value.ha_mode, "ACTIVE_ACTIVE")
  failover_mode     = try(each.value.failover_mode, null)
  transit_subnets   = try(each.value.transit_subnets, null)
  edge_cluster_path = data.nsxt_policy_edge_cluster.this[each.value.edge_cluster_display_name].path

  dynamic "bgp_config" {
    for_each = try(each.value.bgp, null) == null ? [] : [each.value.bgp]

    content {
      enabled               = try(bgp_config.value.enabled, true)
      local_as_num          = try(bgp_config.value.local_as_num, null)
      ecmp                  = try(bgp_config.value.ecmp, true)
      inter_sr_ibgp         = try(bgp_config.value.inter_sr_ibgp, null)
      graceful_restart_mode = try(bgp_config.value.graceful_restart_mode, null)
    }
  }

  dynamic "tag" {
    for_each = try(each.value.tags, [])

    content {
      scope = tag.value.scope
      tag   = tag.value.tag
    }
  }
}
SCAFFOLD_EOF

write_file modules/tier0/outputs.tf <<'SCAFFOLD_EOF'
output "paths" {
  description = "Logical tier-0 name => NSX policy path."
  value       = { for k, t in nsxt_policy_tier0_gateway.this : k => t.path }
}
SCAFFOLD_EOF

write_file modules/tier0/README.md <<'SCAFFOLD_EOF'
# module: tier0

Tier-0 gateways for one site, from `data/platform/<site>.yaml`.

Used only by the `platform` stack. Nothing with a daily cadence may share this
state: a rule edit must never require Terraform to refresh a T0 or a transport
zone.

Every change here is **restricted** — change advisory, named approver, rollback
plan, out-of-hours.
SCAFFOLD_EOF

# ---------------------------------------------------------------------------
# 5. Stacks
#
# One root module per stack, instantiated once per manager by the pipeline with
# partial backend config — not 10+ aliased providers in a single root module.
# ---------------------------------------------------------------------------

# Shared: data-loading locals, identical in every security stack.
gen_versions() {
	write_file "stacks/$1/versions.tf" <<'SCAFFOLD_EOF'
terraform {
  required_version = ">= 1.9"

  required_providers {
    nsxt = {
      source  = "vmware/nsxt"
      version = "~> 3.9"
    }
  }
}
SCAFFOLD_EOF
}

gen_backend() {
	write_file "stacks/$1/backend.tf" <<'SCAFFOLD_EOF'
# Partial backend configuration. Values come from envs/<site>.backend.hcl:
#
#   terraform init -backend-config=../../envs/${SITE}.backend.hcl
#
# OPEN DECISION (docs/ARCHITECTURE.md section 14.1): the backend type is the owner's call
# and has not been made. Until it is, this is the local backend so the stack
# initialises out of the box for validation and dry runs.
#
# The local backend is NOT acceptable for a real manager: state carries the full
# security posture of the estate and needs encryption at rest, locking, and
# access restricted to the pipeline identity. scripts/tf.sh refuses to apply
# through a local backend unless ALLOW_LOCAL_STATE=1 is set explicitly.
#
# Replace the block below with the chosen backend and update
# envs/*.backend.hcl to match. Example for s3:
#
#   backend "s3" {}
#
# with envs/lon1.backend.hcl supplying bucket / key / region / dynamodb_table /
# kms_key_id.

terraform {
  backend "local" {}
}
SCAFFOLD_EOF
}

for s in global-security local-security local-network platform; do
	gen_versions "$s"
	gen_backend "$s"
done

# --- stacks/global-security ------------------------------------------------

write_file stacks/global-security/providers.tf <<'SCAFFOLD_EOF'
# host / username / password come from NSXT_MANAGER_HOST, NSXT_USERNAME and
# NSXT_PASSWORD, exported by the pipeline from Vault. Nothing sensitive is ever
# written into a .tf file, a variable, or state.
provider "nsxt" {
  global_manager = true

  # Federation realization is slower than a Local Manager's: the GM accepts a
  # policy before every site has realized it. Under-tuned retries surface that
  # as spurious errors.
  max_retries     = 6
  retry_min_delay = 500
  retry_max_delay = 5000
}
SCAFFOLD_EOF

write_file stacks/global-security/variables.tf <<'SCAFFOLD_EOF'
variable "domain" {
  description = <<-EOT
    NSX domain for objects created by this stack. On a Global Manager this is a
    domain id or a site id, and it determines the object's span. There is no
    default on purpose: an accidental 'default' domain gives estate-wide span.
  EOT
  type        = string
}

variable "data_root" {
  description = "Location of the data/ tree relative to this stack."
  type        = string
  default     = "../../data"
}
SCAFFOLD_EOF

write_file stacks/global-security/main.tf <<'SCAFFOLD_EOF'
# global-security — the federated DFW, owned by the Global Manager.
#
# Objects created here are read-only on every Local Manager. Nothing in a
# local-* stack may manage the same object; two stacks pointed at one object
# produces permanent drift and failed applies.

locals {
  data_root = "${path.module}/${var.data_root}"

  # --- groups -------------------------------------------------------------
  group_files = fileset("${local.data_root}/groups", "*.yaml")

  groups_all = merge([
    for f in local.group_files : try(yamldecode(file("${local.data_root}/groups/${f}")).groups, {})
  ]...)

  groups = { for k, g in local.groups_all : k => g if try(g.owner, "lm") == "gm" }

  # Groups that reference other groups are created in a second pass so their
  # member paths can be resolved. A group cannot reference itself into
  # existence.
  composite_group_keys = [
    for k, g in local.groups : k
    if length(flatten([for c in try(g.criteria, []) : try(c.member_groups, [])])) > 0
  ]

  base_groups      = { for k, g in local.groups : k => g if !contains(local.composite_group_keys, k) }
  composite_groups = { for k, g in local.groups : k => g if contains(local.composite_group_keys, k) }

  group_paths = merge(module.base_groups.paths, module.composite_groups.paths)

  # --- services -----------------------------------------------------------
  service_files = fileset("${local.data_root}/services", "*.yaml")
  service_docs  = [for f in local.service_files : yamldecode(file("${local.data_root}/services/${f}"))]

  predefined_services = merge([for d in local.service_docs : try(d.predefined, {})]...)
  custom_services_all = merge([for d in local.service_docs : try(d.custom, {})]...)
  custom_services     = { for k, v in local.custom_services_all : k => v if try(v.owner, "gm") == "gm" }

  service_paths = merge(
    { for k, s in data.nsxt_policy_service.predefined : k => s.path },
    module.services.paths,
  )

  # --- policies -----------------------------------------------------------
  policy_files = fileset("${local.data_root}/policies", "*.yaml")

  policy_docs = {
    for f in local.policy_files :
    trimsuffix(f, ".yaml") => yamldecode(file("${local.data_root}/policies/${f}"))
  }

  policies = {
    for k, d in local.policy_docs : k => d
    if try(d.policy.owner, "lm") == "gm" && try(d.policy.rule_management, "standalone") == "standalone"
  }
}

module "base_groups" {
  source = "../../modules/group"

  groups = local.base_groups
  domain = var.domain
}

module "composite_groups" {
  source = "../../modules/group"

  groups      = local.composite_groups
  domain      = var.domain
  group_paths = module.base_groups.paths
}

# Services NSX already ships with are looked up, never recreated.
data "nsxt_policy_service" "predefined" {
  for_each = local.predefined_services

  display_name = each.value
}

module "services" {
  source = "../../modules/service"

  services = local.custom_services
}

module "policies" {
  source   = "../../modules/dfw-policy"
  for_each = local.policies

  policy        = each.value.policy
  rules         = each.value.rules
  domain        = var.domain
  group_paths   = local.group_paths
  service_paths = local.service_paths
}
SCAFFOLD_EOF

write_file stacks/global-security/outputs.tf <<'SCAFFOLD_EOF'
output "policy_count" {
  description = "Policies managed by this stack."
  value       = length(local.policies)
}

output "rule_count" {
  description = "Total rules across all policies. Compare against the plan's count delta before approving."
  value       = sum(concat([0], [for k, m in module.policies : m.rule_count]))
}

output "group_count" {
  description = "Groups managed by this stack."
  value       = length(local.groups)
}

output "policy_paths" {
  description = "Policy key => NSX policy path."
  value       = { for k, m in module.policies : k => m.policy_path }
}
SCAFFOLD_EOF

write_file stacks/global-security/README.md <<'SCAFFOLD_EOF'
# stack: global-security

The federated DFW. One state for the federation.

- Cadence: **daily**. Blast radius: **all sites**. Approver: **security review**.
- Provider runs with `global_manager = true` and raised retries.
- Consumes every `data/policies/*.yaml` and `data/groups/*.yaml` entry marked
  `owner: gm`.

## Boundary

Objects created here are read-only on the Local Managers. A group referenced by
a policy in this stack must also be `owner: gm` — a site-local group cannot be
referenced across the span, and the dfw-policy module fails the plan if you try.

## Run

```bash
export TF_VAR_domain=global          # never leave this to default
terraform init -backend-config=../../envs/gm1.backend.hcl
terraform plan -out=tfplan -parallelism=5
```

Or from the repository root: `make plan STACK=global-security SITE=gm1`.
SCAFFOLD_EOF

# --- stacks/local-security -------------------------------------------------

write_file stacks/local-security/providers.tf <<'SCAFFOLD_EOF'
# Credentials arrive as NSXT_* environment variables from the pipeline.
provider "nsxt" {
  # global_manager stays false: this stack talks to a Local Manager.
  max_retries     = 4
  retry_min_delay = 200
  retry_max_delay = 1000
}
SCAFFOLD_EOF

write_file stacks/local-security/variables.tf <<'SCAFFOLD_EOF'
variable "site" {
  description = "Site id of the Local Manager this run targets. Must match a key in inventory/managers.yaml."
  type        = string
}

variable "domain" {
  description = "NSX domain on the Local Manager. 'default' is the only domain on a standard LM."
  type        = string
  default     = "default"
}

variable "data_root" {
  description = "Location of the data/ tree relative to this stack."
  type        = string
  default     = "../../data"
}
SCAFFOLD_EOF

write_file stacks/local-security/main.tf <<'SCAFFOLD_EOF'
# local-security — site-local DFW exceptions for one Local Manager.
#
# One state per LM. Anything federated belongs in global-security; this stack
# must never manage a GM-owned object, which the Local Manager would reject as
# read-only anyway.

locals {
  data_root = "${path.module}/${var.data_root}"

  # --- groups -------------------------------------------------------------
  group_files = fileset("${local.data_root}/groups", "*.yaml")

  groups_all = merge([
    for f in local.group_files : try(yamldecode(file("${local.data_root}/groups/${f}")).groups, {})
  ]...)

  groups = {
    for k, g in local.groups_all : k => g
    if try(g.owner, "lm") == "lm" && (
      contains(try(g.sites, []), var.site) || contains(try(g.sites, []), "*")
    )
  }

  composite_group_keys = [
    for k, g in local.groups : k
    if length(flatten([for c in try(g.criteria, []) : try(c.member_groups, [])])) > 0
  ]

  base_groups      = { for k, g in local.groups : k => g if !contains(local.composite_group_keys, k) }
  composite_groups = { for k, g in local.groups : k => g if contains(local.composite_group_keys, k) }

  group_paths = merge(module.base_groups.paths, module.composite_groups.paths)

  # --- services -----------------------------------------------------------
  service_files = fileset("${local.data_root}/services", "*.yaml")
  service_docs  = [for f in local.service_files : yamldecode(file("${local.data_root}/services/${f}"))]

  predefined_services = merge([for d in local.service_docs : try(d.predefined, {})]...)
  custom_services_all = merge([for d in local.service_docs : try(d.custom, {})]...)
  custom_services     = { for k, v in local.custom_services_all : k => v if try(v.owner, "gm") == "lm" }

  service_paths = merge(
    { for k, s in data.nsxt_policy_service.predefined : k => s.path },
    module.services.paths,
  )

  # --- policies -----------------------------------------------------------
  policy_files = fileset("${local.data_root}/policies", "*.yaml")

  policy_docs = {
    for f in local.policy_files :
    trimsuffix(f, ".yaml") => yamldecode(file("${local.data_root}/policies/${f}"))
  }

  policies = {
    for k, d in local.policy_docs : k => d
    if try(d.policy.owner, "lm") == "lm"
    && try(d.policy.rule_management, "standalone") == "standalone"
    && (contains(try(d.policy.sites, []), var.site) || contains(try(d.policy.sites, []), "*"))
  }
}

module "base_groups" {
  source = "../../modules/group"

  groups = local.base_groups
  domain = var.domain
}

module "composite_groups" {
  source = "../../modules/group"

  groups      = local.composite_groups
  domain      = var.domain
  group_paths = module.base_groups.paths
}

data "nsxt_policy_service" "predefined" {
  for_each = local.predefined_services

  display_name = each.value
}

module "services" {
  source = "../../modules/service"

  services = local.custom_services
}

module "policies" {
  source   = "../../modules/dfw-policy"
  for_each = local.policies

  policy        = each.value.policy
  rules         = each.value.rules
  domain        = var.domain
  group_paths   = local.group_paths
  service_paths = local.service_paths
}
SCAFFOLD_EOF

write_file stacks/local-security/outputs.tf <<'SCAFFOLD_EOF'
output "site" {
  description = "Site this state belongs to."
  value       = var.site
}

output "policy_count" {
  description = "Policies managed by this stack at this site."
  value       = length(local.policies)
}

output "rule_count" {
  description = "Total rules at this site. Compare against the plan's count delta before approving."
  value       = sum(concat([0], [for k, m in module.policies : m.rule_count]))
}

output "group_count" {
  description = "Site-local groups managed by this stack."
  value       = length(local.groups)
}
SCAFFOLD_EOF

write_file stacks/local-security/README.md <<'SCAFFOLD_EOF'
# stack: local-security

Site-local DFW exceptions. **One state per Local Manager.**

- Cadence: weekly. Blast radius: one site. Approver: site owner.
- Consumes `data/policies/*.yaml` and `data/groups/*.yaml` entries marked
  `owner: lm` whose `sites` list contains this site (or `"*"`).

GM and LM policies coexist within the same categories. Confirm the exact
precedence between GM and LM sections for your NSX version before relying on
cross-boundary rule ordering — do not assume it.

```bash
make plan STACK=local-security SITE=lon1
```
SCAFFOLD_EOF

# --- stacks/local-network --------------------------------------------------

write_file stacks/local-network/providers.tf <<'SCAFFOLD_EOF'
provider "nsxt" {
  max_retries     = 4
  retry_min_delay = 200
  retry_max_delay = 1000
}
SCAFFOLD_EOF

write_file stacks/local-network/variables.tf <<'SCAFFOLD_EOF'
variable "site" {
  description = "Site id of the Local Manager this run targets. Must match a key in inventory/managers.yaml."
  type        = string
}

variable "data_root" {
  description = "Location of the data/ tree relative to this stack."
  type        = string
  default     = "../../data"
}
SCAFFOLD_EOF

write_file stacks/local-network/main.tf <<'SCAFFOLD_EOF'
# local-network — segments and tier-1 gateways for one site. One state per LM.
#
# Separate from local-security because the cadences differ and a DFW edit must
# never refresh network objects.

locals {
  data_file = "${path.module}/${var.data_root}/network/${var.site}.yaml"
  # Both branches must be the same type, so the fallback is an empty YAML
  # document rather than an empty object: a conditional whose branches differ
  # in type fails at plan time on exactly the sites that do have a data file.
  data = yamldecode(fileexists(local.data_file) ? file(local.data_file) : "{}")

  tier1s   = try(local.data.tier1s, {})
  segments = try(local.data.segments, {})
}

module "tier1" {
  source = "../../modules/tier1"

  tier1s = local.tier1s
}

module "segment" {
  source = "../../modules/segment"

  segments    = local.segments
  tier1_paths = module.tier1.paths
}
SCAFFOLD_EOF

write_file stacks/local-network/outputs.tf <<'SCAFFOLD_EOF'
output "site" {
  description = "Site this state belongs to."
  value       = var.site
}

output "segment_paths" {
  description = "Logical segment name => NSX policy path."
  value       = module.segment.paths
}

output "tier1_paths" {
  description = "Logical tier-1 name => NSX policy path."
  value       = module.tier1.paths
}
SCAFFOLD_EOF

write_file stacks/local-network/README.md <<'SCAFFOLD_EOF'
# stack: local-network

Segments and tier-1 gateways for one site. **One state per Local Manager.**

- Cadence: weekly. Blast radius: one site. Approver: network owner.
- Reads `data/network/<site>.yaml`. A site with no such file plans clean and
  manages nothing.

Segment tags are set here because segments are Terraform-owned. Those tags are
what lets a group select workloads by subnet without embedding a CIDR.
SCAFFOLD_EOF

# --- stacks/platform -------------------------------------------------------

write_file stacks/platform/providers.tf <<'SCAFFOLD_EOF'
provider "nsxt" {
  max_retries     = 4
  retry_min_delay = 500
  retry_max_delay = 2000
}
SCAFFOLD_EOF

write_file stacks/platform/variables.tf <<'SCAFFOLD_EOF'
variable "site" {
  description = "Site id of the Local Manager this run targets. Must match a key in inventory/managers.yaml."
  type        = string
}

variable "data_root" {
  description = "Location of the data/ tree relative to this stack."
  type        = string
  default     = "../../data"
}
SCAFFOLD_EOF

write_file stacks/platform/main.tf <<'SCAFFOLD_EOF'
# platform — tier-0 gateways and the objects underneath them, for one site.
#
# The slowest and most dangerous state in the estate. Every change here is
# RESTRICTED: change advisory, named approver, rollback plan, out-of-hours.
# Nothing with a daily cadence may ever be added to this stack.

locals {
  data_file = "${path.module}/${var.data_root}/platform/${var.site}.yaml"
  # Both branches must be the same type, so the fallback is an empty YAML
  # document rather than an empty object: a conditional whose branches differ
  # in type fails at plan time on exactly the sites that do have a data file.
  data = yamldecode(fileexists(local.data_file) ? file(local.data_file) : "{}")

  tier0s = try(local.data.tier0s, {})
}

module "tier0" {
  source = "../../modules/tier0"

  tier0s = local.tier0s
}
SCAFFOLD_EOF

write_file stacks/platform/outputs.tf <<'SCAFFOLD_EOF'
output "site" {
  description = "Site this state belongs to."
  value       = var.site
}

output "tier0_paths" {
  description = "Logical tier-0 name => NSX policy path."
  value       = module.tier0.paths
}
SCAFFOLD_EOF

write_file stacks/platform/README.md <<'SCAFFOLD_EOF'
# stack: platform

Tier-0 gateways, and in time transport zones and edge clusters, for one site.
**One state per Local Manager.**

- Cadence: rarely. Blast radius: one site, total. Approver: change advisory.
- Reads `data/platform/<site>.yaml`.

Every change here is **restricted**. Automation may prepare one; it may
never apply one.
SCAFFOLD_EOF

# ---------------------------------------------------------------------------
# 6. Tooling
# ---------------------------------------------------------------------------

write_file scripts/preflight.sh <<'SCAFFOLD_EOF'
#!/usr/bin/env bash
# Report which tools this repository needs and which are present. Read-only.

set -uo pipefail

status=0

check() {
	local name="$1" why="$2" required="$3"
	if command -v "$name" >/dev/null 2>&1; then
		printf '  ok       %-12s %s\n' "$name" "$($name --version 2>/dev/null | head -1)"
	elif [ "$required" = required ]; then
		printf '  MISSING  %-12s %s\n' "$name" "$why"
		status=1
	else
		printf '  absent   %-12s %s (optional)\n' "$name" "$why"
	fi
}

echo "tools"
check terraform "plan and apply" required
check python3 "data validation and the CI matrix" required
check git "everything" required
check curl "fetching credentials from Vault or SDDC Manager" optional
check tflint "extra Terraform linting" optional

echo
echo "repository"
for f in inventory/managers.yaml data/schema/tag-scopes.yaml Makefile; do
	if [ -e "$f" ]; then
		printf '  ok       %s\n' "$f"
	else
		printf '  MISSING  %s\n' "$f"
		status=1
	fi
done

if [ -n "$(find stacks -name '.terraform.lock.hcl' -print -quit 2>/dev/null)" ]; then
	printf '  ok       provider lock files present\n'
else
	printf '  absent   no .terraform.lock.hcl yet — run terraform init in a stack and commit it\n'
fi

echo
if [ "$status" = 0 ]; then
	echo "preflight passed"
else
	echo "preflight found missing requirements"
fi
exit "$status"
SCAFFOLD_EOF
mark_executable scripts/preflight.sh

write_file scripts/tf.sh <<'SCAFFOLD_EOF'
#!/usr/bin/env bash
#
# Terraform wrapper: one stack, one manager, one state.
#
#   scripts/tf.sh init   <stack> <site>
#   scripts/tf.sh plan   <stack> <site>
#   scripts/tf.sh show   <stack> <site>
#   scripts/tf.sh apply  <stack> <site>     # requires APPROVE=yes
#
# Credentials are never read from a file here. Either they are already in the
# environment as NSXT_MANAGER_HOST / NSXT_USERNAME / NSXT_PASSWORD, or you wrap
# the call:
#
#   scripts/with-credentials.sh lon1 -- scripts/tf.sh plan local-security lon1

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PARALLELISM="${PARALLELISM:-5}"

usage() {
	sed -n '3,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
	exit "${1:-1}"
}

[ $# -ge 3 ] || usage 1

cmd="$1"
stack="$2"
site="$3"
shift 3

stack_dir="$REPO_ROOT/stacks/$stack"
backend_file="$REPO_ROOT/envs/${site}.backend.hcl"
plan_file="$stack_dir/tfplan"

[ -d "$stack_dir" ] || {
	echo "error: no such stack: $stack" >&2
	exit 1
}
[ -f "$backend_file" ] || {
	echo "error: missing backend config: envs/${site}.backend.hcl" >&2
	exit 1
}

# Site and domain come from the inventory, so a manager is added by editing data.
eval "$(python3 "$REPO_ROOT/scripts/ci-matrix.py" --export "$site")"

export TF_VAR_site="$site"
export TF_VAR_domain="${TF_VAR_domain:-${NSX_DOMAIN:-default}}"
export TF_IN_AUTOMATION=1

# global-security takes no site variable; the other stacks require one.
if [ "$stack" = global-security ]; then
	unset TF_VAR_site
fi

run() {
	echo "+ terraform $*" >&2
	(cd "$stack_dir" && terraform "$@")
}

# One state per stack per manager. While the stacks are on the placeholder local
# backend, the path is derived here so two stacks at the same site cannot end up
# sharing one state file.
uses_local_backend() { grep -q 'backend "local"' "$stack_dir/backend.tf" 2>/dev/null; }

backend_args=(-backend-config="$backend_file")
if uses_local_backend; then
	mkdir -p "$REPO_ROOT/.local-state"
	backend_args+=(-backend-config="path=$REPO_ROOT/.local-state/${site}-${stack}.tfstate")
fi

case "$cmd" in
init)
	run init -reconfigure "${backend_args[@]}" "$@"
	;;
plan)
	[ -d "$stack_dir/.terraform" ] || run init -reconfigure "${backend_args[@]}"
	run plan -out=tfplan -parallelism="$PARALLELISM" -input=false "$@"
	echo
	echo "plan written to stacks/$stack/tfplan — a sensitive artifact, not a PR attachment."
	echo "review it with: scripts/tf.sh show $stack $site"
	;;
show)
	[ -f "$plan_file" ] || {
		echo "error: no saved plan. Run: scripts/tf.sh plan $stack $site" >&2
		exit 1
	}
	run show tfplan
	;;
apply)
	[ -f "$plan_file" ] || {
		echo "error: no saved plan. Never run a bare apply — it re-plans and can execute something nobody reviewed." >&2
		exit 1
	}
	if [ "${APPROVE:-}" != yes ]; then
		echo "error: apply requires an explicit human decision. Re-run with APPROVE=yes after reviewing the plan." >&2
		exit 1
	fi
	if uses_local_backend && [ "${ALLOW_LOCAL_STATE:-}" != 1 ]; then
		echo "error: stack $stack is still on the placeholder local backend. State carries the security posture of the estate and needs a remote, encrypted, locked backend before any real apply. Set ALLOW_LOCAL_STATE=1 only for a lab." >&2
		exit 1
	fi
	run apply -parallelism="$PARALLELISM" -input=false tfplan
	rm -f "$plan_file"
	;;
*)
	usage 1
	;;
esac
SCAFFOLD_EOF
mark_executable scripts/tf.sh

write_file scripts/with-credentials.sh <<'SCAFFOLD_EOF'
#!/usr/bin/env bash
#
# Fetch NSX credentials and hand them to a command as environment variables.
#
#   scripts/with-credentials.sh <site> -- <command> [args...]
#
# The chain is: SDDC Manager API -> Vault -> environment -> terraform. Nothing
# is written to disk, to a Terraform variable, or to state. Reasons, in short:
#
#   * The vault_* Terraform data sources write the fetched secret into state in
#     plaintext. Never fetch a secret inside Terraform.
#   * TF_VAR_* values that reach a provider or resource argument land in state
#     and in saved plan files. 'sensitive = true' only redacts CLI output.
#
# Source of the secret, chosen with --from (default: vault):
#
#   --from vault   read the KV v2 secret at the vault_path in the inventory.
#                  Needs VAULT_ADDR and VAULT_TOKEN in the environment.
#   --from vcf     ask SDDC Manager for the current NSX credentials.
#                  Needs SDDC_MANAGER_HOST, SDDC_USERNAME, SDDC_PASSWORD.
#
# Prefer short-lived credentials: Vault dynamic secrets or a rotated VCF service
# account beats a long-lived password in a KV store. Where VCF can issue client
# certificates, NSXT_CLIENT_AUTH_CERT is stronger than any password path.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE=vault

die() {
	echo "error: $*" >&2
	exit 1
}

[ $# -ge 1 ] || die "usage: with-credentials.sh <site> [--from vault|vcf] -- <command>"

SITE="$1"
shift

while [ $# -gt 0 ]; do
	case "$1" in
	--from)
		SOURCE="${2:-}"
		shift 2
		;;
	--)
		shift
		break
		;;
	*) die "unexpected argument: $1" ;;
	esac
done

[ $# -ge 1 ] || die "no command given after --"

command -v curl >/dev/null 2>&1 || die "curl is required"

# Inventory lookup: host and vault path for this site. Never the secret.
eval "$(python3 "$REPO_ROOT/scripts/ci-matrix.py" --export "$SITE")"
[ -n "${NSX_HOST:-}" ] || die "site '$SITE' is not in inventory/managers.yaml"

export NSXT_MANAGER_HOST="$NSX_HOST"

# Keep the session alive across requests — materially faster on large plans.
export NSXT_SESSION_AUTH="${NSXT_SESSION_AUTH:-true}"

json_get() { python3 -c 'import json,sys; d=json.load(sys.stdin)
for k in sys.argv[1:]:
    d = d[int(k)] if isinstance(d, list) else d[k]
print(d)' "$@"; }

case "$SOURCE" in
vault)
	[ -n "${VAULT_ADDR:-}" ] || die "VAULT_ADDR is not set"
	[ -n "${VAULT_TOKEN:-}" ] || die "VAULT_TOKEN is not set"
	[ -n "${NSX_VAULT_PATH:-}" ] || die "no vault_path recorded for site '$SITE'"

	# KV v2: /v1/<mount>/data/<path>. The inventory records the full path.
	response="$(curl -sS --fail-with-body \
		-H "X-Vault-Token: $VAULT_TOKEN" \
		"${VAULT_ADDR%/}/v1/${NSX_VAULT_PATH#/}")" ||
		die "vault read failed for $NSX_VAULT_PATH"

	NSXT_USERNAME="$(printf '%s' "$response" | json_get data data username)"
	NSXT_PASSWORD="$(printf '%s' "$response" | json_get data data password)"
	;;
vcf)
	[ -n "${SDDC_MANAGER_HOST:-}" ] || die "SDDC_MANAGER_HOST is not set"
	[ -n "${SDDC_USERNAME:-}" ] || die "SDDC_USERNAME is not set"
	[ -n "${SDDC_PASSWORD:-}" ] || die "SDDC_PASSWORD is not set"

	token="$(curl -sS --fail-with-body \
		-X POST "https://${SDDC_MANAGER_HOST}/v1/tokens" \
		-H 'Content-Type: application/json' \
		-d "$(python3 -c 'import json,os;print(json.dumps({"username":os.environ["SDDC_USERNAME"],"password":os.environ["SDDC_PASSWORD"]}))')" |
		json_get accessToken)" || die "SDDC Manager authentication failed"

	creds="$(curl -sS --fail-with-body \
		-H "Authorization: Bearer $token" \
		"https://${SDDC_MANAGER_HOST}/v1/credentials?resourceType=NSXT_MANAGER")" ||
		die "credential lookup failed"

	read -r NSXT_USERNAME NSXT_PASSWORD <<<"$(printf '%s' "$creds" | NSX_HOST="$NSX_HOST" python3 -c '
import json, os, sys
want = os.environ["NSX_HOST"].lower()
for e in json.load(sys.stdin).get("elements", []):
    res = e.get("resource", {})
    names = {str(res.get(k, "")).lower() for k in ("resourceName", "resourceIp", "resourceFqdn")}
    if want in names and e.get("accountType") in (None, "SYSTEM", "USER"):
        print(e["username"], e["password"])
        break
else:
    sys.exit("no NSX credential for " + want)
')" || die "no SDDC Manager credential matches $NSX_HOST"
	;;
*) die "unknown --from source: $SOURCE (vault|vcf)" ;;
esac

[ -n "${NSXT_USERNAME:-}" ] || die "no username retrieved"
[ -n "${NSXT_PASSWORD:-}" ] || die "no password retrieved"
export NSXT_USERNAME NSXT_PASSWORD

exec "$@"
SCAFFOLD_EOF
mark_executable scripts/with-credentials.sh

write_file scripts/ci-matrix.py <<'SCAFFOLD_EOF'
#!/usr/bin/env python3
"""Derive the run matrix from inventory/managers.yaml.

Adding an eleventh Local Manager is a data change, not a code change: CI reads
its matrix from here, and so does scripts/tf.sh.

  scripts/ci-matrix.py                      # JSON matrix, every stack
  scripts/ci-matrix.py --stack local-security
  scripts/ci-matrix.py --format lines
  scripts/ci-matrix.py --export lon1        # shell exports for one manager
"""

from __future__ import annotations

import argparse
import json
import shlex
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from yamlcompat import load_yaml  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent
INVENTORY = REPO_ROOT / "inventory" / "managers.yaml"

GM_STACKS = ["global-security"]
LM_STACKS = ["local-security", "local-network", "platform"]


def managers() -> dict:
    if not INVENTORY.exists():
        sys.exit(f"error: {INVENTORY} does not exist")
    doc = load_yaml(INVENTORY.read_text()) or {}
    return doc.get("managers") or {}


def entries(stack_filter: str | None) -> list[dict]:
    out = []
    for name, m in sorted(managers().items()):
        if m.get("enabled") is False:
            continue
        role = m.get("role", "lm")
        allowed = m.get("stacks") or (GM_STACKS if role == "gm" else LM_STACKS)
        for stack in allowed:
            if stack_filter and stack != stack_filter:
                continue
            out.append(
                {
                    "site": name,
                    "stack": stack,
                    "role": role,
                    "host": m.get("host", ""),
                    "tier": m.get("tier", ""),
                    "vcf_instance": m.get("vcf_instance", ""),
                }
            )
    return out


def export(site: str) -> int:
    m = managers().get(site)
    if not m:
        print(f"error: site {site!r} is not in inventory/managers.yaml", file=sys.stderr)
        return 1
    pairs = {
        "NSX_HOST": m.get("host", ""),
        "NSX_ROLE": m.get("role", "lm"),
        "NSX_SITE": site,
        "NSX_TIER": m.get("tier", ""),
        "NSX_VAULT_PATH": m.get("vault_path", ""),
        "NSX_DOMAIN": m.get("domain", "default"),
        "NSX_VCF_INSTANCE": m.get("vcf_instance", ""),
    }
    for key, value in pairs.items():
        print(f"export {key}={shlex.quote(str(value))}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--stack", help="only include this stack")
    ap.add_argument("--format", choices=["json", "github", "lines"], default="json")
    ap.add_argument("--export", metavar="SITE", help="print shell exports for one manager")
    args = ap.parse_args()

    if args.export:
        return export(args.export)

    rows = entries(args.stack)
    if args.format == "lines":
        for r in rows:
            print(f"{r['site']}\t{r['stack']}\t{r['role']}\t{r['host']}")
    elif args.format == "github":
        print(json.dumps({"include": rows}))
    else:
        print(json.dumps(rows, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
SCAFFOLD_EOF
mark_executable scripts/ci-matrix.py

write_file scripts/yamlcompat.py <<'SCAFFOLD_EOF'
"""YAML loading with no mandatory third-party dependency.

PyYAML is used when it is importable. When it is not, a parser for the subset of
YAML this repository actually commits takes over: block mappings, block and flow
sequences, quoted and plain scalars, folded and literal block scalars, comments.

The fallback exists so that 'make validate' works on a laptop with nothing
installed. Terraform itself parses these files with yamldecode, which is a full
YAML implementation, so the fallback never has to be authoritative — it only has
to agree on the subset we write.
"""

from __future__ import annotations

import re
from typing import Any

try:  # pragma: no cover - environment dependent
    import yaml as _pyyaml
except ImportError:  # pragma: no cover
    _pyyaml = None


def load_yaml(text: str) -> Any:
    if _pyyaml is not None:
        return _pyyaml.safe_load(text)
    return _Parser(text).parse()


class YamlError(ValueError):
    pass


_INT = re.compile(r"^[+-]?\d+$")
_FLOAT = re.compile(r"^[+-]?(\d+\.\d*|\.\d+)([eE][+-]?\d+)?$")


class _Parser:
    def __init__(self, text: str) -> None:
        self.lines: list[tuple[int, str, int]] = []
        for lineno, raw in enumerate(text.splitlines(), 1):
            self.lines.append((_indent(raw), raw, lineno))
        self.raw_text = text
        self.pos = 0

    # -- line helpers ------------------------------------------------------
    def _skip(self) -> None:
        while self.pos < len(self.lines):
            _, raw, _ = self.lines[self.pos]
            stripped = raw.strip()
            if not stripped or stripped.startswith("#") or stripped in ("---", "..."):
                self.pos += 1
            else:
                return

    def _peek(self):
        self._skip()
        if self.pos >= len(self.lines):
            return None
        return self.lines[self.pos]

    def parse(self) -> Any:
        value = self._parse_block(0)
        self._skip()
        if self.pos < len(self.lines):
            _, raw, lineno = self.lines[self.pos]
            raise YamlError(f"line {lineno}: unexpected content {raw.strip()!r}")
        return value

    def _parse_block(self, indent: int) -> Any:
        entry = self._peek()
        if entry is None:
            return None
        cur_indent, raw, _ = entry
        if cur_indent < indent:
            return None
        if raw.strip().startswith("- "):
            return self._parse_sequence(cur_indent)
        if raw.strip() == "-":
            return self._parse_sequence(cur_indent)
        return self._parse_mapping(cur_indent)

    def _parse_mapping(self, indent: int) -> dict:
        result: dict[str, Any] = {}
        while True:
            entry = self._peek()
            if entry is None:
                break
            cur_indent, raw, lineno = entry
            if cur_indent < indent:
                break
            if cur_indent > indent:
                raise YamlError(f"line {lineno}: unexpected indentation")
            content = _strip_comment(raw.strip())
            if content.startswith("- "):
                break
            key, sep, rest = _split_key(content)
            if not sep:
                raise YamlError(f"line {lineno}: expected 'key: value', got {content!r}")
            self.pos += 1
            result[key] = self._parse_value(rest.strip(), indent, lineno)
        return result

    def _parse_sequence(self, indent: int) -> list:
        items: list[Any] = []
        while True:
            entry = self._peek()
            if entry is None:
                break
            cur_indent, raw, lineno = entry
            if cur_indent < indent:
                break
            content = _strip_comment(raw.strip())
            if not content.startswith("-"):
                break
            if cur_indent > indent:
                raise YamlError(f"line {lineno}: unexpected indentation in sequence")
            rest = content[1:].strip()
            self.pos += 1
            if not rest:
                items.append(self._parse_block(indent + 1))
                continue
            key, sep, tail = _split_key(rest)
            if sep:
                # Inline mapping start: '- key: value', continuation lines are
                # indented past the dash.
                item: dict[str, Any] = {}
                item[key] = self._parse_value(tail.strip(), cur_indent + 2, lineno)
                nested = self._peek()
                if nested is not None and nested[0] > cur_indent:
                    item.update(self._parse_mapping(nested[0]))
                items.append(item)
            else:
                items.append(_scalar(rest))
        return items

    def _parse_value(self, rest: str, indent: int, lineno: int) -> Any:
        if rest in ("|", "|-", "|+", ">", ">-", ">+"):
            return self._parse_block_scalar(rest, indent)
        if rest == "":
            entry = self._peek()
            if entry is None or entry[0] <= indent:
                return None
            return self._parse_block(entry[0])
        return _scalar(rest)

    def _parse_block_scalar(self, marker: str, indent: int) -> str:
        collected: list[str] = []
        block_indent = None
        while self.pos < len(self.lines):
            cur_indent, raw, _ = self.lines[self.pos]
            if raw.strip() == "":
                collected.append("")
                self.pos += 1
                continue
            if cur_indent <= indent:
                break
            if block_indent is None:
                block_indent = cur_indent
            collected.append(raw[block_indent:])
            self.pos += 1
        while collected and collected[-1] == "":
            collected.pop()
        if marker.startswith("|"):
            text = "\n".join(collected)
        else:
            folded: list[str] = []
            for line in collected:
                if line == "":
                    folded.append("\n")
                elif folded and folded[-1] not in ("", "\n"):
                    folded[-1] = folded[-1] + " " + line
                else:
                    folded.append(line)
            text = "".join(p if p == "\n" else p for p in folded)
        if marker.endswith("-"):
            return text
        return text + "\n"


def _indent(raw: str) -> int:
    return len(raw) - len(raw.lstrip(" "))


def _strip_comment(text: str) -> str:
    out = []
    quote = None
    i = 0
    while i < len(text):
        ch = text[i]
        if quote:
            out.append(ch)
            if ch == quote:
                quote = None
        elif ch in "'\"":
            quote = ch
            out.append(ch)
        elif ch == "#" and (i == 0 or text[i - 1] == " "):
            break
        else:
            out.append(ch)
        i += 1
    return "".join(out).rstrip()


def _split_key(text: str) -> tuple[str, bool, str]:
    quote = None
    for i, ch in enumerate(text):
        if quote:
            if ch == quote:
                quote = None
            continue
        if ch in "'\"":
            quote = ch
            continue
        if ch == ":" and (i + 1 == len(text) or text[i + 1] in " \t"):
            return _unquote(text[:i].strip()), True, text[i + 1 :]
    return text, False, ""


def _unquote(text: str) -> str:
    if len(text) >= 2 and text[0] == text[-1] and text[0] in "'\"":
        return text[1:-1]
    return text


def _scalar(text: str) -> Any:
    text = text.strip()
    if text.startswith("[") and text.endswith("]"):
        inner = text[1:-1].strip()
        if not inner:
            return []
        return [_scalar(p) for p in _split_flow(inner)]
    if text.startswith("{") and text.endswith("}"):
        inner = text[1:-1].strip()
        if not inner:
            return {}
        out = {}
        for part in _split_flow(inner):
            key, sep, value = _split_key(part)
            if not sep:
                raise YamlError(f"bad flow mapping entry: {part!r}")
            out[key] = _scalar(value)
        return out
    if len(text) >= 2 and text[0] == text[-1] and text[0] in "'\"":
        return text[1:-1]
    lowered = text.lower()
    if lowered in ("true", "yes", "on"):
        return True
    if lowered in ("false", "no", "off"):
        return False
    if lowered in ("null", "~", ""):
        return None
    if _INT.match(text):
        return int(text)
    if _FLOAT.match(text):
        return float(text)
    return text


def _split_flow(text: str) -> list[str]:
    parts: list[str] = []
    depth = 0
    quote = None
    current: list[str] = []
    for ch in text:
        if quote:
            current.append(ch)
            if ch == quote:
                quote = None
            continue
        if ch in "'\"":
            quote = ch
            current.append(ch)
        elif ch in "[{":
            depth += 1
            current.append(ch)
        elif ch in "]}":
            depth -= 1
            current.append(ch)
        elif ch == "," and depth == 0:
            parts.append("".join(current).strip())
            current = []
        else:
            current.append(ch)
    if current:
        parts.append("".join(current).strip())
    return [p for p in parts if p]
SCAFFOLD_EOF

write_file scripts/validate-data.py <<'SCAFFOLD_EOF'
#!/usr/bin/env python3
"""Validate everything under data/ and inventory/ before any plan runs.

This is the cheapest place to catch a malformed rule, and the last place before
it reaches a live firewall. It runs offline: no credentials, no network, no
Terraform.

Two layers:

  * structure — the JSON Schemas in data/schema/ are evaluated directly, so the
    schemas an editor uses and the schemas CI enforces are the same files.
  * meaning   — the things a schema cannot express: that a Global Manager policy
    only references Global Manager groups, that sequence numbers do not collide,
    that every tag scope is in the vocabulary, that no raw policy path or secret
    has been pasted into a data file.

  scripts/validate-data.py           # errors fail, warnings are printed
  scripts/validate-data.py --strict  # warnings fail too
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from yamlcompat import load_yaml  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent
DATA = REPO_ROOT / "data"
SCHEMA_DIR = DATA / "schema"
INVENTORY = REPO_ROOT / "inventory" / "managers.yaml"

SECRET_KEYS = {"password", "passwd", "secret", "token", "api_key", "apikey", "credential", "private_key"}
FUZZY_OPERATORS = {"CONTAINS", "STARTSWITH", "ENDSWITH", "MATCHES"}


class Report:
    def __init__(self) -> None:
        self.errors: list[str] = []
        self.warnings: list[str] = []

    def error(self, where: str, message: str) -> None:
        self.errors.append(f"{where}: {message}")

    def warn(self, where: str, message: str) -> None:
        self.warnings.append(f"{where}: {message}")


# --------------------------------------------------------------------------
# JSON Schema subset: exactly the keywords used by data/schema/*.json.
# --------------------------------------------------------------------------

def check_schema(instance, schema: dict, where: str, path: str, report: Report) -> None:
    def fail(message: str) -> None:
        report.error(where, f"{path or '<root>'}: {message}")

    expected = schema.get("type")
    if expected and not _type_ok(instance, expected):
        fail(f"expected {expected}, got {_type_name(instance)}")
        return

    if "enum" in schema and instance not in schema["enum"]:
        fail(f"{instance!r} is not one of {', '.join(map(str, schema['enum']))}")

    if isinstance(instance, str):
        if "minLength" in schema and len(instance) < schema["minLength"]:
            fail("must not be empty")
        pattern = schema.get("pattern")
        if pattern and not re.match(pattern, instance):
            fail(f"{instance!r} does not match {pattern}")

    if isinstance(instance, int) and not isinstance(instance, bool):
        if "minimum" in schema and instance < schema["minimum"]:
            fail(f"must be >= {schema['minimum']}, got {instance}")

    if isinstance(instance, list):
        if "minItems" in schema and len(instance) < schema["minItems"]:
            fail(f"needs at least {schema['minItems']} item(s)")
        item_schema = schema.get("items")
        if item_schema:
            for i, item in enumerate(instance):
                check_schema(item, item_schema, where, f"{path}[{i}]", report)

    if isinstance(instance, dict):
        if "minProperties" in schema and len(instance) < schema["minProperties"]:
            fail(f"needs at least {schema['minProperties']} entr(ies)")

        for key in schema.get("required", []):
            if key not in instance or instance[key] is None:
                fail(f"missing required key {key!r}")

        names = schema.get("propertyNames", {}).get("pattern")
        properties = schema.get("properties", {})
        additional = schema.get("additionalProperties", True)

        for key, value in instance.items():
            child = f"{path}.{key}" if path else key
            if names and key not in properties and not re.match(names, str(key)):
                fail(f"key {key!r} does not match {names}")
            if key in properties:
                check_schema(value, properties[key], where, child, report)
            elif isinstance(additional, dict):
                check_schema(value, additional, where, child, report)
            elif additional is False:
                fail(f"unknown key {key!r}")


def _type_ok(instance, expected: str) -> bool:
    if expected == "object":
        return isinstance(instance, dict)
    if expected == "array":
        return isinstance(instance, list)
    if expected == "string":
        return isinstance(instance, str)
    if expected == "integer":
        return isinstance(instance, int) and not isinstance(instance, bool)
    if expected == "number":
        return isinstance(instance, (int, float)) and not isinstance(instance, bool)
    if expected == "boolean":
        return isinstance(instance, bool)
    return True


def _type_name(instance) -> str:
    return {dict: "object", list: "array", str: "string", bool: "boolean", int: "integer"}.get(
        type(instance), type(instance).__name__
    )


# --------------------------------------------------------------------------
# Loading
# --------------------------------------------------------------------------

def load_schema(name: str) -> dict | None:
    path = SCHEMA_DIR / name
    if not path.exists():
        return None
    return json.loads(path.read_text())


def load_docs(subdir: str, report: Report) -> dict[Path, dict]:
    directory = DATA / subdir
    docs: dict[Path, dict] = {}
    if not directory.is_dir():
        return docs
    for path in sorted(directory.glob("*.yaml")):
        try:
            doc = load_yaml(path.read_text())
        except Exception as exc:  # noqa: BLE001 - report, do not crash the run
            report.error(_rel(path), f"unparseable YAML: {exc}")
            continue
        if doc is None:
            report.warn(_rel(path), "file is empty")
            continue
        if not isinstance(doc, dict):
            report.error(_rel(path), "top level must be a mapping")
            continue
        docs[path] = doc
    return docs


def _rel(path: Path) -> str:
    try:
        return str(path.relative_to(REPO_ROOT))
    except ValueError:
        return str(path)


def walk_strings(value, trail: str = ""):
    if isinstance(value, dict):
        for key, item in value.items():
            yield from walk_strings(item, f"{trail}.{key}" if trail else str(key))
    elif isinstance(value, list):
        for i, item in enumerate(value):
            yield from walk_strings(item, f"{trail}[{i}]")
    elif isinstance(value, str):
        yield trail, value


# --------------------------------------------------------------------------
# Checks
# --------------------------------------------------------------------------

def check_no_raw_paths(where: str, doc: dict, report: Report) -> None:
    for trail, value in walk_strings(doc):
        if value.startswith("/infra/") or value.startswith("/global-infra/"):
            report.error(
                where,
                f"{trail}: raw policy path {value!r}. Reference groups and services by "
                "logical name; the module resolves them to paths.",
            )


def check_no_secrets(where: str, doc: dict, report: Report) -> None:
    def walk(node, trail: str) -> None:
        if isinstance(node, dict):
            for key, value in node.items():
                child = f"{trail}.{key}" if trail else str(key)
                if str(key).lower() in SECRET_KEYS:
                    report.error(
                        where,
                        f"{child}: looks like a credential. Nothing sensitive is ever "
                        "committed — record the Vault path, never the secret.",
                    )
                walk(value, child)
        elif isinstance(node, list):
            for i, item in enumerate(node):
                walk(item, f"{trail}[{i}]")

    walk(doc, "")


def check_inventory(report: Report) -> dict:
    if not INVENTORY.exists():
        report.error("inventory/managers.yaml", "missing. Every stack run resolves its manager here.")
        return {}
    try:
        doc = load_yaml(INVENTORY.read_text()) or {}
    except Exception as exc:  # noqa: BLE001
        report.error("inventory/managers.yaml", f"unparseable YAML: {exc}")
        return {}

    where = "inventory/managers.yaml"
    schema = load_schema("managers.schema.json")
    if schema:
        check_schema(doc, schema, where, "", report)
    check_no_secrets(where, doc, report)

    managers = doc.get("managers") or {}
    gms = [k for k, m in managers.items() if m.get("role") == "gm"]
    if not gms:
        report.warn(where, "no Global Manager listed. The global-security stack has nothing to target.")
    elif len(gms) > 1:
        report.warn(
            where,
            f"{len(gms)} Global Managers listed ({', '.join(sorted(gms))}). More than one "
            "federation means global-security is several states, not one — open decision 7.",
        )

    for name, m in managers.items():
        role = m.get("role")
        for stack in m.get("stacks") or []:
            if role == "gm" and stack != "global-security":
                report.error(where, f"{name}: a Global Manager cannot run the {stack} stack.")
            if role == "lm" and stack == "global-security":
                report.error(where, f"{name}: global-security runs against the GM, not a Local Manager.")
        backend = REPO_ROOT / "envs" / f"{name}.backend.hcl"
        if m.get("enabled") is not False and not backend.exists():
            report.warn(where, f"{name}: no envs/{name}.backend.hcl — nothing can initialise for this manager.")

    return managers


def check_tag_scopes(report: Report) -> dict:
    path = SCHEMA_DIR / "tag-scopes.yaml"
    if not path.exists():
        report.error("data/schema/tag-scopes.yaml", "missing. The tag vocabulary is a contract, not an option.")
        return {}
    try:
        doc = load_yaml(path.read_text()) or {}
    except Exception as exc:  # noqa: BLE001
        report.error("data/schema/tag-scopes.yaml", f"unparseable YAML: {exc}")
        return {}
    return doc.get("scopes") or {}


def check_tag_value(where: str, label: str, member_type: str, value: str, scopes: dict, report: Report) -> None:
    if "|" not in value:
        report.warn(
            where,
            f"{label}: tag {value!r} has no scope. Scope every tag as 'scope|value' so the "
            "vocabulary can be enforced.",
        )
        return
    scope, _, tag_value = value.partition("|")
    if scope not in scopes:
        report.error(
            where,
            f"{label}: tag scope {scope!r} is not in data/schema/tag-scopes.yaml. Adding a "
            "scope is a reviewed change; a typo here silently empties the group.",
        )
        return
    spec = scopes[scope] or {}
    allowed = spec.get("values")
    if allowed and tag_value not in allowed:
        report.error(where, f"{label}: {tag_value!r} is not a permitted value for scope {scope!r} ({', '.join(allowed)})")
    applies = spec.get("applies_to")
    if applies and member_type and member_type not in applies:
        report.warn(where, f"{label}: scope {scope!r} is documented for {', '.join(applies)}, not {member_type}")


def check_groups(docs: dict[Path, dict], scopes: dict, sites: set[str], report: Report) -> dict[str, dict]:
    schema = load_schema("group.schema.json")
    groups: dict[str, dict] = {}
    origin: dict[str, str] = {}

    for path, doc in docs.items():
        where = _rel(path)
        if schema:
            check_schema(doc, schema, where, "", report)
        check_no_raw_paths(where, doc, report)

        for name, group in (doc.get("groups") or {}).items():
            if not isinstance(group, dict):
                continue
            if name in groups:
                report.error(where, f"group {name!r} is also defined in {origin[name]}. Group names are unique estate-wide.")
                continue
            groups[name] = group
            origin[name] = where

            owner = group.get("owner")
            group_sites = group.get("sites") or []
            if owner == "gm" and group_sites:
                report.error(where, f"{name}: a Global Manager group has no site list; its span comes from its domain.")
            if owner == "lm" and not group_sites:
                report.error(where, f"{name}: a site-local group must list the sites it is created on.")
            for site in group_sites:
                if site != "*" and site not in sites:
                    report.error(where, f"{name}: site {site!r} is not in inventory/managers.yaml")

            criteria = group.get("criteria") or []
            static = any(c.get("ip_addresses") for c in criteria if isinstance(c, dict))
            if static and not group.get("why_static"):
                report.error(
                    where,
                    f"{name}: static membership needs a why_static note saying what would let it "
                    "become dynamic. Nothing updates a static group when the estate changes.",
                )
            if len(criteria) > 1 and not group.get("conjunction"):
                report.error(where, f"{name}: {len(criteria)} criteria blocks need an explicit conjunction (AND/OR).")

            for i, criterion in enumerate(criteria):
                if not isinstance(criterion, dict):
                    continue
                for j, condition in enumerate(criterion.get("conditions") or []):
                    label = f"{name}.criteria[{i}].conditions[{j}]"
                    operator = condition.get("operator")
                    if operator in FUZZY_OPERATORS:
                        report.warn(
                            where,
                            f"{label}: {operator} on a tag acquires unintended members — "
                            "'app|payments' also matches 'app|payments-test'. Prefer EQUALS.",
                        )
                    if condition.get("key") == "Tag":
                        check_tag_value(where, label, condition.get("member_type", ""), str(condition.get("value", "")), scopes, report)

    # Nested membership: the stacks resolve groups in two passes, so a composite
    # group may only reference a base group.
    composite = {
        name
        for name, g in groups.items()
        if any(isinstance(c, dict) and c.get("member_groups") for c in (g.get("criteria") or []))
    }
    for name in sorted(composite):
        for criterion in groups[name].get("criteria") or []:
            for member in (criterion.get("member_groups") or []) if isinstance(criterion, dict) else []:
                target = origin.get(name, "data/groups")
                if member == name:
                    report.error(target, f"{name}: references itself.")
                elif member not in groups:
                    report.error(target, f"{name}: member_groups references undefined group {member!r}")
                elif member in composite:
                    report.error(
                        target,
                        f"{name}: references {member!r}, which itself nests groups. The stacks "
                        "resolve nested groups in two passes only; flatten one level.",
                    )
                elif groups[member].get("owner") != groups[name].get("owner"):
                    report.error(target, f"{name} ({groups[name].get('owner')}) nests {member!r} ({groups[member].get('owner')}) — that crosses the GM/LM boundary.")

    return groups


def check_services(docs: dict[Path, dict], report: Report) -> dict[str, dict]:
    schema = load_schema("service.schema.json")
    services: dict[str, dict] = {}
    origin: dict[str, str] = {}

    for path, doc in docs.items():
        where = _rel(path)
        if schema:
            check_schema(doc, schema, where, "", report)
        check_no_raw_paths(where, doc, report)

        for name, display in (doc.get("predefined") or {}).items():
            if name in services:
                report.error(where, f"service {name!r} is also defined in {origin[name]}")
                continue
            services[name] = {"kind": "predefined", "display_name": display, "owner": None}
            origin[name] = where

        for name, service in (doc.get("custom") or {}).items():
            if name in services:
                report.error(where, f"service {name!r} is also defined in {origin[name]}")
                continue
            if not (service.get("l4_port_set") or service.get("icmp")):
                report.error(where, f"service {name!r} has no entries — it would match nothing.")
            services[name] = {"kind": "custom", "owner": service.get("owner", "gm")}
            origin[name] = where

    return services


def check_policies(
    docs: dict[Path, dict],
    groups: dict[str, dict],
    services: dict[str, dict],
    sites: set[str],
    report: Report,
) -> None:
    schema = load_schema("policy.schema.json")
    seen_ids: dict[str, str] = {}

    for path, doc in docs.items():
        where = _rel(path)
        if schema:
            check_schema(doc, schema, where, "", report)
        check_no_raw_paths(where, doc, report)

        policy = doc.get("policy") or {}
        rules = doc.get("rules") or {}
        owner = policy.get("owner")
        policy_id = policy.get("id")
        policy_sites = policy.get("sites") or []

        if policy_id:
            if policy_id in seen_ids:
                report.error(where, f"policy id {policy_id!r} is also used in {seen_ids[policy_id]}")
            seen_ids[policy_id] = where

        if owner == "lm" and not policy_sites:
            report.error(where, "a site-local policy must list the sites it applies to.")
        if owner == "gm" and policy_sites:
            report.error(where, "a Global Manager policy has no site list; its span comes from its domain.")
        for site in policy_sites:
            if site != "*" and site not in sites:
                report.error(where, f"site {site!r} is not in inventory/managers.yaml")

        if policy.get("category") == "Emergency":
            report.warn(
                where,
                "Emergency category. This is a RESTRICTED change class — change advisory, "
                "named approver, rollback plan, out-of-hours.",
            )

        if policy.get("rule_management") == "inline" and len(rules) > 8:
            report.warn(
                where,
                f"{len(rules)} rules managed inline. Inline blocks rewrite the whole policy on "
                "every change; use rule_management: standalone for anything with churn.",
            )

        def resolve_group(name: str, label: str) -> None:
            if name == "ANY":
                return
            group = groups.get(name)
            if group is None:
                report.error(where, f"{label}: references undefined group {name!r}")
                return
            if owner == "gm" and group.get("owner") != "gm":
                report.error(
                    where,
                    f"{label}: a Global Manager policy references site-local group {name!r}. "
                    "Federation cannot span an LM group; create it on the GM.",
                )
            if owner == "lm" and group.get("owner") == "lm":
                missing = [s for s in policy_sites if s != "*" and s not in (group.get("sites") or []) and "*" not in (group.get("sites") or [])]
                if missing:
                    report.error(where, f"{label}: group {name!r} does not exist at site(s) {', '.join(missing)}")
            if owner == "lm" and group.get("owner") == "gm":
                report.warn(
                    where,
                    f"{label}: a site-local policy references GM-owned group {name!r}. Confirm "
                    "your NSX version lets a Local Manager policy consume a GM group before relying on it.",
                )

        for name in policy.get("scope") or []:
            resolve_group(name, "policy.scope")

        sequence_numbers: dict[int, str] = {}
        for key, rule in rules.items():
            if not isinstance(rule, dict):
                continue
            label = f"rules.{key}"

            seq = rule.get("sequence_number")
            if isinstance(seq, int):
                if seq in sequence_numbers:
                    report.error(where, f"{label}: sequence_number {seq} already used by {sequence_numbers[seq]}. Sequence numbers are allocated, not guessed.")
                sequence_numbers[seq] = label
                if seq % 100 != 0:
                    report.warn(where, f"{label}: sequence_number {seq} is not a multiple of 100. Gaps are what let a rule be inserted later without renumbering.")

            for field in ("source_groups", "destination_groups", "scope"):
                for name in rule.get(field) or []:
                    resolve_group(name, f"{label}.{field}")

            for name in rule.get("services") or []:
                if name == "ANY":
                    continue
                service = services.get(name)
                if service is None:
                    report.error(where, f"{label}.services: references undefined service {name!r}")
                elif owner == "gm" and service["kind"] == "custom" and service.get("owner") != "gm":
                    report.error(where, f"{label}.services: {name!r} is a site-local service; a GM policy cannot reference it.")

            if rule.get("action") in ("DROP", "REJECT") and rule.get("logged") is False:
                report.warn(where, f"{label}: a drop with logging off is invisible during an incident.")

            if not (rule.get("source_groups") or rule.get("destination_groups")):
                report.warn(where, f"{label}: neither source nor destination is set — this matches everything in scope.")


def check_site_files(subdir: str, schema_name: str, scopes: dict, sites: set[str], report: Report) -> None:
    schema = load_schema(schema_name)
    directory = DATA / subdir
    if not directory.is_dir():
        return

    for path in sorted(directory.glob("*.yaml")):
        where = _rel(path)
        try:
            doc = load_yaml(path.read_text()) or {}
        except Exception as exc:  # noqa: BLE001
            report.error(where, f"unparseable YAML: {exc}")
            continue
        if schema:
            check_schema(doc, schema, where, "", report)
        check_no_raw_paths(where, doc, report)

        site = doc.get("site")
        if site and site != path.stem:
            report.error(where, f"site {site!r} does not match the filename; the stack loads data/{subdir}/<site>.yaml")
        if site and sites and site not in sites:
            report.error(where, f"site {site!r} is not in inventory/managers.yaml")

        tier1s = doc.get("tier1s") or {}
        for name, segment in (doc.get("segments") or {}).items():
            if not isinstance(segment, dict):
                continue
            tier1 = segment.get("tier1")
            if tier1 and tier1 not in tier1s:
                report.error(where, f"segment {name!r} connects to undefined tier1 {tier1!r}")
            for i, tag in enumerate(segment.get("tags") or []):
                check_tag_value(where, f"segments.{name}.tags[{i}]", "Segment", f"{tag.get('scope')}|{tag.get('tag')}", scopes, report)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--strict", action="store_true", help="treat warnings as failures")
    ap.add_argument("--quiet", action="store_true", help="print only the summary")
    args = ap.parse_args()

    report = Report()

    managers = check_inventory(report)
    sites = set(managers.keys())
    scopes = check_tag_scopes(report)

    group_docs = load_docs("groups", report)
    service_docs = load_docs("services", report)
    policy_docs = load_docs("policies", report)

    groups = check_groups(group_docs, scopes, sites, report)
    services = check_services(service_docs, report)
    check_policies(policy_docs, groups, services, sites, report)
    check_site_files("network", "network.schema.json", scopes, sites, report)
    check_site_files("platform", "platform.schema.json", scopes, sites, report)

    if not args.quiet:
        for message in report.warnings:
            print(f"warning  {message}")
        for message in report.errors:
            print(f"ERROR    {message}")
        if report.warnings or report.errors:
            print()

    print(
        f"checked {len(managers)} manager(s), {len(groups)} group(s), "
        f"{len(services)} service(s), {len(policy_docs)} policy file(s): "
        f"{len(report.errors)} error(s), {len(report.warnings)} warning(s)"
    )

    if report.errors:
        return 1
    if args.strict and report.warnings:
        print("--strict: warnings are failures")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
SCAFFOLD_EOF
mark_executable scripts/validate-data.py

# ---------------------------------------------------------------------------
# 7. Backend config and CI
# ---------------------------------------------------------------------------

write_file envs/example.backend.hcl.example <<'SCAFFOLD_EOF'
# Partial backend configuration for one manager. Copy to envs/<site>.backend.hcl
# and fill in. The file name must match the manager key in
# inventory/managers.yaml — scripts/tf.sh finds it that way.
#
#   terraform init -backend-config=envs/<site>.backend.hcl
#
# The backend type is an open decision (docs/ARCHITECTURE.md section 14.1). Whatever is
# chosen must give: encryption at rest, state locking, and access restricted to
# the pipeline identity. State carries the full security posture of the estate.

# While the stacks are on the placeholder local backend this file holds nothing:
# scripts/tf.sh supplies the state path itself, so two stacks at the same site
# cannot collide on one state file.

# --- example: s3 (replace backend "local" with backend "s3" in the stack) ---
# bucket         = "nsx-terraform-state"
# key            = "example/global-security.tfstate"
# region         = "eu-west-2"
# dynamodb_table = "nsx-terraform-locks"
# kms_key_id     = "alias/nsx-terraform"
# encrypt        = true

# --- example: azurerm ------------------------------------------------------
# resource_group_name  = "rg-terraform-state"
# storage_account_name = "sttfstatensx"
# container_name       = "state"
# key                  = "example/global-security.tfstate"
SCAFFOLD_EOF

write_file .github/workflows/validate.yml <<'SCAFFOLD_EOF'
# Runs on every pull request. No credentials, no network access to any manager:
# everything here is offline validation of the data and the HCL.
name: validate

on:
  pull_request:
  push:
    branches: [main]

permissions:
  contents: read

jobs:
  data:
    name: data schemas
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.11"
      - name: Validate data/ and inventory/
        run: python3 scripts/validate-data.py

  terraform:
    name: terraform fmt and validate
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: "1.9.8"
      - name: Format check
        run: terraform fmt -recursive -check -diff .
      - name: Validate each stack
        run: |
          set -euo pipefail
          for stack in stacks/*/; do
            echo "::group::${stack}"
            terraform -chdir="${stack}" init -backend=false -input=false
            terraform -chdir="${stack}" validate
            echo "::endgroup::"
          done
SCAFFOLD_EOF

write_file .github/workflows/plan.yml <<'SCAFFOLD_EOF'
# Plan every manager in the inventory, in parallel, with read-only credentials.
#
# The matrix comes from inventory/managers.yaml, so an eleventh Local Manager is
# a data change rather than a workflow change. Sites are independent: one site
# failing does not block the others.
#
# Before this can run, the repository owner must configure the secrets referenced
# below and decide the state backend (docs/ARCHITECTURE.md section 14).
name: plan

on:
  pull_request:
  workflow_dispatch:

permissions:
  contents: read
  pull-requests: write

jobs:
  matrix:
    name: build matrix
    runs-on: ubuntu-latest
    outputs:
      matrix: ${{ steps.build.outputs.matrix }}
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.11"
      - id: build
        run: echo "matrix=$(python3 scripts/ci-matrix.py --format github)" >> "$GITHUB_OUTPUT"

  plan:
    name: ${{ matrix.stack }} @ ${{ matrix.site }}
    needs: matrix
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      max-parallel: 4
      matrix: ${{ fromJson(needs.matrix.outputs.matrix) }}
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: "1.9.8"

      - name: Plan
        env:
          # The plan identity is read-only. Only the apply workflow gets write
          # access — that is what makes it safe to plan on every pull request.
          VAULT_ADDR: ${{ secrets.VAULT_ADDR }}
          VAULT_TOKEN: ${{ secrets.VAULT_PLAN_TOKEN }}
        run: |
          scripts/with-credentials.sh "${{ matrix.site }}" -- \
            scripts/tf.sh plan "${{ matrix.stack }}" "${{ matrix.site }}"

      - name: Render plan summary
        run: |
          # The saved plan is a sensitive artifact. Post the rendered summary,
          # never the plan file itself.
          scripts/tf.sh show "${{ matrix.stack }}" "${{ matrix.site }}" \
            | tee "$GITHUB_STEP_SUMMARY" >/dev/null
SCAFFOLD_EOF

write_file .github/pull_request_template.md <<'SCAFFOLD_EOF'
## What changed

<!-- One site or one application per PR. A PR spanning multiple sites cannot be
     rolled back cleanly. -->

## Change class

- [ ] **Routine** — rule added/removed in an existing policy, or a member added
      to a static group
- [ ] **Elevated** — new policy or category, new or changed group criteria, new
      segment, new tag scope
- [ ] **Restricted** — default rule, Emergency category, tag scope rename or
      removal, GM↔LM ownership move, anything in `platform`

Ticket:

## Plan review

- [ ] The resource **count delta** matches the intent
- [ ] **No unexpected destroys** — a destroy on an untouched rule means keys shifted
- [ ] No change to the **default rule** and none to the Emergency category
- [ ] Every new or changed rule has a **non-empty `scope`**
- [ ] Group criteria changes: **membership blast radius** checked in NSX *before* approval
- [ ] Sequence numbers do not collide and preserve intended ordering
- [ ] The change touches **one site's state**, unless deliberately global

## Rollback
SCAFFOLD_EOF

write_file inventory/README.md <<'SCAFFOLD_EOF'
# inventory

`managers.yaml` is the single registry of every NSX manager in the estate. It is
the only place a manager is declared: CI derives its run matrix from it,
`scripts/tf.sh` resolves host and domain from it, and
`scripts/with-credentials.sh` reads the Vault **path** from it.

It never contains a secret. `vault_path` records where the credential lives, not
what it is; `scripts/validate-data.py` fails the build if a key that looks like a
credential appears here.

## Adding a manager

1. Add the entry below the others, keyed by a short stable id (`lon1`, `nyc1`).
   That id is the site name used everywhere else — data files, backend config,
   CI job names.
2. Create `envs/<id>.backend.hcl`.
3. Store the credential in Vault at the recorded path.

Nothing else. If adding a manager requires editing Terraform code, the
abstraction is wrong.

## Fields

| Field | Meaning |
|---|---|
| `role` | `gm` (Global Manager) or `lm` (Local Manager) |
| `host` | Manager FQDN, exported as `NSXT_MANAGER_HOST` |
| `site` | Physical site this manager serves |
| `region` | Grouping for reporting |
| `vcf_instance` | Which VCF instance / SDDC Manager owns it |
| `sddc_manager` | SDDC Manager FQDN, for the VCF credential lookup |
| `vault_path` | Vault path holding the credential. Path only. |
| `tier` | `prod`, `preprod`, `nonprod`, `lab` |
| `domain` | NSX domain. On a GM, a domain id or site id — set it explicitly. |
| `stacks` | Which stacks run against this manager. Defaults by role. |
| `enabled` | Set `false` to drop a manager out of the CI matrix without deleting it |
SCAFFOLD_EOF

if [ "$WITH_EXAMPLES" = 1 ]; then

	write_file inventory/managers.yaml <<'SCAFFOLD_EOF'
# The single registry of every NSX manager in the estate.
#
# Paths, never secrets. See inventory/README.md.
#
# The entries below are a worked example with realistic shape — replace the
# hostnames, sites and Vault paths with the real estate. Delete any manager that
# does not exist rather than leaving it disabled.

managers:
  gm1:
    role: gm
    host: nsx-gm-01.example.internal
    site: lon1
    region: emea
    vcf_instance: vcf-lon-01
    sddc_manager: sddc-lon-01.example.internal
    vault_path: nsx/data/managers/gm1
    tier: prod
    domain: global
    stacks: [global-security]
    description: Global Manager. Owns the federated DFW for the whole estate.

  lon1:
    role: lm
    host: nsx-lm-lon-01.example.internal
    site: lon1
    region: emea
    vcf_instance: vcf-lon-01
    sddc_manager: sddc-lon-01.example.internal
    vault_path: nsx/data/managers/lon1
    tier: prod
    domain: default

  nyc1:
    role: lm
    host: nsx-lm-nyc-01.example.internal
    site: nyc1
    region: amer
    vcf_instance: vcf-nyc-01
    sddc_manager: sddc-nyc-01.example.internal
    vault_path: nsx/data/managers/nyc1
    tier: prod
    domain: default

  fra1:
    role: lm
    host: nsx-lm-fra-01.example.internal
    site: fra1
    region: emea
    vcf_instance: vcf-fra-01
    sddc_manager: sddc-fra-01.example.internal
    vault_path: nsx/data/managers/fra1
    tier: preprod
    domain: default
SCAFFOLD_EOF

	for site in gm1 lon1 nyc1 fra1; do
		printf '# Partial backend configuration for %s.\n#\n# The backend type is an open decision (docs/ARCHITECTURE.md section 14.1). While the\n# stacks are on the placeholder local backend, scripts/tf.sh supplies the state\n# path itself and this file holds nothing. Once the backend is chosen, put its\n# per-manager settings here — see envs/example.backend.hcl.example.\n' "$site" |
			write_file "envs/${site}.backend.hcl"
	done

	write_file data/groups/payments.yaml <<'SCAFFOLD_EOF'
# Groups for the payments application.
#
# Federated groups omit the site element of the naming convention on purpose:
# they span every site, so <env>-<app>-<role> is the whole name.
#
# Membership is dynamic. The tags these criteria match are written by the system
# that provisions the workload — this repository only consumes them.

groups:
  prod-payments-all:
    display_name: prod-payments-all
    description: Every payments workload in production. Used as Apply To for the policy.
    owner: gm
    criteria:
      - conditions:
          - key: Tag
            member_type: VirtualMachine
            operator: EQUALS
            value: "app|payments"
          - key: Tag
            member_type: VirtualMachine
            operator: EQUALS
            value: "env|prod"

  prod-payments-web:
    display_name: prod-payments-web
    owner: gm
    criteria:
      - conditions:
          - key: Tag
            member_type: VirtualMachine
            operator: EQUALS
            value: "app|payments"
          - key: Tag
            member_type: VirtualMachine
            operator: EQUALS
            value: "env|prod"
          - key: Tag
            member_type: VirtualMachine
            operator: EQUALS
            value: "tier|web"

  prod-payments-app:
    display_name: prod-payments-app
    owner: gm
    criteria:
      - conditions:
          - key: Tag
            member_type: VirtualMachine
            operator: EQUALS
            value: "app|payments"
          - key: Tag
            member_type: VirtualMachine
            operator: EQUALS
            value: "env|prod"
          - key: Tag
            member_type: VirtualMachine
            operator: EQUALS
            value: "tier|app"

  prod-payments-db:
    display_name: prod-payments-db
    owner: gm
    criteria:
      - conditions:
          - key: Tag
            member_type: VirtualMachine
            operator: EQUALS
            value: "app|payments"
          - key: Tag
            member_type: VirtualMachine
            operator: EQUALS
            value: "env|prod"
          - key: Tag
            member_type: VirtualMachine
            operator: EQUALS
            value: "tier|db"

  prod-payments-segments:
    display_name: prod-payments-segments
    description: >
      Subnet-based membership. Matches the segment tag rather than a CIDR: the
      segment is Terraform-owned, so its tags are reliable, and a CIDR here would
      be a duplicated fact that drifts from the segment's real definition.
    owner: gm
    criteria:
      - conditions:
          - key: Tag
            member_type: Segment
            operator: EQUALS
            value: "app|payments"
SCAFFOLD_EOF

	write_file data/groups/infrastructure.yaml <<'SCAFFOLD_EOF'
# Shared infrastructure groups and the quarantine mechanism.

groups:
  prod-lb:
    display_name: prod-lb
    description: Physical load balancer VIPs in front of production.
    owner: gm
    why_static: >
      Physical appliances with no VM object in NSX, so no tag can be applied to
      them. This becomes dynamic if the appliances are replaced by virtual
      editions that the provisioning system tags.
    criteria:
      - ip_addresses:
          - 10.10.0.10
          - 10.10.0.11
          - 10.20.0.10

  corp-dns:
    display_name: corp-dns
    description: Corporate DNS resolvers.
    owner: gm
    why_static: >
      Managed outside VCF by the platform team; not VM workloads in any of these
      managers. Becomes dynamic if DNS moves onto tagged VCF workloads.
    criteria:
      - ip_addresses:
          - 10.0.0.53
          - 10.0.1.53

  quarantine-active:
    display_name: quarantine-active
    description: >
      Incident response. Membership is one tag on a VM, applied by an operator —
      no Terraform run, no PR, no plan. Terraform owns the mechanism, not the
      act of quarantining.
    owner: gm
    criteria:
      - conditions:
          - key: Tag
            member_type: VirtualMachine
            operator: EQUALS
            value: "quarantine|active"

  lon1-legacy-hosts:
    display_name: prod-lon1-legacy-hosts
    description: Pre-VCF hosts at lon1 that predate the tagging estate.
    owner: lm
    sites: [lon1]
    why_static: >
      These workloads are not in the CMDB and nothing tags them. They become
      dynamic once the lon1 migration completes and the CMDB sync owns them.
    criteria:
      - ip_addresses:
          - 10.31.14.0/24

  lon1-app-frontend:
    display_name: prod-lon1-app-frontend
    description: Site-local frontend workloads at lon1.
    owner: lm
    sites: [lon1]
    criteria:
      - conditions:
          - key: Tag
            member_type: VirtualMachine
            operator: EQUALS
            value: "zone|dmz"
          - key: Tag
            member_type: VirtualMachine
            operator: EQUALS
            value: "env|prod"
SCAFFOLD_EOF

	write_file data/services/common.yaml <<'SCAFFOLD_EOF'
# Services referenced by rules, by logical name.
#
# 'predefined' names are looked up in NSX rather than recreated, so there is one
# definition of HTTPS in the estate instead of one per repository.

predefined:
  https: HTTPS
  http: HTTP
  ssh: SSH
  dns-udp: DNS-UDP
  ntp: NTP

custom:
  payments-api:
    display_name: payments-api
    description: Payments service API listener.
    owner: gm
    l4_port_set:
      - protocol: TCP
        destination_ports: ["8443"]

  payments-db:
    display_name: payments-db
    description: Payments database listener.
    owner: gm
    l4_port_set:
      - protocol: TCP
        destination_ports: ["5432"]
SCAFFOLD_EOF

	write_file data/policies/payments.yaml <<'SCAFFOLD_EOF'
# Payments application policy. Federated: owned by the Global Manager.
#
# Adding a rule here is a routine change — edit this file, run 'make validate',
# open a PR. No HCL changes.
#
# Map keys are the stable identity. 'web-from-lb' is the Terraform address:
# changing a value updates the rule in place, renaming the key destroys and
# recreates it. Never renumber keys.

policy:
  id: prod-payments
  name: prod-payments
  description: East-west policy for the payments application.
  category: Application
  owner: gm
  sequence_number: 1000
  rule_management: standalone
  # Apply To. Mandatory: without it every rule below is pushed to every
  # hypervisor in the federation span.
  scope: [prod-payments-all]

rules:
  web-from-lb:
    name: web-from-lb
    sequence_number: 100
    action: ALLOW
    direction: IN
    source_groups: [prod-lb]
    destination_groups: [prod-payments-web]
    services: [https]
    scope: [prod-payments-web]
    logged: true

  app-from-web:
    name: app-from-web
    sequence_number: 200
    action: ALLOW
    direction: IN
    source_groups: [prod-payments-web]
    destination_groups: [prod-payments-app]
    services: [payments-api]
    scope: [prod-payments-app]
    logged: true

  db-from-app:
    name: db-from-app
    sequence_number: 300
    action: ALLOW
    direction: IN
    source_groups: [prod-payments-app]
    destination_groups: [prod-payments-db]
    services: [payments-db]
    scope: [prod-payments-db]
    logged: true

  # Policy-level deny. This is not the DFW default rule — that one is never
  # touched by a routine change.
  deny-other:
    name: deny-other
    description: Anything not allowed above is dropped inside the application.
    sequence_number: 900
    action: DROP
    direction: IN_OUT
    source_groups: [ANY]
    destination_groups: [prod-payments-all]
    scope: [prod-payments-all]
    logged: true
SCAFFOLD_EOF

	write_file data/policies/infrastructure-baseline.yaml <<'SCAFFOLD_EOF'
# Estate-wide infrastructure services. Federated.

policy:
  id: infra-baseline
  name: infra-baseline
  description: DNS and NTP to the corporate resolvers, everywhere.
  category: Infrastructure
  owner: gm
  sequence_number: 100
  rule_management: standalone
  scope: [prod-payments-all]

rules:
  dns-to-corp:
    name: dns-to-corp
    sequence_number: 100
    action: ALLOW
    direction: OUT
    source_groups: [prod-payments-all]
    destination_groups: [corp-dns]
    services: [dns-udp]
    scope: [prod-payments-all]
    logged: false

  ntp-to-corp:
    name: ntp-to-corp
    sequence_number: 200
    action: ALLOW
    direction: OUT
    source_groups: [prod-payments-all]
    destination_groups: [corp-dns]
    services: [ntp]
    scope: [prod-payments-all]
    logged: false
SCAFFOLD_EOF

	write_file data/policies/emergency-quarantine.yaml <<'SCAFFOLD_EOF'
# Standing quarantine mechanism. RESTRICTED — changes here go through change
# advisory with a named approver.
#
# The point of this policy is that using it requires no Terraform run at all:
# incident response applies the tag 'quarantine|active' to a VM and the group
# picks it up. Incident response must not depend on a pipeline being healthy.
#
# Terraform owns the mechanism. Operators use it without Terraform in the loop.

policy:
  id: emergency-quarantine
  name: emergency-quarantine
  description: Isolate any workload tagged quarantine|active.
  category: Emergency
  owner: gm
  sequence_number: 10
  rule_management: standalone
  scope: [quarantine-active]

rules:
  quarantine-in:
    name: quarantine-in
    sequence_number: 100
    action: DROP
    direction: IN
    source_groups: [ANY]
    destination_groups: [quarantine-active]
    scope: [quarantine-active]
    logged: true

  quarantine-out:
    name: quarantine-out
    sequence_number: 200
    action: DROP
    direction: OUT
    source_groups: [quarantine-active]
    destination_groups: [ANY]
    scope: [quarantine-active]
    logged: true
SCAFFOLD_EOF

	write_file data/policies/lon1-legacy.yaml <<'SCAFFOLD_EOF'
# Site-local exception at lon1. Owned by the Local Manager, not the GM.
#
# Everything referenced here is site-local: a Local Manager policy and a
# federated group are on opposite sides of the ownership boundary.

policy:
  id: lon1-legacy
  name: prod-lon1-legacy
  description: Temporary allowance for pre-VCF hosts at lon1 during migration.
  category: Application
  owner: lm
  sites: [lon1]
  sequence_number: 2000
  rule_management: standalone
  scope: [lon1-app-frontend]

rules:
  frontend-from-legacy:
    name: frontend-from-legacy
    description: Remove when the lon1 migration completes.
    sequence_number: 100
    action: ALLOW
    direction: IN
    source_groups: [lon1-legacy-hosts]
    destination_groups: [lon1-app-frontend]
    services: [https]
    scope: [lon1-app-frontend]
    logged: true
SCAFFOLD_EOF

	write_file data/network/lon1.yaml <<'SCAFFOLD_EOF'
# Segments and tier-1 gateways at lon1. Consumed by the local-network stack.
#
# Segment tags are set here because segments are Terraform-owned infrastructure.
# Those tags are what lets a group select workloads by subnet without hardcoding
# a CIDR into group criteria.

site: lon1

tier1s:
  t1-payments:
    display_name: prod-lon1-payments-t1
    tier0_display_name: prod-lon1-t0
    edge_cluster_display_name: edge-cluster-lon1
    failover_mode: NON_PREEMPTIVE
    route_advertisement_types:
      - TIER1_CONNECTED
    tags:
      - scope: app
        tag: payments
      - scope: env
        tag: prod

segments:
  seg-payments-web:
    display_name: prod-lon1-payments-web
    tier1: t1-payments
    transport_zone_display_name: overlay-tz-lon1
    subnets:
      - cidr: 10.30.1.1/24
    tags:
      - scope: app
        tag: payments
      - scope: env
        tag: prod
      - scope: zone
        tag: dmz

  seg-payments-db:
    display_name: prod-lon1-payments-db
    tier1: t1-payments
    transport_zone_display_name: overlay-tz-lon1
    subnets:
      - cidr: 10.30.3.1/24
    tags:
      - scope: app
        tag: payments
      - scope: env
        tag: prod
      - scope: zone
        tag: internal
SCAFFOLD_EOF

	write_file data/platform/lon1.yaml <<'SCAFFOLD_EOF'
# Platform objects at lon1. RESTRICTED — change advisory, named approver,
# rollback plan, out-of-hours. Nothing with a daily cadence belongs in this file.

site: lon1

tier0s:
  t0-lon1:
    display_name: prod-lon1-t0
    ha_mode: ACTIVE_ACTIVE
    failover_mode: NON_PREEMPTIVE
    edge_cluster_display_name: edge-cluster-lon1
    transit_subnets:
      - 100.64.0.0/16
    bgp:
      enabled: true
      local_as_num: "65001"
      ecmp: true
    tags:
      - scope: env
        tag: prod
SCAFFOLD_EOF

fi # WITH_EXAMPLES

# ---------------------------------------------------------------------------
# 8. Finish
# ---------------------------------------------------------------------------

# Leave a copy of this script in the scaffold, so the tree it produces can
# regenerate and update itself without reaching back to wherever it came from.
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
if [ -f "$SELF" ] && [ "$SELF" != "$ROOT/scripts/bootstrap.sh" ]; then
	write_file scripts/bootstrap.sh <"$SELF"
	mark_executable scripts/bootstrap.sh
fi

if [ "$DRY_RUN" != 1 ]; then
	for f in $EXECUTABLES; do
		[ -e "$ROOT/$f" ] && chmod +x "$ROOT/$f"
	done
fi

if [ "$WITH_GIT" = 1 ] && [ "$DRY_RUN" != 1 ]; then
	if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
		log ""
		log "git: already a working tree, left alone"
	else
		log ""
		git -C "$ROOT" init -q
		log "git: initialised a repository in $ROOT"
	fi
fi

log ""
log "summary"
log "  created   $created"
log "  updated   $updated"
log "  unchanged $unchanged"
[ "$skipped" -gt 0 ] && log "  skipped   $skipped (existing files with different content)"

if [ "$DRY_RUN" = 1 ]; then
	log ""
	log "dry run — nothing was written."
	exit 0
fi

if [ "$QUIET" != 1 ]; then
	cat <<'NEXT'

next steps
  1. make preflight              check the tools this repository needs
  2. make validate               schema + convention checks, offline
  3. Edit inventory/managers.yaml so it describes the real estate, and add one
     envs/<site>.backend.hcl per manager.
  4. Decide the state backend and replace the placeholder in stacks/*/backend.tf.
     The local backend is not acceptable for a real manager.
  5. terraform init in one stack, then commit the generated .terraform.lock.hcl.

what still needs a human decision (docs/ARCHITECTURE.md section 14)
  * state backend, encryption and locking
  * Vault mount, path convention, and auth method for the pipeline
  * whether Application category is GM-owned or delegated per site
  * which site is the brownfield import pilot
NEXT
fi

if [ "$skipped" -gt 0 ]; then
	exit 2
fi
exit 0
