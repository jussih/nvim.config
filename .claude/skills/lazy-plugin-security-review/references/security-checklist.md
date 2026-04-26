# Supply-Chain Security Checklist for Neovim Plugin Diffs

Walk through each category below with the diff open. For each pattern, search the diff (e.g. `grep`, `rg`, or visual scan) and note any hits. Most hits will be benign — you are building a list of things for a human to consciously accept, not a list of accusations.

Categories roughly descend from "most likely to be compromise evidence" to "worth glancing at."

## 1. Arbitrary code execution primitives

Plugins are already code, so these are not automatically suspicious — but *newly introduced* calls to them, or calls whose *input* comes from a remote source, deserve attention.

Lua primitives:
- `loadstring(...)` — evaluates a string as Lua code. Malicious use: eval remotely-fetched payload.
- `load(...)` — same as above with more options.
- `dofile(path)` — executes an external Lua file. Watch for `dofile` of paths outside the plugin's own directory.
- `require(modname)` with a dynamically constructed `modname` — can be used to load unexpected modules.

Shell-out primitives:
- `os.execute(cmd)` — runs a shell command, returns exit status.
- `io.popen(cmd)` — runs a shell command, captures output.
- `vim.fn.system(cmd)` / `vim.fn.systemlist(cmd)` — Neovim's blocking shell runner.
- `vim.system({...})` — Neovim's non-blocking shell runner (0.10+).
- `vim.fn.jobstart(cmd)` / `vim.loop.spawn(...)` / `vim.uv.spawn(...)` — async process spawn.

**What to flag:**
- A *new* call to any of the above, especially where the command string is built from input the plugin did not previously control (env vars, config values, URL contents).
- Any pipeline of the form `curl ... | sh`, `wget ... | bash`, or equivalent. This is the classic supply-chain install-script pattern and should always be called out, even when the target URL looks legitimate.
- Any `chmod +x` or `chmod 777` on something just downloaded.

