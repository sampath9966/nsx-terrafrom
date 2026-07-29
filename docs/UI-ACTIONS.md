# Actions that must be done in the GitHub web UI

Everything else in this repository is automatable. These four are not: the git
proxy in use refuses ref deletions (`git push origin --delete` returns
`the remote end hung up unexpectedly`), and pull request titles and bodies live
in GitHub's database rather than in the repository, so no amount of history
rewriting reaches them.

Each item below is the last remaining place the old naming survives. None of
them affect the code.

Repository: <https://github.com/sampath9966/nsx-terrafrom>

---

## 1. Delete the two stale `claude/*` branches

These are the last references of that kind attached to the repository. Both are
fully merged or abandoned — nothing is lost by deleting them.

| Branch | Status |
|---|---|
| `claude/dynamic-folder-setup-script-4lve68` | Superseded. Its commits are on `main` via `PR1785271899`. |
| `claude/claude-md-docs-rts2s5` | Abandoned leftover from an earlier session. |

**Steps**

1. Open <https://github.com/sampath9966/nsx-terrafrom/branches>
2. Select **All branches**.
3. Find each branch in the list.
4. Click the **🗑 (trash can)** icon at the right of its row.
5. Confirm.

If a branch shows as *protected* and the trash icon is greyed out, remove the
protection first at **Settings → Branches → Branch protection rules**, delete
the branch, then restore the rule.

**Verify** — this should list only `main` and `PR<epoch>` branches:

```bash
git ls-remote --heads origin
```

---

## 2. Retitle pull request #1

Its title still reads `Add CLAUDE.md: architecture and conventions for
multi-VCF NSX Federation`. The merged commit on `main` has already been
rewritten to say `docs/ARCHITECTURE.md`; only the PR title lags.

**Steps**

1. Open <https://github.com/sampath9966/nsx-terrafrom/pull/1>
2. Click **Edit** next to the title.
3. Replace with:
   `Add docs/ARCHITECTURE.md: architecture and conventions for multi-VCF NSX Federation`
4. Click **Save**.

---

## 3. Edit or delete the body of closed pull request #2

The description references `CLAUDE.md` throughout and carries a generated-by
attribution line. The PR is closed and its branch is being deleted, so the body
has no ongoing purpose.

**Steps** — pick one:

- **Edit**: open <https://github.com/sampath9966/nsx-terrafrom/pull/2>, click
  the **…** menu at the top right of the description, choose **Edit**, and
  replace the text with a one-liner such as
  `Superseded — merged to main via PR1785271899.`
- **Delete**: same **…** menu → **Delete**. GitHub keeps the PR record but drops
  the body.

A closed PR cannot be removed entirely; only its body and comments can be
edited or deleted.

---

## 4. Check the repository description and topics

Set at repository creation, not tracked in git, so worth a glance.

1. Open <https://github.com/sampath9966/nsx-terrafrom>
2. Click the **⚙** next to **About** on the right.
3. Clear anything in **Description** or **Topics** you do not want.

---

## Nothing else is outstanding

For the record, these were handled and need no UI work:

- Every commit on every branch — file contents, commit messages, and author and
  committer identities — audited clean.
- `CLAUDE.md` renamed to `docs/ARCHITECTURE.md` in every historical version, not
  just the current one.
- `LICENSE` carries the owner and repository name.
- This clone's git identity is pinned so future commits cannot pick up a
  default from the environment.
