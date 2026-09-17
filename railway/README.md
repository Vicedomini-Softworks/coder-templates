---
display_name: Railway (via GraphQL)
description: Coder workspaces backed by Railway services, provisioned via direct GraphQL calls (no community Terraform provider).
icon: ../../../../.icons/railway.svg
verified: false
tags: [railway, cloud, container, docker]
---

# Railway (via GraphQL)

Each Coder workspace is a fully isolated [Railway](https://railway.com) project running a container built from a public image on GHCR. Every workspace becomes a first-class Railway project (its own environment, its own volumes, its own service token), which sets up a natural extension point: the workspace user can manage further Railway resources inside their own project via the [Railway CLI](https://docs.railway.com/reference/cli-api).

[![Demo: Railway + Coder workspaces](https://cdn.loom.com/sessions/thumbnails/92a59e1f379c4b6bb8869f14df5e837d-49d50ac4ed07b42c.gif)](https://www.loom.com/share/92a59e1f379c4b6bb8869f14df5e837d)
_Demo (Loom, ~5 min)_

> [!NOTE]
> The Loom above was recorded before startup was optimized. The demo shows a per-start Docker build (~62s median). This template now uses `serviceInstanceUpdate(source: { image })` against a pre-built image (`ghcr.io/bpmct/railway-coder-workspace:latest`), so median start time is ~6s. The rest of the flow in the demo (workspace creation, project isolation, Railway CLI) still applies.

## Why direct GraphQL instead of the Terraform provider

The community [`terraform-community-providers/railway`](https://github.com/terraform-community-providers/terraform-provider-railway) provider is a great starting point, but hits two blocking issues for a Coder template that has to run reliably under stress:

1. **Volume creation is racy.** `railway_volume` can write to a service before the service is fully attached, and Railway rejects `volumeCreate` on services that have had deployments. Terraform's implicit ordering does not respect Railway's API contract here.
2. **`variableUpsert` triggers extra deploys.** Every env var write during workspace start races a redeploy that intermittently fails with "Cannot redeploy without a snapshot" (just after `serviceDisconnect`) or "Cannot redeploy yet, please wait for the original deployment to finish building" (during the first second after a `deploymentCancel`).

This template bypasses the provider entirely for the Railway operations and calls the [Railway public API](https://docs.railway.com/reference/public-api) directly with `curl`. Key fixes that keep the reliability suite green:

- **`skipDeploys: true`** on `variableUpsert`. An undocumented flag that tells Railway to persist the value without enqueuing a redeploy. The subsequent `serviceInstanceDeployV2` is what actually deploys, and it picks up the freshly-set variables.
- **Explicit `volumeCreate` before any deployment activity**, with backoff on the "creating volumes too quickly" rate limit.
- **`serviceInstanceUpdate(source: { image })` + `serviceInstanceDeployV2`** for the image deploy, rather than `serviceConnect` (which builds from a repo on every start).

See [bpmct/coder-railway](https://github.com/bpmct/coder-railway) for the full write-up, the reliability suite, and three other variants (Terraform-provider-based, hybrid, and Railway-CLI-based) that were tried along the way.

## Prerequisites

### 1. Railway API token

Create a Railway account/team token at [railway.com/account/tokens](https://railway.com/account/tokens). It must be an account or team token (not a project token) so that the template can call `projectCreate`.

### 2. Push the template with the token

```sh
coder templates push railway --directory . \
  --variable railway_token=YOUR_RAILWAY_TOKEN
```

The Railway master token is stored as a Terraform variable at the template level and is never exposed to workspace users. If `enable_project_management` is set to `true`, each workspace also gets its own project-scoped Railway token (a much narrower blast radius) injected as `$RAILWAY_TOKEN` inside the workspace, and the Railway CLI is auto-installed and pre-authenticated:

```sh
coder templates push railway --directory . \
  --variable railway_token=YOUR_RAILWAY_TOKEN \
  --variable enable_project_management=true
```

## Usage

Create a workspace from the `railway` template. The only end-user parameter is:

- **Region**: US West, US East, EU West, Asia Southeast.

Everything else (project, service, volume, env vars, image source, first deploy) happens under the hood via GraphQL.

## Architecture

For each workspace, this template provisions on Railway:

- **Project** (`coder-<owner>-<workspace>`, one per workspace).
- **Service** (`workspace`) pinned to the image in `workspace_image`.
- **Volume** persisting `/home/coder`, survives stop/start.
- **Env vars** on the service: `CODER_AGENT_TOKEN`, `CODER_INIT_SCRIPT_B64`, `RAILWAY_RUN_UID=0`.
- Optionally, a **project-scoped Railway token** exposed to the workspace as `$RAILWAY_TOKEN`.

Persistent (survive stop/start): project, service, volume, project token. Ephemeral (per start): env vars, image deploy.

### Custom workspace image

The default image is `ghcr.io/bpmct/railway-coder-workspace:latest`, which is `codercom/enterprise-base:ubuntu` plus a small entrypoint that fixes Railway volume ownership, decodes `CODER_INIT_SCRIPT_B64`, and runs the Coder agent as the `coder` user. The Dockerfile and entrypoint are vendored in this template under [`build/`](./build) so you can read, fork, or extend them without leaving the registry:

- [`build/Dockerfile`](./build/Dockerfile) - layer on `codercom/enterprise-base:ubuntu` adding the Claude Code, Cursor, Kiro and [pi.dev](https://pi.dev) coding-agent CLIs, GitHub CLI (`gh`), cloudflared/WARP/Tailscale, rootless Podman, PHP 8.5 + Composer, kubectl + kustomize, SDKMAN (Java 8/11/21, Maven, JBang), Node.js 22, Playwright/Chromium and `tini` as PID 1 (process reaper).
- [`build/entrypoint.sh`](./build/entrypoint.sh) - Railway volume `chown`, skeleton seed, `CODER_INIT_SCRIPT_B64` decode + drop to `coder`.
- [`build/pi-models.json`](./build/pi-models.json) - regolo.ai custom provider for pi (see below).

Node.js 22 is installed **system-wide** via a shared NVM in `/opt/nvm`, with `node`/`npm`/`npx` symlinked into `/usr/local/bin`. That puts Node on PATH for every shell - including non-interactive ones (`coder ssh <ws> -- cmd`, code-server tasks, agent scripts) and workspaces whose home volume still carries rc files from older images, since entrypoint backfills never overwrite existing rc files. The `nvm` shell function is still available in login/interactive shells for switching versions; versions installed at runtime live in `/opt` and reset to the image's default on the next start.

The image's `ENTRYPOINT` runs under [tini](https://github.com/krallin/tini) rather than executing `entrypoint.sh` directly as PID 1. Without a real init process, `entrypoint.sh`'s final `exec su ... coder` replaces PID 1's process image with `su`, which never reaps orphaned child processes (e.g. every `git`/`gh` subprocess a coding agent spawns and abandons) - they pile up as zombies until Railway's per-container process-count limit (`pids.max`) is hit and the workspace has to be restarted. tini runs as the actual container PID 1, wraps `entrypoint.sh`, and reaps all orphaned descendants regardless of what `entrypoint.sh` execs into. This only takes effect on container start, so a workspace already running on an older image needs to be stopped/restarted (or otherwise redeployed) after pushing this fix to actually pick it up.

### pi.dev coding agent

The image preinstalls [pi](https://pi.dev) (`pi` on PATH everywhere) with almost every extension from [narumiruna/pi-extensions](https://github.com/narumiruna/pi-extensions):

| Extension | What it adds |
| --- | --- |
| `pi-plan-mode` | Read-only `/plan` collaboration before implementation |
| `pi-goal` | Keep the agent working until a goal is verified complete |
| `pi-statusline` | Footer with model, git state, tokens, cost, context usage |
| `pi-btw` | Quick `/btw` side questions outside the main context |
| `pi-stamp` | Timestamps and response/tool timing in the transcript |
| `pi-usage` | `/usage` for Codex/OpenRouter subscription limits |
| `pi-worktree` | Git worktrees that carry the pi session along |
| `pi-file-context` | Attach exact file lines / diff hunks to the next prompt |
| `pi-lsp` | Language-server diagnostics and code actions |
| `pi-github-pr` | Current-branch PR checks/reviews via the `gh` CLI |
| `pi-accounts` | Switch between named OAuth accounts with `/accounts` |
| `pi-codex-compact` | Bounded, replayable context compaction |
| `pi-subagents` | Bounded background pi jobs with main-agent messaging |
| `pi-chrome-devtools` | Inspect tabs, evaluate JS, capture screenshots via CDP |
| `pi-caffeinate` | Prevent the system from sleeping during long prompts |
| `pi-dotenv` | Load explicit dotenv files for credential discovery |
| `pi-fleet` | Separate pi processes in terminal splits for bounded messages |
| `pi-tool` | Browse configured tools and inspect their active state/schemas |
| `pi-cache-hit-monitor` | Live prompt-cache reuse and cost diagnostics |
| `pi-recall` | Save and recall selected messages locally across sessions |

Not installed: `pi-herdr`, `pi-langfuse`, `pi-sync` and `pi-firecrawl` each need their own external account/service configured before they're useful, so they're left as opt-in (`pi install npm:@narumitw/<pkg>`) rather than baked into the image; `pi-chat` (peer chat rooms) is out of scope for a single-user workspace; `pi-starship` is an alternate footer that would conflict with `pi-statusline` above; `pi-tui-kit` is a shared library other extensions depend on, not an end-user extension.

Manage them with `pi list` / `pi install` / `pi remove`; change the preinstalled set by editing the `pi install` block in [`build/Dockerfile`](./build/Dockerfile). Authenticate pi per workspace with `/login` (credentials persist on the home volume in `~/.pi/agent/auth.json`).

[regolo.ai](https://regolo.ai) is registered as a pi custom provider (OpenAI-compatible, `https://api.regolo.ai/v1`) via `~/.pi/agent/models.json` ([source](./build/pi-models.json)). Authenticate once with `/login regolo` inside pi, or export `REGOLO_API_KEY`; then pick a model with `/model` (e.g. `gpt-oss-120b`, `glm5.2`, `qwen3-coder-next`). The bundled model list comes from the public `curl -s https://api.regolo.ai/v1/models` - refresh `build/pi-models.json` when regolo adds models.

> [!NOTE]
> Workspaces created before this image keep their existing home volume: `node`/`npm`/`pi` appear anyway (they live in the image under `/usr/local/bin`), but a pre-existing `~/.pi/agent/settings.json` or `models.json` is not overwritten by the skeleton backfill. Run the `pi install npm:@narumitw/...` commands from [`build/Dockerfile`](./build/Dockerfile) once by hand to pick up the preinstalled extensions.

**Adding your own tools:** the default image is deliberately minimal, so most teams will want to extend it. Two patterns:

1. **Extend the default image** (recommended for most cases). Write a Dockerfile that starts `FROM ghcr.io/bpmct/railway-coder-workspace:latest` and layer whatever you need on top. Entrypoint and Coder agent wiring are inherited, so you only touch what you actually need.

   ```dockerfile
   FROM ghcr.io/bpmct/railway-coder-workspace:latest
   USER root
   RUN apt-get update && apt-get install -y --no-install-recommends \
    postgresql-client redis-tools \
    && rm -rf /var/lib/apt/lists/*
   ```

2. **Duplicate `build/` and build from a different base**, if you need to swap the base image entirely (e.g. `codercom/example-universal:ubuntu`, an internal golden image, or a non-Ubuntu distro). Copy [`build/entrypoint.sh`](./build/entrypoint.sh) verbatim - the image contract that the template relies on (volume chown, `CODER_INIT_SCRIPT_B64` decode, drop to `coder` user) lives in that entrypoint, not in the base image. Also keep `tini` installed and wrapping the entrypoint in your `ENTRYPOINT` line (`["/usr/local/bin/tini", "--", "/coder-entrypoint.sh"]`, not `["/coder-entrypoint.sh"]` directly) - dropping it reintroduces the zombie-process/`pids.max` exhaustion bug described above.

Build, push to any registry, and point the template at it:

```sh
coder templates push railway --directory . \
  --variable railway_token=YOUR_RAILWAY_TOKEN \
  --variable workspace_image=ghcr.io/yourorg/your-image:tag
```

For private registries, also set `image_registry_username` and `image_registry_password`.

The only contract the template requires from the image is that its `ENTRYPOINT` consumes:

- `CODER_INIT_SCRIPT_B64`: base64-encoded Coder agent init script.
- `CODER_AGENT_TOKEN`: Coder agent token.
- `RAILWAY_RUN_UID=0`: Railway UID override so the entrypoint can chown the root-owned Railway volume mount before dropping to the workspace user.

## Other Railway approaches

This template ships the GraphQL variant, which is the most reliable of four approaches I tried against the Railway API. The others live in [bpmct/coder-railway/variants/wip/](https://github.com/bpmct/coder-railway/tree/main/variants/wip):

- **`tf-patched`**: Uses the Railway Terraform provider with a small patch and a `trailing_zombie` workaround for the redeploy race.
- **`hybrid`**: Uses `railway_service` from the provider, GraphQL for everything else.
- **`cli`**: Uses the Railway CLI (`railway up`, `railway link`) instead of the provider or GraphQL.

See the [benchmark table](https://github.com/bpmct/coder-railway#benchmarks) for the reliability comparison across variants.

> [!NOTE]
> This template is designed to be a starting point. Edit the Terraform to extend it for your use case.
