# rotate-secrets.sh

Rotate GitHub Actions secrets and variables across any number of repositories in a single run.

---

## 1. What it does

- Prompts you **once per item**, then writes that value to **every repository** listed in `repos.conf`.
- Creates the item if it does not exist, overwrites it if it does. Same command either way.
- Handles both:
  - **Secrets** — encrypted, never readable back, input hidden as you type
  - **Variables** — plaintext, visible in GitHub UI and workflow logs, input shown as you type
- Writes **repository-level** items (`NAME`) or **environment-level** items (`NAME@environment`).
- Authenticates as a **GitHub App**, not as you. The credential belongs to the org, not your account.
- Mints a short-lived token scoped to only the repos and permissions needed, then **revokes it on exit**.
- Scales by editing a text file: add a repo line, re-run, every item lands there too.
- CLI mode: passing `--secret` or `--var` on the command line ignores both config files entirely — useful for one-off changes without touching `secrets.conf` or `vars.conf`.

**What it deliberately does not do:** create environments, create repositories, read existing
secret values (the GitHub API cannot), or store anything on disk.

---

## 2. What it uses

| Tool | Why | Status on this machine |
|---|---|---|
| `bash` | The script itself. Run it in Git Bash, WSL, macOS or Linux. | 5.2.37 |
| `gh` | Encrypts and uploads secrets; uploads variables. | 2.83.1 |
| `openssl` | Signs the GitHub App JWT (RS256) and hashes secret values for the checksum display. | 3.5.4 |
| `curl` | The two GitHub App auth calls. | present |
| `jq` | Optional. A built-in `grep`/`sed` fallback is used when absent. | 1.7.1 (at `~/bin/jq`) |

### Required GitHub App permissions

Minimum set. Grant nothing else.

| Permission | Level | Why it is needed |
|---|---|---|
| **Metadata** | Read-only | Mandatory for every GitHub App. Resolves `owner/repo`. |
| **Secrets** | Read and write | `PUT /repos/{owner}/{repo}/actions/secrets/{name}` — repository secrets. Only requested when the run includes secrets. |
| **Variables** | Read and write | `POST/PATCH /repos/{owner}/{repo}/actions/variables/{name}` — repository variables. Only requested when the run includes variables. |
| **Environments** | Read and write | Env-scoped secrets and variables. Only requested when a `NAME@environment` form is in the run. |

These are **repository** permissions. No organisation permissions, no `contents`, no `actions`,
no account permissions. The token is scoped to only the permissions the current run actually needs.

> Read access on **Secrets** exposes only secret *names and timestamps*. The GitHub API never
> returns secret values, so this App cannot read back what is stored.

### Configuration files

| File | Purpose |
|---|---|
| `repos.conf` | One `owner/repo` per line. Add a line to widen the blast radius. |
| `secrets.conf` | One secret per line. `NAME` or `NAME@environment`. |
| `vars.conf` | One variable per line. `NAME` or `NAME@environment`. Optional — skipped if absent or empty. |
| `.gitignore` | Blocks `*.pem` / `*.key` from being committed. |

All `.conf` files ignore blank lines, `#` comments, Windows CRLF, and duplicates.

---

## 3. How to use it

### One-time setup

1. **Create the App** — Org Settings → Developer settings → GitHub Apps → New GitHub App.
   - Uncheck **Webhook → Active**.
   - Set the repository permissions from the table above.
   - **Where can this app be installed:** Only on this account.
2. **Generate a private key** — App settings → *Private keys* → Generate. A `.pem` downloads.
   Store it **outside this repo** (e.g. `~/.ssh/gh-app-secret-rotation.pem`). Anyone holding
   this file can act as the App.
3. **Install the App** — App settings → Install App → **Only select repositories** → pick your repos.
   The App must be installed on a repo before the script can touch it.
4. **Note the App ID** — top of the App's settings page.

### Running it — GitHub App (default)

```bash
cd scripts/secret-rotation
chmod +x rotate-secrets.sh          # first time only

export GH_APP_ID=123456
export GH_APP_PRIVATE_KEY=~/.ssh/gh-app-secret-rotation.pem

./rotate-secrets.sh --dry-run       # full rehearsal, writes nothing
./rotate-secrets.sh                 # do it
```

### Running it — personal auth (no App needed)

If you have admin rights on the target repos and are already logged into `gh`, skip
the GitHub App entirely:

```bash
./rotate-secrets.sh --personal-auth --dry-run
./rotate-secrets.sh --personal-auth
```

Uses your existing `gh` session (`gh auth token`). No `GH_APP_ID` or private key required.
Appears in audit logs as your user account rather than the App.

Secret input is hidden as you type. Variable input is visible (variables are plaintext).
Press **Enter on an empty prompt to skip** any item.

### Adding a repository

Append to `repos.conf`, install the App on it, re-run:

```
ava-jinesh/auto-setup-demo-repo
ava-jinesh/another-service
some-org/third-service
```

Repos are grouped by owner and one token is minted per owner, so mixing owners is fine
as long as the App is installed on each account.

### Adding a secret

Append to `secrets.conf`:

```
AZURE_CLIENT_ID
AZURE_TENANT_ID
AZURE_SUBSCRIPTION_ID
AZURE_CLIENT_SECRET@production      # environment-scoped
```

### Adding a variable

Append to `vars.conf`:

```
AZURE_WEBAPP_NAME
NODE_VERSION
DEPLOY_SLOT@production              # environment-scoped
```

A name used both bare and with `@env` is prompted for once and written to both scopes.

### Ad-hoc runs (CLI mode)

Passing `--secret` or `--var` on the CLI ignores both config files — only what you list
on the command line is processed:

