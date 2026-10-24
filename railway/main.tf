# ============================================================================
# Railway (via GraphQL) — Coder Template
# ============================================================================
#
# Each Coder workspace becomes a fully isolated Railway project running
# a container built from a pre-built image on GHCR. Every Railway
# operation is a direct GraphQL mutation via `curl` (no community
# Railway Terraform provider).
#
# See registry/bpmct/templates/railway/README.md for the full write-up
# on why this template calls the Railway API directly instead of using
# the community provider, and https://github.com/bpmct/coder-railway
# for three alternative approaches (tf-patched, hybrid, cli) and the
# reliability suite behind the design choices.
#
# Image contract:
#   The workspace image's ENTRYPOINT must consume:
#     CODER_INIT_SCRIPT_B64   base64-encoded Coder agent init script
#     CODER_AGENT_TOKEN       Coder agent token
#     RAILWAY_RUN_UID         "0" so the entrypoint can chown the
#                             root-owned Railway volume mount and then
#                             drop to the coder user.
#   The default image (docker.io/vicedominisoftworks/railway-vicedominidev:latest)
#   is codercom/enterprise-base:ubuntu plus a small entrypoint and a set of
#   preinstalled CLIs (Claude Code, Cursor, Kiro, cloudflared, cloudflare-warp,
#   Tailscale). Built and pushed by .github/workflows/build-workspace-image.yml
#   from ./build on every push to build/**. Source at ./build/Dockerfile.
#
# Lifecycle:
#   Persistent (survive stop): project, service, volume, project token
#   Ephemeral  (start_count):  env vars, image deploy
#
# Provisioner layout:
#   Bash bodies live in scripts/*.sh, one file per (resource, action).
#   main.tf only wires `command = "bash ${path.module}/scripts/X.sh"`
#   and passes runtime values via environment {} blocks. Destroy
#   provisioners reference self.input.* because vars/locals/data are
#   not allowed in destroy scopes. ${path.module} is a constant and
#   safe to use everywhere.
# ============================================================================

terraform {
  required_providers {
    coder = {
      source = "coder/coder"
    }
  }
}

variable "railway_token" {
  type        = string
  description = "Railway API token."
  sensitive   = true
}

variable "enable_project_management" {
  type        = bool
  default     = false
  description = <<-EOT
    If true, provision a project-scoped Railway token in each workspace's
    Railway project and install the Railway CLI in the workspace. The
    workspace user can then run `railway logs`, `railway up`,
    `railway run`, etc. against their own project. The master token
    (var.railway_token) is never exposed to the workspace; only the
    project-scoped token is.
  EOT
}

variable "workspace_image" {
  type        = string
  default     = "docker.io/vicedominisoftworks/railway-vicedominidev:latest"
  description = <<-EOT
    Pre-built workspace image. The image's ENTRYPOINT must consume the
    CODER_INIT_SCRIPT_B64, CODER_AGENT_TOKEN, and RAILWAY_RUN_UID env
    vars. The default image is public; see ./build/Dockerfile for the
    source and .github/workflows/build-workspace-image.yml for how it's
    built and pushed to Docker Hub.
  EOT
}

variable "image_registry_username" {
  type        = string
  default     = ""
  description = <<-EOT
    Optional registry username for private image pulls. Leave empty
    when pointing at the public default image
    (docker.io/vicedominisoftworks/railway-vicedominidev) or any other public
    registry.
  EOT
}

variable "image_registry_password" {
  type        = string
  default     = ""
  sensitive   = true
  description = <<-EOT
    Optional registry password / PAT for private image pulls. Leave
    empty when pointing at the public default image
    (docker.io/vicedominisoftworks/railway-vicedominidev) or any other public
    registry.
  EOT
}

variable "claude_code_oauth_token" {
  type        = string
  default     = ""
  sensitive   = true
  description = <<-EOT
    Optional Claude Code OAuth token (generate with `claude setup-token`).
    When set, it is exported as CLAUDE_CODE_OAUTH_TOKEN in every workspace
    session so `claude` is authenticated without an interactive login.
    Shared by all workspaces created from this template. Leave empty to
    skip.
  EOT
}

