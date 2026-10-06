# set-var-sec.sh

A lightweight script to set GitHub Actions secrets and variables using your personal
`gh` login. No GitHub App, no private key, no token setup — just admin rights on the
repos and a logged-in `gh` session.

---

## 1. What it does

- Prompts you once per secret or variable, then writes the value to every repo in `repos.conf`.
- Creates the item if it does not exist; overwrites it if it does.
- Handles both **secrets** (encrypted, input hidden) and **variables** (plaintext, input visible).
- Supports **repo-level** (`NAME`) and **environment-level** (`NAME@environment`) items.
- CLI mode: passing `--secret` or `--var` on the command line ignores config files — targets only
  what you listed, across all repos in `repos.conf` (or a `--repo` override).

---

## 2. What it requires

| Requirement | Check |
|---|---|
| `gh` CLI installed | `gh --version` |
| Logged in to gh | `gh auth status` |
| **Admin** role on each target repo | Settings tab must be accessible |
| Environment exists on repo | Only if you use `NAME@environment` |

No App ID, no `.pem` file, no `openssl`, no `curl` — just `gh`.

Your session token needs the `repo` scope (the default when you run `gh auth login`).
To confirm: `gh auth status` should show `repo` in the token scopes line.

---

## 3. How to use it

### First time

```bash
cd scripts/secret-rotation
chmod +x set-var-sec.sh
gh auth status          # confirm you are logged in
```

### Set everything in config files

```bash
./set-var-sec.sh --dry-run    # rehearsal — validates secrets, writes nothing
./set-var-sec.sh              # do it
```

Reads secrets from `secrets.conf` and variables from `vars.conf`, writes to every repo
in `repos.conf`.

### Set one secret (CLI mode)

```bash
./set-var-sec.sh --secret AZURE_CLIENT_ID
```

### Set one variable (CLI mode)

```bash
./set-var-sec.sh --var NODE_VERSION
```

### Set one item on one specific repo

```bash
./set-var-sec.sh --repo ava-jinesh/auto-setup-demo-repo --secret AZURE_CLIENT_ID
./set-var-sec.sh --repo ava-jinesh/auto-setup-demo-repo --var NODE_VERSION
```

### Mix secrets and variables in one run

```bash
./set-var-sec.sh --secret AZURE_CLIENT_ID --var NODE_VERSION
```

### Environment-scoped item

```bash
./set-var-sec.sh --var DEPLOY_SLOT@production
```

The `production` environment must already exist on the repo (Settings → Environments).

---

## 4. Commands it runs

| Step | Command | Purpose |
|---|---|---|
| 1 | `gh auth token` | Retrieve your current session token. Fails fast if not logged in. |
| 2 | `gh secret set NAME --repo owner/repo [--env ENV] [--no-store]` | Fetch repo public key, encrypt value, upload. `--no-store` used on `--dry-run`. |
| 3 | `gh variable set NAME --repo owner/repo [--env ENV]` | Upload variable value in plaintext. Skipped entirely on `--dry-run`. |

Secret and variable values are piped over **stdin** — they never appear in the process
list or shell history.

---

## 5. What checks it has

| Check | Failure message |
|---|---|
| `gh` on PATH | `gh is not installed or not on PATH` |
| Logged in | `not logged in to gh — run: gh auth login` |
| At least one repo configured | `no repositories configured` |
| At least one secret or variable | `nothing to do — add entries to secrets.conf or vars.conf, or pass --secret / --var` |
| Repo name format `owner/name` | `invalid repository 'x' (expected owner/name)` |
| Name is `[A-Za-z_][A-Za-z0-9_]*` | `invalid secret/variable name '9BAD'` |
| Name does not start with `GITHUB_` | `name 'GITHUB_TOKEN' is reserved` |
| Environment name is well-formed | `invalid environment name 'x' in 'NAME@x'` |
| Per-item failures | Reported individually; run continues to next item |
| Empty input | Item is skipped, not written as empty string |

Exits `0` only if everything succeeded. Exits `1` if any item failed.
Prints `applied / skipped / failed` summary at the end.

---

## 6. Why it is secure

### Secrets are end-to-end encrypted before leaving your machine

When you set a secret, `gh secret set` does the following — all locally, before any
network call:

1. Fetches the repository's **public key** from GitHub (each repo has a unique one).
2. Encrypts your value using **libsodium `crypto_box_seal`** (NaCl sealed-box encryption)
   with that public key.
3. Sends only the **ciphertext** to GitHub over HTTPS.

GitHub stores and uses the ciphertext. It never sees your plaintext value, not even in
transit. The private key that can decrypt it never leaves GitHub's servers.
This is the same encryption model GitHub uses for all secrets set through the UI.

### Secret values are never exposed as process arguments

The value is piped to `gh` over **stdin**:
```bash
printf '%s' "$value" | gh secret set NAME ...
```
It does not appear in:
- The process list (`ps aux`)
- Your shell history
- Any log file the script writes

### Nothing is written to disk

The script holds values only in shell variables in memory for the duration of the run.
No temp files, no log files, no `.env` dumps.

### Your session token is read-only from `gh`'s keyring

`gh auth token` retrieves your OAuth token from the system credential store (`gh`
manages this). The token is held in memory only for the run and is never written to any file
by this script.

### Variables are NOT encrypted — by design

GitHub variables are **plaintext** and are intended to be non-sensitive configuration
(app names, version numbers, feature flags). The script shows variable values as you type
to make this distinction clear. **Never put passwords, keys, or tokens in `vars.conf`
— use `secrets.conf` for anything sensitive.**

| | Secrets | Variables |
|---|---|---|
| Encrypted at rest on GitHub | Yes (libsodium) | No — stored plaintext |
| Visible in GitHub UI | Name only, never value | Name and value |
| Visible in workflow logs | No (masked automatically) | Yes, unless masked manually |
| Input when running script | Hidden | Visible as you type |

---

## Difference from rotate-secrets.sh

| | `set-var-sec.sh` | `rotate-secrets.sh` |
|---|---|---|
| Auth | Your personal `gh` session | GitHub App (or `--personal-auth`) |
| Setup | None | Create App, generate key, install on repos |
| Audit log | Shows as your user account | Shows as the App |
| Best for | Your own repos, quick runs | Shared team automation |
