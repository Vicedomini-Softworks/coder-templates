# ============================================================================
# Kubernetes (k3s) — Coder Template
# ============================================================================
#
# Same workspace as the `railway` template, but each Coder workspace is a
# Deployment + PVC on a Kubernetes cluster (the dev k3s cluster managed by
# vcloud-infra-dev) instead of a Railway project.
#
# Image contract (identical to railway/):
#   The workspace image's ENTRYPOINT consumes
#     CODER_INIT_SCRIPT_B64   base64-encoded Coder agent init script
#     CODER_AGENT_TOKEN       Coder agent token
#   and runs as root so the entrypoint can chown the home volume and then
#   drop to the coder user. The default image is the one built from
#   ../railway/build (single source of truth, no second Dockerfile).
#
# Lifecycle:
#   Persistent (survive stop): PVC for /home/coder, optional pull secret
#   Ephemeral  (start_count):  the Deployment (scaled to zero by deleting it)
#
# The target namespace must already exist:
#   kubectl create namespace coder-workspaces
# ============================================================================

terraform {
  required_providers {
    coder = {
      source = "coder/coder"
    }
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
  }
}

variable "kubeconfig" {
  type        = string
  sensitive   = true
  description = <<-EOT
    Content (not a path) of a kubeconfig for the target cluster, e.g. the k3s
    /etc/rancher/k3s/k3s.yaml with `server:` changed from 127.0.0.1 to an
    address the Coder provisioner can reach. Supports client certificate or
    bearer-token users. Never exposed to workspace users.
  EOT
}

variable "namespace" {
  type        = string
  default     = "coder-workspaces"
  description = "Existing namespace where workspace Deployments and PVCs are created."
}

variable "storage_class" {
  type        = string
  default     = "local-path"
  description = "StorageClass for the /home/coder volume (k3s default: local-path)."
}

variable "home_disk_size" {
  type        = string
  default     = "20Gi"
  description = "Size of the persistent /home/coder volume."
}

variable "cpu_limit" {
  type        = string
  default     = "4"
  description = "CPU limit of the workspace container."
}

variable "memory_limit" {
  type        = string
  default     = "8Gi"
  description = "Memory limit of the workspace container."
}

variable "workspace_image" {
  type        = string
  default     = "docker.io/vicedominisoftworks/railway-vicedominidev:latest"
  description = <<-EOT
    Pre-built workspace image. The image's ENTRYPOINT must consume the
    CODER_INIT_SCRIPT_B64 and CODER_AGENT_TOKEN env vars. The default image
    is public; see ../railway/build/Dockerfile for the source.
  EOT
}

variable "image_registry_username" {
  type        = string
  default     = ""
  description = <<-EOT
    Optional registry username for private image pulls. Leave empty when
    pointing at the public default image or any other public registry.
  EOT
}

variable "image_registry_password" {
  type        = string
  default     = ""
  sensitive   = true
  description = <<-EOT
    Optional registry password / PAT for private image pulls. Leave empty
    when pointing at a public image.
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
    the pod's resolver. Needed in userspace-networking mode (no /dev/net/tun), where tailscaled
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

locals {
  kubeconfig = yamldecode(var.kubeconfig)
  cluster    = local.kubeconfig.clusters[0].cluster
  user       = local.kubeconfig.users[0].user

  username     = data.coder_workspace_owner.me.name
  workspace    = lower(data.coder_workspace.me.name)
  project_name = lower(substr("coder-${local.username}-${local.workspace}", 0, 32))
  labels = {
    "app.kubernetes.io/name"     = "coder-workspace"
    "app.kubernetes.io/instance" = local.project_name
    "app.kubernetes.io/part-of"  = "coder"
    "com.coder.workspace.id"     = data.coder_workspace.me.id
  }
  use_pull_secret = var.image_registry_username != ""
  use_tailscale   = nonsensitive(var.tailscale_auth_key != "")

  # Claude Code goes through the tailscaled proxy; these stay direct.
  coder_host      = regex("^[a-z]+://([^/:]+)", data.coder_workspace.me.access_url)[0]
  claude_no_proxy = "localhost,127.0.0.1,::1,.svc,.cluster.local,${local.coder_host}"
  use_jenkins_mcp = var.jenkins_user != "" && nonsensitive(var.jenkins_api_token != "")
}

provider "coder" {}

provider "kubernetes" {
  host                   = local.cluster.server
  cluster_ca_certificate = try(base64decode(local.cluster["certificate-authority-data"]), null)
  insecure               = try(local.cluster["insecure-skip-tls-verify"], false)
  token                  = try(local.user.token, null)
  client_certificate     = try(base64decode(local.user["client-certificate-data"]), null)
  client_key             = try(base64decode(local.user["client-key-data"]), null)
}

data "coder_provisioner" "me" {}
data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

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
# Kubernetes resources
# ===========================================================================

# ---------------------------------------------------------------------------
# 1. Home volume (persistent)
#
# local-path binds on first consumer (WaitForFirstConsumer), so Terraform
# must not wait for the claim to bind before the Deployment exists.
# ---------------------------------------------------------------------------
resource "kubernetes_persistent_volume_claim_v1" "home" {
  wait_until_bound = false

  metadata {
    name      = "${local.project_name}-home"
    namespace = var.namespace
    labels    = local.labels
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = var.storage_class
    resources {
      requests = {
        storage = var.home_disk_size
      }
    }
  }
}

# ---------------------------------------------------------------------------
# 2. Image pull secret (persistent, optional)
# ---------------------------------------------------------------------------
resource "kubernetes_secret_v1" "registry" {
  count = local.use_pull_secret ? 1 : 0

  metadata {
    name      = "${local.project_name}-registry"
    namespace = var.namespace
    labels    = local.labels
  }
  type = "kubernetes.io/dockerconfigjson"
  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        (split("/", var.workspace_image)[0]) = {
          username = var.image_registry_username
          password = var.image_registry_password
          auth     = base64encode("${var.image_registry_username}:${var.image_registry_password}")
        }
      }
    })
  }
}