variable "tailscale_auth_key" {
  type        = string
  default     = ""
  sensitive   = true
  description = <<-EOT
    Optional Tailscale auth key (https://login.tailscale.com/admin/settings/keys).
    When set, each workspace runs `tailscale up --auth-key=...` on start and
    joins your tailnet as `coder-<owner>-<workspace>`, as an ephemeral node
    (in-memory state). When empty, Tailscale is not started. Shared by all
    workspaces created from this template.
  EOT
}

variable "tailscale_dns_domains" {
  type        = string
  default     = "vicedomini.corp"
  description = <<-EOT
    Comma-separated DNS domains resolved by the tailnet's private DNS server
    (the first private IPv4 resolver in the tailnet DNS settings) instead of
    Railway's resolver. Needed in userspace-networking mode, where tailscaled
    and its proxy resolve names through /etc/resolv.conf. Empty to disable.
  EOT
}

variable "internal_ca_install_url" {
  type        = string
  default     = "http://ca.dev-k8s.vicedomini.corp/install.sh"
  description = <<-EOT
    Install script of the internal CA (the dev-k8s CA that signs
    *.dev-k8s.vicedomini.corp, name-constrained to that domain). Fetched and
    run as root through the tailnet on every start, after `tailscale up`, so
    curl, git and Claude Code (including its HTTP MCP servers) trust internal
    services. Empty to skip. Needs tailscale_auth_key.
  EOT
}

variable "internal_ca_fingerprint" {
  type        = string
  default     = "D2:FA:9D:F4:46:2F:61:E3:A1:56:7B:AA:0C:88:CF:B1:8A:39:AC:21:52:73:85:5E:01:6F:B0:04:F2:CE:1F:C9"
  description = <<-EOT
    SHA-256 fingerprint of the internal CA, passed to the install script as
    EXPECTED_FP: the CA is installed only if it matches (the script and the
    CA come over plain HTTP). The default is the dev-k8s CA's; update it when
    the CA is rotated. Empty to install without checking.
  EOT
}

variable "jenkins_user" {
  type        = string
  default     = ""
  description = "Optional Jenkins user for the Claude Code `jenkins` MCP server (with jenkins_api_token)."
}

variable "jenkins_api_token" {
  type        = string
  default     = ""
  sensitive   = true
  description = <<-EOT
    Optional Jenkins API token. When it and jenkins_user are set, every
    workspace registers the `jenkins` HTTP MCP server in Claude Code (user
    scope) on start. The credentials reach the workspace only as the agent
    env var JENKINS_MCP_AUTHORIZATION, which the MCP config references.
  EOT
}

variable "jenkins_mcp_url" {
  type        = string
  default     = "https://jenkins.dev-k8s.vicedomini.corp/mcp-server/mcp"
  description = "URL of the Jenkins MCP server endpoint."
}

provider "coder" {}

locals {
  username     = data.coder_workspace_owner.me.name
  workspace    = lower(data.coder_workspace.me.name)
  started      = data.coder_workspace.me.start_count > 0
  railway_api  = "https://backboard.railway.app/graphql/v2"
  state_dir    = "${path.module}/.railway-state"
  scripts_dir  = "${path.module}/scripts"
  project_name = lower(substr("coder-${local.username}-${local.workspace}", 0, 32))

  # Claude Code goes through the tailscaled proxy; these stay direct.
  coder_host      = regex("^[a-z]+://([^/:]+)", data.coder_workspace.me.access_url)[0]
  claude_no_proxy = "localhost,127.0.0.1,::1,.railway.internal,${local.coder_host}"
  use_jenkins_mcp = var.jenkins_user != "" && nonsensitive(var.jenkins_api_token != "")
}

data "coder_provisioner" "me" {}
data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

data "coder_parameter" "region" {
  name         = "region"
  display_name = "Region"
  description  = "Railway region for the workspace."
  icon         = "/emojis/1f30e.png"
  type         = "string"
  default      = "us-west1"
  mutable      = false
  option {
    name  = "US West"
    value = "us-west1"
    icon  = "/emojis/1f1fa-1f1f8.png"
  }
  option {
    name  = "US East"
    value = "us-east4"
    icon  = "/emojis/1f1fa-1f1f8.png"
  }
  option {
    name  = "Europe West"
    value = "europe-west4"
    icon  = "/emojis/1f1ea-1f1fa.png"
  }
  option {
    name  = "Asia Southeast"
    value = "asia-southeast1"
    icon  = "/emojis/1f1f8-1f1ec.png"
  }
}

data "coder_parameter" "git_repo_url" {
  name         = "git_repo_url"
  display_name = "Git repository to clone"
  description  = "Optional. Clone this repo into the workspace home dir before login (e.g. https://github.com/org/repo). Leave blank to skip."
  icon         = "/icon/git.svg"
  type         = "string"
  default      = ""
  mutable      = true
}

# ---------------------------------------------------------------------------
# Coder agent
# ---------------------------------------------------------------------------

resource "coder_agent" "main" {
  os   = "linux"
  arch = "amd64"

  startup_script = <<-EOT
    set -e
    if [ ! -f ~/.init_done ]; then
      cp -rT /etc/skel ~ 2>/dev/null || true
      touch ~/.init_done
    fi
  EOT

  env = merge(
    {
      GIT_AUTHOR_NAME     = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
      GIT_AUTHOR_EMAIL    = data.coder_workspace_owner.me.email
      GIT_COMMITTER_NAME  = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
      GIT_COMMITTER_EMAIL = data.coder_workspace_owner.me.email
    },
    var.claude_code_oauth_token != "" ? { CLAUDE_CODE_OAUTH_TOKEN = var.claude_code_oauth_token } : {},
    var.tailscale_auth_key != "" ? { TS_AUTHKEY = var.tailscale_auth_key } : {},
    # Node tools only use their bundled roots: also trust the system store,
    # where the internal CA is installed.
    var.internal_ca_install_url != "" ? { NODE_EXTRA_CA_CERTS = "/etc/ssl/certs/ca-certificates.crt" } : {},
    local.use_jenkins_mcp ? {
      JENKINS_MCP_AUTHORIZATION = "Basic ${base64encode("${var.jenkins_user}:${var.jenkins_api_token}")}"
    } : {},
  )

  metadata {
    display_name = "CPU Usage"
    key          = "0_cpu_usage"
    script       = "coder stat cpu"
    interval     = 10
    timeout      = 1
  }
  metadata {
    display_name = "RAM Usage"
    key          = "1_ram_usage"
    script       = "coder stat mem"
    interval     = 10
    timeout      = 1
  }
  metadata {
    display_name = "Home Disk"
    key          = "3_home_disk"
    script       = "coder stat disk --path $${HOME}"
    interval     = 60
    timeout      = 1
  }
}

# ===========================================================================
# Railway resources, all via GraphQL
# ===========================================================================

# Helper: every curl call follows this pattern:
#   1. POST the mutation.
#   2. Print the response (for terraform logs).
#   3. grep for "errors", exit 1 if found.
#   4. Extract the ID with sed and write to state file.

# ---------------------------------------------------------------------------
# 1. Project (persistent)
# ---------------------------------------------------------------------------
resource "terraform_data" "project" {
  # Triggers replacement if project name changes. Stores token and
  # project name so the destroy provisioner can authenticate and find
  # the project by name without depending on state files.
  input = {
    project_name = local.project_name
    token        = var.railway_token
    scripts_dir  = local.scripts_dir
  }

  triggers_replace = local.project_name

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = "bash ${local.scripts_dir}/project_create.sh"
    environment = {
      API          = local.railway_api
      TOKEN        = var.railway_token
      PROJECT_NAME = local.project_name
      STATE_DIR    = local.state_dir
    }
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["bash", "-c"]
    command     = "bash ${self.input.scripts_dir}/project_destroy.sh"
    environment = {
      API          = "https://backboard.railway.app/graphql/v2"
      TOKEN        = self.input.token
      PROJECT_NAME = self.input.project_name
    }
  }
}