```bash
# Rotate one secret across all repos in repos.conf
./rotate-secrets.sh --secret AZURE_CLIENT_ID

# Set one variable on one specific repo
./rotate-secrets.sh --repo ava-jinesh/auto-setup-demo-repo --var NODE_VERSION

# Mix secrets and variables in one run
./rotate-secrets.sh --secret AZURE_CLIENT_ID --var AZURE_WEBAPP_NAME

# Environment-scoped
./rotate-secrets.sh --secret API_KEY@production
```

| Flag | Effect |
|---|---|
| `--repo owner/name` | Use this repo instead of `repos.conf`. Repeatable. |
| `--secret NAME[@env]` | CLI mode: only this secret (suppresses `secrets.conf` and `vars.conf`). Repeatable. |
| `--var NAME[@env]` | CLI mode: only this variable (suppresses `secrets.conf` and `vars.conf`). Repeatable. |
| `--repos-file PATH` | Alternate repo list. |
| `--secrets-file PATH` | Alternate secret list (config mode only). |
| `--vars-file PATH` | Alternate variable list (config mode only). |
| `--personal-auth` | Use your existing `gh` session instead of a GitHub App. No `GH_APP_ID` or `.pem` needed. |
| `--dry-run` | Authenticate and validate — write nothing. |
| `-h`, `--help` | Usage. |

---

## 4. Commands it runs

In order, per run:

| Step | Command / API call | Purpose |
|---|---|---|
| 1 | `openssl pkey -in $GH_APP_PRIVATE_KEY -noout` | Validate the PEM before going near the network. |
| 2 | `openssl dgst -sha256 -sign $GH_APP_PRIVATE_KEY` | Sign the RS256 JWT (10-minute lifetime, `iat` backdated 60s for clock skew). |
| 3 | `GET /repos/{owner}/{repo}/installation` *(JWT)* | Resolve the App's installation ID for that owner. |
| 4 | `POST /app/installations/{id}/access_tokens` *(JWT)* | Mint a token scoped to `{"repositories":[...],"permissions":{...only what this run needs...}}`. Expires in 1 hour. |
| 5 | `openssl dgst -sha256` per secret value | Produce the display checksum. The value is never printed. |
| 6a | `gh secret set NAME --repo owner/repo [--env ENV] [--no-store]` *(token)* | Fetch repo public key, libsodium-seal the value, `PUT` it. `--no-store` on `--dry-run`. |
| 6b | `gh variable set NAME --repo owner/repo [--env ENV]` *(token)* | `POST` or `PATCH` the variable value in plaintext. Skipped entirely on `--dry-run`. |
| 7 | `DELETE /installation/token` | Revoke every minted token. Runs from an `EXIT` trap — fires even on Ctrl-C. |

Notes:

- Both secret and variable values are piped over **stdin**, never passed as arguments — they do not
  appear in the process list, `ps` output, or shell history.
- Step 6a with `--no-store` fetches the repo public key and encrypts, so `--dry-run` genuinely
  exercises the permission path for secrets rather than just checking auth.
- Variables have no `--no-store` equivalent — `--dry-run` skips step 6b entirely and prints "would set".
- One token is minted per **owner**, not per repo.

---

## 5. What checks it has

**Before any network call:**

| Check | Failure message |
|---|---|
| `gh`, `openssl`, `curl` on `PATH` | `<tool> is not installed or not on PATH` |
| `GH_APP_ID` set | `set GH_APP_ID to the App ID shown on your GitHub App settings page` |
| `GH_APP_PRIVATE_KEY` set | `set GH_APP_PRIVATE_KEY to the path of the .pem private key…` |
| Private key readable | `cannot read private key: <path>` |
| Private key is a valid PEM | `…is not a valid PEM private key (re-download it…)` |
| Config files exist | `config file not found: <path>` |
| At least one repo | `no repositories configured` |
| At least one secret or variable | `nothing to do — add entries to secrets.conf or vars.conf, or pass --secret / --var` |
| Repo matches `owner/name` | `invalid repository 'x' (expected owner/name)` |
| Name is `[A-Za-z_][A-Za-z0-9_]*` | `invalid secret/variable name '9BAD' (…cannot start with a digit)` |
| Name is not `GITHUB_*` | `secret/variable name 'GITHUB_TOKEN' is reserved: GitHub rejects the GITHUB_ prefix` |
| Environment name is well-formed | `invalid environment name 'x' in 'NAME@x'` |

**During the run:**

- Installation lookup failure → `the GitHub App is not installed on <repo> (or the App ID / private key is wrong)`.
- Token mint failure → `could not mint an installation token for <owner> — check the App's permissions`.
  This is what you get if **Variables** or **Environments** is missing but those features are in use.
- Empty installation ID or token → explicit error rather than a silent no-op.
- Per-item failures are **isolated**: one bad secret or variable is reported and the run continues.
- Empty input → that item is skipped and counted, not written as an empty string.

**Behavioural guarantees:**

- `set -euo pipefail` — no silent failures, no unset-variable surprises.
- Config parsing strips CRLF, comments and duplicates, so a Windows-edited file behaves.
- Exits **1** if any item failed, **0** only if everything succeeded — safe to wrap in CI later.
- Prints an `applied / skipped / failed` summary at the end.

### Known constraints

- The **environment must already exist** on the repo before env-scoped items can be written.
  The script surfaces GitHub's 404 verbatim rather than creating environments silently.
- Environment secrets **override** repository secrets of the same name for jobs declaring that
  environment. Only use `@env` when you actually want a per-environment value.
- Keep the `.pem` outside the repository. `*.pem` is gitignored here as a backstop only.