# ---------------------------------------------------------------------------
# 3. Workspace Deployment (ephemeral, only when started)
#
# Recreate strategy because the home PVC is ReadWriteOnce. The container
# runs as root so the image entrypoint can chown /home/coder and drop to
# the coder user. NET_ADMIN/NET_RAW (+ /dev/net/tun when a Tailscale key is
# set) let tailscaled and warp-svc run, as in the Railway image.
# ---------------------------------------------------------------------------
resource "kubernetes_deployment_v1" "workspace" {
  count            = data.coder_workspace.me.start_count
  wait_for_rollout = false

  metadata {
    name      = local.project_name
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        "app.kubernetes.io/instance" = local.project_name
      }
    }

    template {
      metadata {
        labels = local.labels
      }

      spec {
        dynamic "image_pull_secrets" {
          for_each = kubernetes_secret_v1.registry
          content {
            name = image_pull_secrets.value.metadata[0].name
          }
        }

        container {
          name              = "workspace"
          image             = var.workspace_image
          image_pull_policy = "Always"

          env {
            name  = "CODER_AGENT_TOKEN"
            value = coder_agent.main.token
          }
          env {
            name  = "CODER_INIT_SCRIPT_B64"
            value = base64encode(coder_agent.main.init_script)
          }

          security_context {
            run_as_user = 0
            capabilities {
              add = ["NET_ADMIN", "NET_RAW"]
            }
          }

          resources {
            limits = {
              cpu    = var.cpu_limit
              memory = var.memory_limit
            }
          }

          volume_mount {
            name       = "home"
            mount_path = "/home/coder"
          }

          dynamic "volume_mount" {
            for_each = local.use_tailscale ? [1] : []
            content {
              name       = "tun"
              mount_path = "/dev/net/tun"
            }
          }
        }

        volume {
          name = "home"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.home.metadata[0].name
          }
        }

        dynamic "volume" {
          for_each = local.use_tailscale ? [1] : []
          content {
            name = "tun"
            host_path {
              path = "/dev/net/tun"
              type = "CharDevice"
            }
          }
        }
      }
    }
  }
}

# ===========================================================================
# Metadata and apps
# ===========================================================================

resource "coder_metadata" "workspace" {
  count       = data.coder_workspace.me.start_count
  resource_id = kubernetes_deployment_v1.workspace[0].id
  item {
    key   = "namespace"
    value = var.namespace
  }
  item {
    key   = "image"
    value = var.workspace_image
  }
  item {
    key   = "home_volume"
    value = "${var.home_disk_size} (${var.storage_class})"
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

# Optional: join the workspace to a tailnet on start. Only created when
# var.tailscale_auth_key is set; without a key Tailscale is not started.
# The key reaches the script through the agent env (TS_AUTHKEY), not the
# script body. The tailscale package and ts-dns-forward are baked into the
# image (railway/build/Dockerfile); the install fallback below only covers
# custom images. Every step is best-effort and start_blocks_login is false: a
# Tailscale problem never keeps the workspace from starting.
resource "coder_script" "tailscale" {
  count              = local.use_tailscale ? 1 : 0
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

    # Same daemon setup as the image entrypoint (railway/build/entrypoint.sh):
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
  count        = local.use_tailscale ? 1 : 0
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
