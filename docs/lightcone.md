# Dask Gateway + Cloud Build (lightcone-cli support)

Additions that let [lightcone-cli](https://github.com/LightconeResearch/lightcone-cli)
run its cloud workflow on a hub: `lc run` builds the project's container
image with **GCP Cloud Build**, creates a per-run **Dask Gateway**
cluster with that image (the user's home is mounted in the workers at
the same path), executes the pipeline, and tears the cluster down.
Opt-in per hub; the gateway wiring follows 2i2c basehub's
battle-tested setup.

No build service runs in the cluster: `lc build` tars the project's
staged build context, uploads it to a GCS bucket, and submits a Cloud
Build job that pushes the content-addressed image
(`lc-<project>:<hash>`) to Artifact Registry. Auth is the pod's
**Workload Identity** — no credentials are stored anywhere (no sops
entries at all), no git remote is required to build, and private
projects build like public ones.

## What was added

- `charts/hub/Chart.yaml`: one conditional dependency — `dask-gateway`
  2026.3.0.
- `hubs/_common/config.yaml`: only `dask-gateway.enabled: false` — helm
  enables a conditional dependency when the condition path is missing
  from values, so the default must be declared for hubs that don't opt
  in. All actual gateway configuration is hub-local.
- `hubs/lightcone/config.yaml`: everything else. The z2jh side declares
  the `dask-gateway` hub service (z2jh autogenerates its token; the
  gateway chart reads it from the `hub` secret by default — no token
  management), an extraConfig snippet injecting `DASK_GATEWAY__*`
  client env + registering the `/services/dask-gateway` proxy route,
  and a singleuser networkPolicy egress rule to the gateway's traefik.
  The gateway's cluster-options handler mounts the requesting user's
  home into scheduler/worker pods (subPath = `{unescaped_username}`,
  matching the z2jh storage config), advertises worker resources
  (`DASK_DISTRIBUTED__WORKER__RESOURCES__*`), and sets
  `HOME`/`USER`/`LOGNAME` so arbitrary (passwd-less, uid-1000) images
  work as workers. It also lifts z2jh's metadata block (safe under
  Workload Identity) and injects the build contract:
  `LIGHTCONE_REGISTRY`, `LIGHTCONE_BUILD_BUCKET`,
  `LIGHTCONE_BUILD_SERVICE_ACCOUNT`.
- `tf/modules/gke_cluster`: **enables Workload Identity** (cluster
  `workload_identity_config` + `GKE_METADATA` on the node pools — the
  per-cluster user pools in `tf/clusters/*/main.tf` too). Applying this
  updates node pools in place (rolling recreate).
- `tf/clusters/lightcone/cloudbuild.tf`: Cloud Build API, the `binder`
  Artifact Registry repo (node SA + hub namespace get read; the
  hardened node SA has no registry access otherwise), a source/logs
  bucket with 7-day expiry, a dedicated build SA holding only
  registry-writer + bucket access, and direct-WI grants for the hub
  namespace principal: `cloudbuild.builds.editor`, `serviceAccountUser`
  on the build SA, and bucket objectAdmin.

## Enabling on a hub

1. `CLUSTER_NAME=lightcone HUB_NAME=lightcone nox -s tofu -- apply` (node pools roll for Workload Identity).
2. Add the dask-gateway blocks (hub service, client extraConfig,
   networkPolicy egress, `dask-gateway:` chart values with
   `enabled: true`) plus the three `LIGHTCONE_*` env vars to the hub's
   config — `hubs/lightcone/config.yaml` is the reference.
3. `CLUSTER_NAME=lightcone HUB_NAME=lightcone nox -s helm_hub`.

No secrets to manage: registry pushes happen inside Cloud Build as the
build SA, and pods authenticate via Workload Identity.

## Image requirements

Any image acting as a Dask Gateway worker (including the default = the
user's notebook image) must carry `dask`, `distributed`, and
`dask-gateway` **pinned to the chart version (2026.3.0)** plus
`snakemake`/`lightcone-cli` for lightcone rules — for `images/user`
that's an addition to `pixi.toml`. lightcone *projects* build their own
worker images through Cloud Build (the `lc init` scaffold is a slim
image with the full pinned stack), so the notebook-image requirement
only gates default (container-less) clusters and the driver side.

Optional, for `lc init`'s GitHub device flow: a GitHub OAuth app with
*Enable Device Flow* ticked, its public client id exposed as
`LIGHTCONE_GITHUB_CLIENT_ID`.

## Acceptance test (from a user server)

```bash
# 1. contract present?
env | grep -E 'DASK_GATEWAY__ADDRESS|LIGHTCONE_(REGISTRY|BUILD_BUCKET)'
# 2. Workload Identity works? (namespace principal token)
curl -s -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" | head -c 60
```

```python
# 3. gateway cluster + worker contract + home visibility
from dask_gateway import Gateway
c = Gateway().new_cluster(); c.scale(1)
cl = c.get_client(); cl.wait_for_workers(1)
print(list(cl.scheduler_info()["workers"].values())[0]["resources"])  # cpus/memory
c.shutdown()
```

```bash
# 4. end to end: builds via Cloud Build (no git needed), runs, culls
lc init test-proj --no-github && cd test-proj && lc run
```