# ---------------------------------------------------------------------------
# 2. Service (persistent)
# ---------------------------------------------------------------------------
resource "terraform_data" "service" {
  input = {
    token       = var.railway_token
    scripts_dir = local.scripts_dir
  }
  depends_on = [terraform_data.project]

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = "bash ${local.scripts_dir}/service_create.sh"
    environment = {
      API          = local.railway_api
      TOKEN        = var.railway_token
      PROJECT_NAME = local.project_name
      STATE_DIR    = local.state_dir
    }
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["bash", "-c"]
    command     = "bash ${self.input.scripts_dir}/service_destroy.sh"
    environment = {
      API   = "https://backboard.railway.app/graphql/v2"
      TOKEN = self.input.token
    }
  }
}

# ---------------------------------------------------------------------------
# 3. Volume (persistent)
#
# CRITICAL: This must run before ANY deployment activity on the service.
# Railway rejects volumeCreate on services that have had deployments.
# By using pure GraphQL we control ordering exactly.
# ---------------------------------------------------------------------------
resource "terraform_data" "volume" {
  input      = var.railway_token
  depends_on = [terraform_data.service]

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = "bash ${local.scripts_dir}/volume_create.sh"
    environment = {
      API          = local.railway_api
      TOKEN        = var.railway_token
      PROJECT_NAME = local.project_name
      STATE_DIR    = local.state_dir
    }
  }

  # Volume is deleted when service/project is deleted (cascade).
}

