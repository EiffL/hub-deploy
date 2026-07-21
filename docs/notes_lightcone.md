# Notes for lightcone deployment

GCP Project: `lightconehub`
Region/zone: `europe-west1` / `europe-west1-b`
Cluster / hub name: `lightcone` (cluster and hub share the name)
Hostnames: `hub.lightconeresearch.org` (hub), `hub-grafana.lightconeresearch.org`,
`hub-prometheus.lightconeresearch.org`
Auth: `authenticator_class: github` with the lightcone GitHub app,
access via `allowed_users`/`admin_users` in `access.json`
(data in `hubs/lightcone/config.enc.yaml`)

## One-time setup (done)

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

   Creates VPC, GKE cluster, node pools, artifact registry, service accounts,
   NFS disk `hub-nfs-lightcone`, static IP `lightcone-ingress`, cert-manager.

1. Get credentials for the new cluster and store them encrypted:

   ```
   KUBECONFIG=clusters/lightcone/kubeconfig.dec.yaml gcloud container clusters get-credentials lightcone --zone europe-west1-b --project lightconehub
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

1. Deploy the hub:

   ```
   CLUSTER_NAME=lightcone HUB_NAME=lightcone nox -s helm_hub
   ```

## Notes

- Everything shared lives in `hubs/_common/config.yaml` and
  `tf/modules/gke_cluster`; lightcone only carries project/region/hostname
  specifics.
- Hub secrets: edit `hubs/lightcone/config.dec.yaml` (gitignored), then
  `sops encrypt hubs/lightcone/config.dec.yaml --output hubs/lightcone/config.enc.yaml`.
  The GitHub app's authorization callback URL must be
  `https://hub.lightconeresearch.org/hub/oauth_callback`.
- The collaboration-groups wiring in `_common` is cilogon-specific;
  collaborations in `access.json` won't create github-auth groups without
  extra config.
- KMS keyrings/keys cannot be deleted, only key versions destroyed.
- Tear-down order: `tofu destroy` first, delete the state bucket last.
