---
display_name: Kubernetes (k3s)
description: Coder workspaces as a Deployment + PVC on a Kubernetes (k3s) cluster, same image and features as the Railway template.
icon: ../../../../.icons/kubernetes.svg
verified: false
tags: [kubernetes, k3s, container]
---

# Kubernetes (k3s)

Same workspace as the [`railway`](../railway) template, running on a Kubernetes cluster (the dev k3s cluster managed by `vcloud-infra-dev`) instead of Railway. Same image, same agent env, same modules, same optional Claude Code / Tailscale / private-registry variables.

| | `railway` | `kubernetes` |
| --- | --- | --- |
| Image | `workspace_image` (default `docker.io/vicedominisoftworks/railway-vicedominidev:latest`) | same, built from [`../railway/build`](../railway/build) |
| Persistent | project, service, volume | PVC (`/home/coder`), optional pull secret |
| Ephemeral (per start) | env vars, image deploy | Deployment |
| Parameters | `region`, `git_repo_url` | `git_repo_url` |
| Variables | `railway_token`, `enable_project_management`, `workspace_image`, `image_registry_*`, `claude_code_oauth_token`, `tailscale_auth_key` | `kubeconfig`, `namespace`, `storage_class`, `home_disk_size`, `cpu_limit`, `memory_limit`, `workspace_image`, `image_registry_*`, `claude_code_oauth_token`, `tailscale_auth_key` |
| Apps | code-server, git-clone | code-server, git-clone |

Not carried over: `railway_token`, `region` and `enable_project_management` have no Kubernetes equivalent.

## Prerequisites

1. **Namespace** (once):

   ```sh
   kubectl create namespace coder-workspaces
   ```

2. **A kubeconfig the Coder provisioner can use.** On the k3s server copy `/etc/rancher/k3s/k3s.yaml` and change `server: https://127.0.0.1:6443` to an address reachable from the provisioner. Client-certificate and bearer-token users are supported. A dedicated ServiceAccount limited to the workspace namespace is preferable to the cluster-admin k3s kubeconfig. It needs to manage `deployments`, `persistentvolumeclaims` and `secrets` there.

3. **For Tailscale:** the node must expose `/dev/net/tun` (`modprobe tun`). Without a key nothing Tailscale-related is mounted or started.

## Push the template

```sh
coder templates push kubernetes --directory . \
  --variable kubeconfig="$(cat dev-k3s.yaml)"
```

Optional, same as the Railway template:

```sh
  --variable claude_code_oauth_token=sk-ant-oat01-... \
  --variable tailscale_auth_key=tskey-auth-... \
  --variable image_registry_username=... --variable image_registry_password=...
```

The kubeconfig is a sensitive template variable and is never exposed to workspace users.

## Tailscale

When `tailscale_auth_key` is set, `tailscaled` runs with a local SOCKS5 and HTTP proxy on `localhost:1055` (`--socks5-server` / `--outbound-http-proxy-listen`, both on the same port). If the node exposes `/dev/net/tun` tailscaled uses kernel networking and the tailnet is routed normally; without it, it falls back to userspace networking, where nothing in the workspace can reach the tailnet directly (`.corp` names don't resolve, the `10.0.0.0/16` subnets aren't routed) and the proxy is the way in. The proxy works in both modes. The proxy is **opt-in per command**: `ALL_PROXY`/`HTTPS_PROXY`/`HTTP_PROXY` are deliberately not set, so GitHub, npm, Composer, apt and the Coder agent keep going out directly.

```sh
curl --proxy socks5h://localhost:1055 https://jenkins.dev-k8s.vicedomini.corp/login
```

Use `socks5h://` (not `socks5://`): with the `h` the hostname is resolved by `tailscaled` on the tailnet (MagicDNS / split DNS), which is the only way `.corp` names resolve. Tools without SOCKS support can use the HTTP proxy on the same port, e.g. `HTTPS_PROXY=http://localhost:1055 some-tool ...` for a single command. `tailscale nc <host> <port>` also works for raw TCP.

## Architecture

For each workspace, in `var.namespace`, named `coder-<owner>-<workspace>`:

- **PVC** `…-home` (`home_disk_size`, `storage_class`, default 20Gi `local-path`) mounted at `/home/coder`; survives stop/start.
- **Deployment** (1 replica, `Recreate` because the PVC is `ReadWriteOnce`) running the workspace image as root with `NET_ADMIN`/`NET_RAW`, so the image entrypoint can `chown` the volume, start `tailscaled`/`warp-svc` and drop to the `coder` user. Env: `CODER_AGENT_TOKEN`, `CODER_INIT_SCRIPT_B64`. Created on start, deleted on stop.
- **Pull secret** `…-registry`, only when `image_registry_username` is set.

With `local-path` the volume lives on the node where the workspace first started, so the workspace is pinned to that node.

> [!NOTE]
> Rootless Podman (`docker` shim in the image) may need extra privileges that an ordinary pod does not get on k3s; it is not enabled here.