# ---------------------------------------------------------------------------
# 4. Environment variables (ephemeral, only when started)
#
# Set BEFORE the image is attached, so that when the first deployment
# runs it already has the correct env vars. This avoids triggering
# extra redeploys that would happen if we upserted vars after the
# source was set (each variableUpsert on a connected service triggers
# a redeploy).
# ---------------------------------------------------------------------------
resource "terraform_data" "env_vars" {
  count      = data.coder_workspace.me.start_count
  depends_on = [terraform_data.volume]

  input = {
    token        = var.railway_token
    project_name = local.project_name
    scripts_dir  = local.scripts_dir
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = "bash ${local.scripts_dir}/env_vars_create.sh"
    environment = {
      API                   = local.railway_api
      TOKEN                 = var.railway_token
      PROJECT_NAME          = local.project_name
      STATE_DIR             = local.state_dir
      CODER_INIT_SCRIPT_B64 = base64encode(coder_agent.main.init_script)
      CODER_AGENT_TOKEN     = coder_agent.main.token
    }
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["bash", "-c"]
    command     = "bash ${self.input.scripts_dir}/env_vars_destroy.sh"
    environment = {
      API          = "https://backboard.railway.app/graphql/v2"
      TOKEN        = self.input.token
      PROJECT_NAME = self.input.project_name
    }
  }
}

# ---------------------------------------------------------------------------
# 4b. Project-scoped Railway token + RAILWAY_TOKEN env var (optional).
#
# When var.enable_project_management is true, provision a Railway
# project-scoped token via projectTokenCreate and upsert it as
# RAILWAY_TOKEN on the workspace service. The Coder script
# `railway_cli` (below) installs the Railway CLI in the workspace.
# The CLI auto-picks up RAILWAY_TOKEN from the container env.
#
# Persistent across stop/start (count is tied to the variable, not
# start_count). The token survives until workspace delete, when the
# destroy provisioner deletes it and the env var. The variableUpsert
# happens before image_deploy, so the first deploy already has
# RAILWAY_TOKEN in scope.
# ---------------------------------------------------------------------------
resource "terraform_data" "project_token" {
  count      = var.enable_project_management ? 1 : 0
  depends_on = [terraform_data.project, terraform_data.service]

  triggers_replace = local.project_name

  input = {
    token        = var.railway_token
    project_name = local.project_name
    scripts_dir  = local.scripts_dir
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = "bash ${local.scripts_dir}/project_token_create.sh"
    environment = {
      API          = local.railway_api
      TOKEN        = var.railway_token
      PROJECT_NAME = local.project_name
      STATE_DIR    = local.state_dir
    }
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["bash", "-c"]
    command     = "bash ${self.input.scripts_dir}/project_token_destroy.sh"
    environment = {
      API          = "https://backboard.railway.app/graphql/v2"
      TOKEN        = self.input.token
      PROJECT_NAME = self.input.project_name
    }
  }
}

