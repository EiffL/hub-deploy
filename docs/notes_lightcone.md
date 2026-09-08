# Notes for lightcone deployment

GCP Project: `lightconehub`
Region/zone: `europe-west1` / `europe-west1-b`
Cluster / hub name: `lightcone` (cluster and hub share the name)
Hostnames: `lab.lightconeresearch.org` (the hub, branded "Lightcone Lab"),
`hub-grafana.lightconeresearch.org`, `hub-prometheus.lightconeresearch.org`
Auth: `authenticator_class: github` with the lightcone GitHub app,
access via `allowed_users`/`admin_users` in `access.json`
(data in `hubs/lightcone/config.enc.yaml`)
Compute: dask-gateway for `lightcone-cli` (`lc run`) and Cloud Build image
builds through Workload Identity (`tf/modules/lightcone`), same as the demo hub.

## Status

Torn down on 2026-07-30 and redeployed from scratch on 2026-09-07. The sops
KMS key is on version 2 (version 1 was destroyed, so anything encrypted before
2026-09-07 is unreadable); the state bucket was recreated. There is currently
no NRP Nautilus key, so opencode/biorouter are configured but unusable.

## One-time setup

sops KMS key ([setup sops](https://github.com/getsops/sops?tab=readme-ov-file#encrypting-using-gcp-kms)),
used by the `(clusters|hubs)/lightcone/` path rule in `.sops.yaml`:

```
gcloud kms keyrings create sops --location global --project lightconehub
gcloud kms keys create sops-key --location global --keyring sops --purpose encryption --project lightconehub
```

Bucket for OpenTofu state (versioned):

```
gcloud storage buckets create gs://tf-state-lightconehub --location=europe-west1 --public-access-prevention --project=lightconehub
gcloud storage buckets update gs://tf-state-lightconehub --versioning
```

## Deployment steps

Tooling: `nox`, `tofu`, `helm`, `kubectl`, `sops`, and `gcloud` with the
`gke-gcloud-auth-plugin`. OpenTofu and sops authenticate with Application
Default Credentials (`gcloud auth application-default login`), which are
separate from the plain `gcloud auth login`; for a single session,
`export GOOGLE_OAUTH_ACCESS_TOKEN=$(gcloud auth print-access-token)` works too.
The chart dependencies need these helm repos once:

```
helm repo add jupyterhub https://jupyterhub.github.io/helm-chart
helm repo add dask https://helm.dask.org
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
```

The nox sessions default to `HUB_NAME=demo` and decrypt that hub's secrets
(BIDS key) before doing anything, so always set both
`CLUSTER_NAME=lightcone HUB_NAME=lightcone`. They also decrypt every
`*.enc.*` file under `clusters/lightcone/` and `hubs/lightcone/`, so those
files must be valid before running any helm session.

1. Create the cluster with OpenTofu (`tf/clusters/lightcone`), about 15 minutes:

   ```
   CLUSTER_NAME=lightcone nox -s tofu -- init
   CLUSTER_NAME=lightcone nox -s tofu -- apply
   ```

   Creates VPC, GKE cluster (Workload Identity, calico network policy), node
   pools (core, user, dask), artifact registry, service accounts, NFS disk
   `hub-nfs-lightcone`, static IP `lightcone-ingress`, cert-manager, and the
   `lightcone-cli` build resources from `tf/modules/lightcone`: artifact
   registry `lightcone-cloudbuild-images`, bucket
   `lightconehub-lightcone-lc-build`, build service account
   `lightcone-lc-build`, and Workload Identity grants for the
   `lightcone-hub-user` Kubernetes service account that user pods run as.
   These names are wired into `hubs/lightcone/config.yaml`.

   The NFS disk is `hyperdisk-balanced`: the NFS server, hub, grafana and
   prometheus are pinned to the hyperdisk-capable `n4d` core node pool from
   `tf/modules/gke_cluster` (`persistentNodeSelector` in `charts/hub` and
   `charts/support`), and those machines cannot attach `pd-*` disks. `n4d`
   machine types and Hyperdisk Balanced must therefore be available in the
   zone (they are in `europe-west1-b`).

1. Get credentials for the new cluster and store them encrypted:

   ```
   KUBECONFIG=clusters/lightcone/kubeconfig.dec.yaml gcloud container clusters get-credentials lightcone --region europe-west1 --project lightconehub
   sops encrypt clusters/lightcone/kubeconfig.dec.yaml --output clusters/lightcone/kubeconfig.enc.yaml
   ```

1. Point DNS at the `lightcone-ingress` static IP: create A records for the
   three hostnames (`lab`, `hub-grafana`, `hub-prometheus`) at the DNS provider
   for `lightconeresearch.org` (Cloudflare, records set to DNS-only so the
   HTTP-01 certificate challenge reaches the cluster):

   ```
   gcloud compute addresses describe lightcone-ingress --region europe-west1 --project lightconehub --format='value(address)'
   ```

   cert-manager issues the Let's Encrypt certificates automatically once the
   records resolve.

1. Hub secrets: write `hubs/lightcone/config.dec.yaml` (gitignored) with the
   GitHub app client id/secret (callback URL
   `https://lab.lightconeresearch.org/hub/oauth_callback`), a cookie secret
   and a CryptKeeper key (`openssl rand -hex 32` each), and the `access.json`
   data; optionally `jupyterhub.singleuser.extraEnv.OPENAI_API_KEY` for
   opencode/biorouter (see `hubs/demo/config.enc.yaml` for the shape). Then:

   ```
   sops encrypt hubs/lightcone/config.dec.yaml --output hubs/lightcone/config.enc.yaml
   ```

   Do this before the helm sessions below; they refuse to run with an
   undecryptable `config.enc.yaml`. Do not overwrite an existing
   `config.dec.yaml` without checking it: it may be the only readable copy.

1. Deploy the support chart (gateway, grafana, prometheus):

   ```
   CLUSTER_NAME=lightcone HUB_NAME=lightcone nox -s helm_support_upgrade_crds
   CLUSTER_NAME=lightcone HUB_NAME=lightcone nox -s helm_support
   ```

1. Apply the dask-gateway CRDs (helm does not install or upgrade a subchart's
   `crds/` on upgrade). Keep the version in step with the `dask-gateway`
   dependency in `charts/hub/Chart.yaml`:

   ```
   KUBECONFIG=clusters/lightcone/kubeconfig.dec.yaml kubectl apply -f https://raw.githubusercontent.com/dask/dask-gateway/2026.3.0/resources/helm/dask-gateway/crds/daskclusters.yaml
   ```

1. Deploy the hub (helm creates the `lightcone` namespace):

   ```
   CLUSTER_NAME=lightcone HUB_NAME=lightcone nox -s helm_hub
   ```

1. Once after the first NFS deploy: the export root on a fresh disk is owned by
   root, but the ganesha export squashes all clients to uid 1000, so the kubelet
   cannot create user home subdirectories. Fix from the nfs-server container:

   ```
   KUBECONFIG=clusters/lightcone/kubeconfig.dec.yaml kubectl exec -n lightcone deploy/home-nfs -c nfs-server -- chown 1000:1000 /export
   ```

1. Commit the new `kubeconfig.enc.yaml` and `config.enc.yaml`.

## Notes

- Theme: the hub pages keep JupyterHub's layout but use the Lightcone colours,
  type and mark, from `charts/hub/files/themes/lightcone/` (`page.html`,
  `lightcone.css`, `logo.svg` from the website), packed into the `hub-theme`
  ConfigMap by `charts/hub/templates/hub-theme.yaml` and enabled with
  `hubTheme: lightcone` plus the volume mounts in `hubs/lightcone/config.yaml`.
  Colours and type follow the brand package (`../brand`); fonts load from
  Google Fonts like the website. JupyterHub caches templates, so after a
  theme change run `kubectl rollout restart -n lightcone deploy/hub`. The
  BIDS analytics snippet from `charts/hub/values.yaml` is not used here.
- Persistent volumes: the hub database, grafana and prometheus claims use the
  `auto-balanced` storage class from `charts/support` with at least 4Gi (set in
  `hubs/lightcone/config.yaml` and `clusters/lightcone/support/config.yaml`).
  The cluster default class (`standard-rwo`, pd-balanced) cannot attach to the
  hyperdisk-only `n4d` nodes those pods are pinned to, and Hyperdisk Balanced
  volumes cannot be smaller than 4 GB. A claim created with the wrong class or
  size has to be deleted and recreated; its spec is immutable.
- Everything shared lives in `hubs/_common/config.yaml` (authenticators, user
  image, resources, opencode/biorouter, ssh env, dask-gateway) and in
  `tf/modules/gke_cluster` / `tf/modules/lightcone`. `hubs/lightcone/config.yaml`
  only carries the hostname-derived values, the NFS `volumeId`, the user
  service account name, the storage class, the theme wiring, and the Cloud
  Build / dask-gateway names that depend on the project and release name
  (`traefik-lightcone-dask-gateway`).
- The collaboration-groups wiring in `_common` is cilogon-specific;
  collaborations in `access.json` won't create github-auth groups without
  extra config.
- KMS keyrings/keys cannot be deleted, only key versions destroyed. Destroying
  the version that encrypted the `*.enc.*` files makes them unrecoverable, so
  keep a readable copy of the secrets somewhere safe before tearing down.
- Tear-down order: `tofu destroy` first, delete the state bucket last.
