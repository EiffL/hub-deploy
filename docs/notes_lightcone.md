# Notes for lightcone deployment

GCP Project: `lightconehub`
Region/zone: `europe-west1` / `europe-west1-b`
Cluster / hub name: `lightcone` (cluster and hub share the name)
Hostnames: `hub.lightconeresearch.org` (hub), `hub-grafana.lightconeresearch.org`,
`hub-prometheus.lightconeresearch.org`
Auth: `authenticator_class: github` with the lightcone GitHub app,
access via `allowed_users`/`admin_users` in `access.json`
(data in `hubs/lightcone/config.enc.yaml`)
Compute: dask-gateway for `lightcone-cli` (`lc run`) and Cloud Build image
builds through Workload Identity (`tf/modules/lightcone`), same as the demo hub.

## Status

The deployment was torn down on 2026-07-30 (`tofu destroy`, then the state
buckets were deleted). The sops KMS key version was scheduled for destruction
on 2026-08-29, after which the existing `*.enc.yaml` files under
`clusters/lightcone/` and `hubs/lightcone/` cannot be decrypted. Redeploying
means redoing the one-time setup below (restore the key version if still
possible, otherwise create a new key) and re-creating every secret and the
kubeconfig.

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

1. Create the cluster with OpenTofu (`tf/clusters/lightcone`):

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
   zone.

1. Get credentials for the new cluster and store them encrypted:

   ```
   KUBECONFIG=clusters/lightcone/kubeconfig.dec.yaml gcloud container clusters get-credentials lightcone --region europe-west1 --project lightconehub
   sops encrypt clusters/lightcone/kubeconfig.dec.yaml --output clusters/lightcone/kubeconfig.enc.yaml
   ```

1. Point DNS at the `lightcone-ingress` static IP: create A records for the
   three hostnames at the DNS provider for `lightconeresearch.org`:

   ```
   gcloud compute addresses describe lightcone-ingress --region europe-west1 --project lightconehub --format='value(address)'
   ```

   cert-manager issues the Let's Encrypt certificates automatically once the
   records resolve.

1. Deploy the support chart (gateway, grafana, prometheus):

   ```
   CLUSTER_NAME=lightcone nox -s helm_support_upgrade_crds
   CLUSTER_NAME=lightcone nox -s helm_support
   ```

1. Apply the dask-gateway CRDs (helm does not install or upgrade a subchart's
   `crds/` on upgrade). Keep the version in step with the `dask-gateway`
   dependency in `charts/hub/Chart.yaml`:

   ```
   KUBECONFIG=clusters/lightcone/kubeconfig.dec.yaml kubectl apply -f https://raw.githubusercontent.com/dask/dask-gateway/2026.3.0/resources/helm/dask-gateway/crds/daskclusters.yaml
   ```

1. Deploy the hub:

   ```
   CLUSTER_NAME=lightcone HUB_NAME=lightcone nox -s helm_hub
   ```

## Notes

- One-time after first NFS deploy: the export root on a fresh disk is owned by
  root, but the ganesha export squashes all clients to uid 1000, so the kubelet
  cannot create user home subdirectories. Fix from the nfs-server container:

  ```
  kubectl exec -n lightcone deploy/home-nfs -c nfs-server -- chown 1000:1000 /export
  ```

- Everything shared lives in `hubs/_common/config.yaml` (authenticators, user
  image, resources, opencode/biorouter, ssh env, dask-gateway) and in
  `tf/modules/gke_cluster` / `tf/modules/lightcone`. `hubs/lightcone/config.yaml`
  only carries the hostname-derived values, the NFS `volumeId`, the user
  service account name, and the Cloud Build / dask-gateway names that depend on
  the project and release name (`traefik-lightcone-dask-gateway`).
- Hub secrets: edit `hubs/lightcone/config.dec.yaml` (gitignored), then
  `sops encrypt hubs/lightcone/config.dec.yaml --output hubs/lightcone/config.enc.yaml`.
  The GitHub app's authorization callback URL must be
  `https://hub.lightconeresearch.org/hub/oauth_callback`.
  Besides the GitHub client id/secret, cookie secret, CryptKeeper keys and
  `access.json` data, the file needs
  `jupyterhub.singleuser.extraEnv.OPENAI_API_KEY` (NRP Nautilus key used by
  opencode and biorouter through `OPENAI_HOST` in `_common`), as in
  `hubs/demo/config.enc.yaml`.
- The collaboration-groups wiring in `_common` is cilogon-specific;
  collaborations in `access.json` won't create github-auth groups without
  extra config.
- KMS keyrings/keys cannot be deleted, only key versions destroyed.
- Tear-down order: `tofu destroy` first, delete the state bucket last.