# ---------------------------------------------------------------------------
# 5. Image deploy (ephemeral, only when started)
#
# Points the workspace service at a pre-built container image and
# triggers the first deployment. Two GraphQL calls:
#   1. serviceInstanceUpdate(source: { image, registryCredentials? })
#      Updates the source. Does NOT trigger a deploy on its own in
#      current Railway behavior.
#   2. serviceInstanceDeployV2(serviceId, environmentId)
#      Explicitly triggers a deploy of the current config.
#
# On stop, the destroy provisioner cancels active deployments to
# scale the container to zero, then polls briefly for stray deploys
# that env_vars destroy might race.
# ---------------------------------------------------------------------------
resource "terraform_data" "image_deploy" {
  count      = data.coder_workspace.me.start_count
  depends_on = [terraform_data.env_vars, terraform_data.project_token]

  # Store IDs needed by the destroy provisioner. Destroy provisioners
  # can only reference self, not vars or other resources.
  input = {
    token        = var.railway_token
    project_name = local.project_name
    scripts_dir  = local.scripts_dir
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = "bash ${local.scripts_dir}/image_deploy_create.sh"
    environment = {
      API                     = local.railway_api
      TOKEN                   = var.railway_token
      PROJECT_NAME            = local.project_name
      STATE_DIR               = local.state_dir
      WORKSPACE_IMAGE         = var.workspace_image
      IMAGE_REGISTRY_USERNAME = var.image_registry_username
      IMAGE_REGISTRY_PASSWORD = var.image_registry_password
    }
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["bash", "-c"]
    command     = "bash ${self.input.scripts_dir}/image_deploy_destroy.sh"
    environment = {
      API          = "https://backboard.railway.app/graphql/v2"
      TOKEN        = self.input.token
      PROJECT_NAME = self.input.project_name
    }
  }
}


# ===========================================================================
# Metadata and apps
# ===========================================================================

resource "coder_metadata" "workspace" {
  resource_id = coder_agent.main.id
  item {
    key   = "region"
    value = data.coder_parameter.region.value
  }
  item {
    key   = "image"
    value = var.workspace_image
  }
  item {
    key   = "project_id"
    value = try(file("${local.state_dir}/project_id"), "pending")
  }
  item {
    key   = "service_id"
    value = try(file("${local.state_dir}/service_id"), "pending")
  }
}

module "code-server" {
  count    = data.coder_workspace.me.start_count
  source   = "registry.coder.com/coder/code-server/coder"
  version  = "~> 1.5"
  agent_id = coder_agent.main.id
  order    = 1
}

# Optional: pre-checkout a git repo into the workspace home dir on start,
# before the user logs in. Skipped entirely when git_repo_url is blank.
module "git-clone" {
  count    = data.coder_workspace.me.start_count > 0 && trimspace(data.coder_parameter.git_repo_url.value) != "" ? 1 : 0
  source   = "registry.coder.com/coder/git-clone/coder"
  version  = "~> 1.0"
  agent_id = coder_agent.main.id
  url      = data.coder_parameter.git_repo_url.value
  base_dir = "~/"
}

