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
    joins your tailnet as `coder-<owner>-<workspace>`. When empty, Tailscale
    is not started. Shared by all workspaces created from this template.
  EOT
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
# script body. The tailscale package itself is baked into the image
# (railway/build/Dockerfile); the install fallback below only covers custom images.
resource "coder_script" "tailscale" {
  count              = local.use_tailscale ? 1 : 0
  agent_id           = coder_agent.main.id
  display_name       = "Tailscale"
  icon               = "/icon/tailscale.svg"
  run_on_start       = true
  start_blocks_login = false

  script = <<-EOT
    set -eu

    if ! command -v tailscale > /dev/null 2>&1; then
      echo "Installing Tailscale..."
      curl -fsSL https://tailscale.com/install.sh | sh
    fi

    # The image entrypoint starts tailscaled as root (needs /dev/net/tun).
    # If it isn't up, start it ourselves, falling back to userspace
    # networking when the container has no TUN device.
    if ! sudo tailscale status > /dev/null 2>&1 && ! pgrep -x tailscaled > /dev/null; then
      if [ -c /dev/net/tun ]; then
        sudo nohup tailscaled > /tmp/tailscaled.log 2>&1 &
      else
        echo "No /dev/net/tun; starting tailscaled in userspace-networking mode."
        sudo nohup tailscaled --tun=userspace-networking > /tmp/tailscaled.log 2>&1 &
      fi
    fi

    for _ in $(seq 1 30); do
      [ -S /var/run/tailscale/tailscaled.sock ] && break
      sleep 1
    done

    sudo tailscale up --auth-key="$TS_AUTHKEY" --hostname="${local.project_name}"
    echo "Tailscale up: $(tailscale ip -4 2>/dev/null | head -n1)"
  EOT
}