**Common benign cases (note but don't alarm):**
- Calling `git` to check the plugin's own version.
- Calling external tools the plugin is a UI for (e.g. a `ripgrep` wrapper calling `rg`).
- Running a formatter or linter the user has configured.

## 2. Network activity

New network code in a plugin that previously had none is the single strongest signal in this checklist.

Patterns:
- `curl`, `wget`, `http`, `https://` literals in new code paths.
- `vim.fn.system("curl ...")` — covered above but listed here because the destination URL matters.
- Lua `socket.http`, `luasocket`, `plenary.curl`, `http.request`.
- Any mention of `:8080`, `:443`, or other explicit ports in new code.
- WebSocket usage (`wss://`, `ws://`).
- DNS lookup APIs.

**What to flag:**
- Hardcoded URLs to domains that are not the plugin's own GitHub/GitLab/homepage or a well-known CDN for its known assets. Even `pastebin.com`, `transfer.sh`, `discord.com/api/webhooks`, `api.telegram.org` in plugin code are exfiltration patterns to call out by name.
- Any telemetry, analytics, or "phone home" behaviour, even with a benign-sounding justification. Users of a text editor do not expect their plugins to call home.
- DNS-based C2 patterns (looking up a weird hostname for no plausible reason).

**Common benign cases:**
- A plugin whose entire purpose is network (an HTTP client, a GitHub integration) updating its API endpoints.
- Fetching plugin-managed data the user explicitly opted into (e.g. dictionary files for a spellchecker, after the user invokes a command).

## 3. Filesystem access

Look at any new code that reads or writes files outside the plugin's own state directory.

Patterns and paths to watch:
- Reads or globs of:
  - `~/.ssh/`, `~/.aws/`, `~/.config/gh/`, `~/.netrc`, `~/.gnupg/`, `~/.docker/config.json`
  - `~/.bash_history`, `~/.zsh_history`, shell rc files
  - `.env`, `.envrc`, `.env.local`, files matching `*.pem`, `*.key`
  - `/etc/passwd`, `/etc/shadow`, `/etc/hosts`
  - Browser profile directories (Chrome, Firefox credential stores)
  - Crypto wallet paths (`~/.ethereum`, `~/Library/Application Support/Exodus`, etc.)
- Writes to:
  - Shell rc files (`.bashrc`, `.zshrc`, `.profile`) — persistence mechanism.
  - `~/.config/autostart/`, `~/Library/LaunchAgents/`, `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\` — persistence.
  - `crontab` entries, systemd unit files, `~/.config/systemd/user/`.
  - Git hooks directories (`.git/hooks/`).
- Recursive directory walks from `$HOME` or `/` — overly broad file scans are a red flag.

**What to flag:**
- Any read of the paths listed above.
- Any write outside the plugin's expected state locations (usually `stdpath('data')/<plugin>`, `stdpath('cache')/<plugin>`, `stdpath('config')/<plugin>`).
- New file I/O with paths built from `os.getenv("HOME")` plus a sensitive suffix.

**Common benign cases:**
- A plugin that manages the user's notes touching files under a configured notes directory.
- Cache and state writes under the standard Neovim state paths.

## 4. Encoding and obfuscation

Supply-chain attackers commonly hide strings (URLs, command payloads) to evade casual review.

Patterns:
- Long base64-looking strings (`[A-Za-z0-9+/=]{60,}`) in Lua source, especially when immediately followed by a decode call.
- Long hex-encoded strings, especially in `string.char(...)` or `\x..` sequences.
- Dynamic construction of sensitive identifiers from substrings or concatenation (e.g. `"sys" .. "tem"` to hide `system`).
- Minified single-line blobs introduced into a previously readable codebase.
- Bytecode (`string.dump` output) committed as a data file.
- Unusual file types (`.bin`, `.dat`, `.so`, `.dll`) added to a pure-Lua plugin.
- Binary "test fixtures" added to the repo, especially ones that the build or test step reads. (The xz-utils backdoor in 2024 hid its payload in files ostensibly for test inputs — a supposedly-inert test fixture that the build process touches deserves real suspicion.)

**What to flag:**
- Any of the above. Obfuscation has essentially no legitimate reason to appear in a Neovim plugin.

**Common benign cases:**
- Base64 of small image icons (check length and context).
- Test fixtures that intentionally contain encoded data (should be clearly marked as test data).

## 5. Build and install artifacts

lazy.nvim supports `build` commands that run when the plugin is installed or updated. These are a direct code-execution surface.

Patterns in the **plugin spec files** (the user's own config, sometimes bumped alongside the lock):
- New `build = "..."` entries.
- `build` strings that pipe curl or wget into a shell.
- `build` functions that download binaries.

Patterns in the **plugin's own repo**:
- New or modified `Makefile`, `CMakeLists.txt`, `build.sh`, `install.sh`, `configure`.
- New `package.json` scripts (for plugins with a JS/TS build step).
- New Rust `build.rs`, Python `setup.py`/`pyproject.toml` with install hooks.
- New git submodules pointing to third-party repos.
- Downloading precompiled binaries during build.

**What to flag:**
- Any new download-and-execute during build.
- New submodules — report the submodule URL and who owns it.
- Precompiled binaries checked directly into the repo (`.so`, `.dll`, `.dylib`, `.node`).

**Common benign cases:**
- Bumping a build dependency to a newer version with a clear reason.
- Minor Makefile edits that only re-arrange existing commands.

## 6. Identity and metadata changes

These aren't code, but they tell you whether to trust the code.

- Changes to `CODEOWNERS`, `AUTHORS`, `MAINTAINERS`.
- Changes to `.github/workflows/` that alter publish, release, or auth steps.
- Changes to CI secrets usage (`${{ secrets.FOO }}` in new workflows).
- New CI steps that run on every PR (attackers can use this to run code via a malicious PR).
- Changes to branch protection metadata, though these rarely show in the diff directly.

**What to flag:**
- A new name added to `CODEOWNERS` or maintainer files, especially alongside substantive code changes in the same diff range.
- A new workflow step that uses secrets and runs on `pull_request_target`.
- Workflows that install unpinned dependencies during release.

## 7. Dependencies

- `lazy.nvim` plugin dependencies (`dependencies = { ... }` entries) — new dependencies expand the attack surface to those plugins too.
- Added LuaRocks / Rust crates / npm packages / Python packages.
- Pinned-version bumps of existing dependencies, especially to a version that has never been used before.

**What to flag:**
- Any new dependency. Record its name and owner. (You don't need to review *that* dependency's diff too — but the user should know it got added.)
- Un-pinning a previously pinned dependency (e.g. changing `= "1.2.3"` to `>= "1.2"`).

## 8. Credentials and secrets

Any *appearance* of credentials in a diff is worth flagging — even ones that look like test fixtures. Attackers commit real secrets by accident, and attackers commit fake-looking secrets on purpose.

Patterns:
- AWS-style access keys (`AKIA[0-9A-Z]{16}`).
- GitHub tokens (`ghp_`, `gho_`, `ghs_`, `ghu_`, `ghr_` prefixes).
- Generic API-key patterns: long random strings next to `api_key`, `token`, `secret`, `password`, `authorization` identifiers.
- `.pem`, `.key`, or similar key material added to the repo.
- `Bearer ...` or `Basic ...` literal headers in source.

**What to flag:**
- Every hit, even if contextually it looks like a placeholder. Credential leaks are nearly always accidents worth raising upstream.

## 9. Committer and cadence meta-signals

These aren't code either, but they shift the prior you bring to the rest of the review. They run in two directions: some lower confidence, others raise it. Both matter.

### Red-flag signals (lower confidence)

When walking the commit list:

- **Unknown committers.** Run down the commit authors. Is the author of a substantive code change a first-time committer to this repo? Not automatically bad (open source thrives on new contributors), but worth naming when combined with anything else on this list.
- **Force-push / rewritten history.** If the old commit SHA recorded in `lazy-lock.json` is no longer in the branch's history, the maintainer has rewritten history. Possible reasons: mistake cleanup (benign), credential leak cleanup (benign-ish), account compromise erasing evidence (not benign). Always flag this; it changes the threat model.
- **Release-tag anomalies.** If the plugin has a tag/release workflow and recent changes bypass it, that's worth mentioning. Likewise if a commit that *claims* to be a release (e.g. "release v1.2.3") lacks the corresponding tag.
- **Commit cadence spike.** A normally quiet plugin suddenly gets 30 commits in one hour touching sensitive paths — unusual enough to surface.
- **Unverified signatures on release commits.** If earlier releases were all GPG-signed by the same key and recent ones suddenly aren't, ask why.

### Affirmative signals (raise confidence)

These don't cancel out red flags elsewhere in the checklist, but they are strong positive evidence in their own right and the report should mention them:

- **GPG-verified signatures.** When GitHub reports a commit as "Verified" (or `git log --format=%G?` returns `G`), it means the commit is signed by a key GitHub trusts for that committer. A consistently-signed history dominated by one maintainer's key is about as good as unfunded open-source provenance gets. Note the key ID in the report when available — it's reusable trust across future reviews of the same plugin.
- **The pinned SHA is a signed release tag.** If `lazy-lock.json` points at a commit that is *also* a signed release tag (e.g. `v0.1.9` with a verified signature), the starting point of the review is effectively tag-gated. Combined with signed tags on the new side, this rules out most account-compromise scenarios where an attacker pushes to `master` without the ability to sign.
- **Release notes that match the commit list.** If the plugin's releases page contains maintainer-written summaries, cross-reference them against the commits you see. When the summaries line up with the commit messages and PR numbers, you have independent corroboration that the commits are what they claim to be. When they diverge, *that* is worth investigating.
- **Consistent maintainer review pattern.** "Author X and maintainer Y committed" across most PRs, with Y being the same person over long stretches, is the open-source equivalent of a two-person rule. It doesn't guarantee safety, but it means a single compromised contributor account isn't sufficient on its own.
- **High star count / long history / active issue tracker.** These aren't security guarantees (popular projects get compromised too — see `event-stream`), but they raise the cost of an undetected malicious change landing and staying.

## Decision rubric for the final verdict

Use this to pick between the three verdict labels. *Fidelity matters*: the rubric below assumes you actually walked the diff. If you only had commit metadata or release notes, the honest ceiling is `REVIEW RECOMMENDED` regardless of what you saw at that level — you cannot rule out problems you didn't look at.

**`LOOKS ROUTINE`** — all of:
- Review fidelity was full-diff (via `gh`, local git, or successful `.diff` fetch).
- No hits in categories 1–5, or hits are straightforwardly explainable by the plugin's purpose.
- No hits in categories 6–8.
- Committers are established contributors; no force-push of the old SHA.
- Ideally one or more affirmative signals from the list above.

**`REVIEW RECOMMENDED`** — any of:
- Non-trivial hits in categories 1–3 that fit the plugin's purpose but deserve explicit user acceptance.
- Dependency or build changes worth the user noting (category 5 or 7).
- A first-time committer making non-trivial changes, with no other red flags.
- *You did not have access to the full diff* — commit-targeted or metadata-only reviews land here by default, even when the meta-signals look clean.

**`HOLD — SPECIFIC CONCERNS`** — any of:
- Obfuscation (category 4).
- Curl-piped-to-shell or equivalent (category 1 or 5).
- Filesystem access to credential-bearing paths (category 3).
- New network code not plausibly explained by the plugin's purpose (category 2).
- Force-push that removed the pinned SHA from history (category 9).
- Credentials committed to the repo (category 8).
- Any combination of yellow flags that compounds (e.g., first-time committer + new shell-out + vague commit message).

The verdict is advisory. The user decides.