# Optional: install the Railway CLI on workspace start when project
# management is enabled. The CLI auto-authenticates against the
# project-scoped RAILWAY_TOKEN that terraform_data.project_token sets
# on the workspace service, so the user can immediately run e.g.
# `railway status`, `railway logs`, `railway up`, `railway run -- npm test`.
#
# The installer writes to ~/.railway which is on the persistent home
# volume, so subsequent starts are instant (no re-download).
resource "coder_script" "railway_cli" {
  count              = var.enable_project_management ? 1 : 0
  agent_id           = coder_agent.main.id
  display_name       = "Install Railway CLI"
  icon               = "/icon/railway.svg"
  run_on_start       = true
  start_blocks_login = false

  script = <<-EOT
    set -eu

    # Install Railway CLI to ~/.railway if not already present.
    # The upstream installer is bash-only; running it via /bin/sh
    # surfaces a harmless "Bad substitution" error and a non-zero
    # exit, which Coder reports as a startup-script failure. Run it
    # explicitly under bash and ignore its exit code; we verify the
    # binary after.
    if ! [ -x "$HOME/.railway/bin/railway" ]; then
      echo "Installing Railway CLI..."
      # agents.railway.com installs the CLI and also configures the
      # Railway MCP server / agent support for installed coding agents.
      curl -fsSL https://agents.railway.com -o /tmp/railway-install.sh
      bash /tmp/railway-install.sh || true
      rm -f /tmp/railway-install.sh
    fi

    if ! [ -x "$HOME/.railway/bin/railway" ]; then
      echo "ERROR: Railway CLI install failed."
      exit 1
    fi

    # Symlink into /usr/local/bin so the CLI is on PATH for every
    # shell, including non-interactive `coder ssh ... -- cmd` runs.
    # ~/.bashrc would only work for interactive shells; setting the
    # PATH in coder_agent.env would not survive new bash sessions.
    if ! [ -e /usr/local/bin/railway ]; then
      sudo ln -sf "$HOME/.railway/bin/railway" /usr/local/bin/railway
    fi

    echo ""
    echo "Railway CLI ready. RAILWAY_TOKEN is set to a project-scoped"
    echo "token for this workspace's Railway project. Try:"
    echo "  railway status"
    echo "  railway logs --service workspace"
    echo "  railway variables"
  EOT
}

# Optional: join the workspace to a tailnet on start. Only created when
# var.tailscale_auth_key is set; without a key Tailscale is not started.
# The key reaches the script through the agent env (TS_AUTHKEY), not the
# script body. The tailscale package and ts-dns-forward are baked into the
# image (build/Dockerfile); the install fallback below only covers custom
# images. Every step is best-effort and start_blocks_login is false: a
# Tailscale problem never keeps the workspace from starting.
resource "coder_script" "tailscale" {
  count              = var.tailscale_auth_key != "" ? 1 : 0
  agent_id           = coder_agent.main.id
  display_name       = "Tailscale"
  icon               = "/icon/tailscale.svg"
  run_on_start       = true
  start_blocks_login = false

  script = <<-EOT
    set -u

    if ! command -v tailscale > /dev/null 2>&1; then
      echo "Installing Tailscale..."
      curl -fsSL https://tailscale.com/install.sh | sh || true
    fi
    if ! command -v tailscaled > /dev/null 2>&1; then
      echo "ERROR: tailscaled not available; Tailscale skipped."
      exit 1
    fi

    # Same daemon setup as the image entrypoint (see build/entrypoint.sh):
    # SOCKS5 + HTTP proxy on localhost:1055, in-memory state (ephemeral
    # node), userspace networking with MTU 1200 when there is no TUN device.
    TS_FLAGS="--state=mem: --socks5-server=localhost:1055 --outbound-http-proxy-listen=localhost:1055"
    TS_ENV=""
    if [ ! -c /dev/net/tun ]; then
      TS_FLAGS="$TS_FLAGS --tun=userspace-networking"
      TS_ENV="TS_DEBUG_MTU=1200"
    fi
    proxy_up() { timeout 2 bash -c ': < /dev/tcp/127.0.0.1/1055' 2> /dev/null; }
    # Ignores zombies: a tailscaled started by an older entrypoint stays
    # <defunct> after a kill (its parent never reaps it), and pgrep would
    # still match it.
    ts_running() { ps -C tailscaled -o stat= 2> /dev/null | grep -qv '^Z'; }

    # An older image's entrypoint starts tailscaled without the proxy (or
    # with on-disk state): restart it with the flags above. Log out first so
    # its node is released instead of lingering in the tailnet.
    if ts_running && ! proxy_up; then
      echo "tailscaled is running without the localhost:1055 proxy; restarting it."
      sudo timeout 15 tailscale logout > /dev/null 2>&1 || true
      sudo pkill -x tailscaled || true
      for _ in $(seq 1 10); do
        ts_running || break
        sleep 1
      done
      sudo pkill -9 -x tailscaled 2> /dev/null || true
    fi
    if ! ts_running; then
      [ -c /dev/net/tun ] || echo "No /dev/net/tun; starting tailscaled in userspace-networking mode."
      sudo sh -c "$TS_ENV nohup tailscaled $TS_FLAGS > /tmp/tailscaled.log 2>&1 &"
    fi
    for _ in $(seq 1 30); do
      [ -S /var/run/tailscale/tailscaled.sock ] && proxy_up && break
      sleep 1
    done

    # --accept-routes: internal services (and the tailnet DNS server) sit
    # behind subnet routers, e.g. 10.0.0.0/16.
    if ! sudo timeout 90 tailscale up --auth-key="$TS_AUTHKEY" --hostname="${local.project_name}" --accept-routes; then
      echo "ERROR: tailscale up failed; see /tmp/tailscaled.log."
      exit 1
    fi
    echo "Tailscale up: $(tailscale ip -4 2> /dev/null | head -n1)"

    # Userspace mode: tailscaled (and so its proxy) resolves names through
    # /etc/resolv.conf, never through the tailnet DNS settings. Put
    # ts-dns-forward in front: names under the configured domains go to the
    # tailnet's private DNS server through the proxy, the rest to the
    # original nameservers. Only lookups of those domains change.
    DNS_DOMAINS="${var.tailscale_dns_domains}"
    if [ ! -c /dev/net/tun ] && [ -n "$DNS_DOMAINS" ]; then
      TAILNET_DNS=$(sudo tailscale dns status --json 2> /dev/null \
        | jq -r '[.Resolvers[]?.Addr | select(test("^(10\\.|192\\.168\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.)"))][0] // empty' 2> /dev/null)
      [ -f /etc/resolv.conf.pre-tailscale ] || sudo cp /etc/resolv.conf /etc/resolv.conf.pre-tailscale
      FALLBACK=$(awk '$1 == "nameserver" && $2 != "127.0.0.53" { print $2 }' /etc/resolv.conf.pre-tailscale | paste -sd, -)
      if ! command -v ts-dns-forward > /dev/null 2>&1; then
        echo "WARNING: ts-dns-forward not in this image; $DNS_DOMAINS names will not resolve."
      elif [ -z "$TAILNET_DNS" ] || [ -z "$FALLBACK" ]; then
        echo "WARNING: no private tailnet DNS server or no system nameserver; DNS forwarder not started."
      else
        if ! ss -lun | grep -q '127\.0\.0\.53:53 '; then
          sudo sh -c "nohup ts-dns-forward --domains '$DNS_DOMAINS' --tailnet-dns $TAILNET_DNS --fallback $FALLBACK > /tmp/ts-dns-forward.log 2>&1 &"
          for _ in $(seq 1 10); do
            ss -lun | grep -q '127\.0\.0\.53:53 ' && break
            sleep 1
          done
        fi
        if ss -lun | grep -q '127\.0\.0\.53:53 '; then
          { echo "nameserver 127.0.0.53"; grep -v '^nameserver 127\.0\.0\.53' /etc/resolv.conf.pre-tailscale; } \
            | sudo tee /etc/resolv.conf > /dev/null
          echo "DNS: $DNS_DOMAINS -> $TAILNET_DNS via the tailnet, rest -> $FALLBACK."
        else
          echo "WARNING: DNS forwarder failed to start; see /tmp/ts-dns-forward.log."
        fi
      fi
    fi

    # Internal CA: its install script and the ca.crt it downloads live on
    # the tailnet, hence the proxy for both (http_proxy for the script's own
    # curl). Plain HTTP, but inside the tailnet; internal_ca_fingerprint
    # makes the script refuse a CA with a different fingerprint. Right
    # after `tailscale up` the route to it may not be ready yet (the proxy
    # answers 502), so the download and the install are retried together
    # for about two minutes.
    CA_INSTALL_URL="${var.internal_ca_install_url}"
    if [ -n "$CA_INSTALL_URL" ]; then
      CA_SCRIPT=$(mktemp)
      CA_OK=""
      for attempt in $(seq 1 12); do
        if curl -fsSL --max-time 30 --proxy http://localhost:1055 "$CA_INSTALL_URL" -o "$CA_SCRIPT" \
          && sudo env http_proxy=http://localhost:1055 EXPECTED_FP="${var.internal_ca_fingerprint}" sh "$CA_SCRIPT"; then
          CA_OK=1
          break
        fi
        [ "$attempt" -lt 12 ] || break
        echo "Internal CA install attempt $attempt failed; retrying in 10s."
        sleep 10
      done
      if [ -n "$CA_OK" ]; then
        echo "Internal CA installed ($CA_INSTALL_URL)."
      else
        echo "WARNING: internal CA install from $CA_INSTALL_URL failed."
      fi
      rm -f "$CA_SCRIPT"
    fi

    # Point Claude Code (only) at the proxy, so its HTTP MCP servers reach
    # the tailnet; everything else keeps going out directly. Managed
    # settings live on the container filesystem, so they never outlive
    # this container (unlike ~/.claude on the persistent volume).
    if proxy_up && command -v jq > /dev/null 2>&1; then
      MANAGED=/etc/claude-code/managed-settings.json
      sudo mkdir -p /etc/claude-code
      { sudo cat "$MANAGED" 2> /dev/null || echo '{}'; } \
        | jq --arg proxy "http://localhost:1055" --arg no_proxy "${local.claude_no_proxy}" \
          '.env = ((.env // {}) + {HTTPS_PROXY: $proxy, HTTP_PROXY: $proxy, NO_PROXY: $no_proxy})' \
        | sudo tee "$MANAGED.tmp" > /dev/null \
        && sudo mv "$MANAGED.tmp" "$MANAGED" \
        && sudo chmod 644 "$MANAGED" \
        && echo "Claude Code proxied via localhost:1055 ($MANAGED)."
    else
      echo "WARNING: nothing listening on localhost:1055; Claude Code left unproxied."
    fi
  EOT
}

# The node is ephemeral, so logging out on stop removes it from the tailnet
# right away and the next start keeps the same hostname (instead of a -1
# suffix until the control plane reaps the offline node).
resource "coder_script" "tailscale_logout" {
  count        = var.tailscale_auth_key != "" ? 1 : 0
  agent_id     = coder_agent.main.id
  display_name = "Tailscale logout"
  icon         = "/icon/tailscale.svg"
  run_on_stop  = true

  script = <<-EOT
    sudo timeout 10 tailscale logout || true
  EOT
}

# Optional: register the Jenkins MCP server in Claude Code (user scope, in
# ~/.claude.json). The header references $JENKINS_MCP_AUTHORIZATION, which
# Claude Code expands at connect time from the agent env: the credentials
# are never written to the script body or to disk.
resource "coder_script" "jenkins_mcp" {
  count              = local.use_jenkins_mcp ? 1 : 0
  agent_id           = coder_agent.main.id
  display_name       = "Jenkins MCP"
  icon               = "/icon/jenkins.svg"
  run_on_start       = true
  start_blocks_login = false

  script = <<-EOT
    set -u
    if ! command -v claude > /dev/null 2>&1; then
      echo "claude not installed; Jenkins MCP not registered."
      exit 0
    fi
    claude mcp remove --scope user jenkins > /dev/null 2>&1 || true
    claude mcp add --scope user --transport http jenkins "${var.jenkins_mcp_url}" \
      --header 'Authorization: $${JENKINS_MCP_AUTHORIZATION}'
  EOT
}
