# Akeyless + Kubernetes External Secrets Operator (ESO) Runbook

An operator runbook for integrating Kubernetes clusters with [Akeyless](https://www.akeyless.io/) using the [External Secrets Operator (ESO)](https://external-secrets.io/). Covers both **RKE/Rancher** and **GKE** distributions, including migration paths from HashiCorp Vault.

This guide is designed for **platform engineers, DevOps teams, and SREs** who need to deliver secrets to Kubernetes workloads at scale using a standardized, auditable, and automated approach.

## Table of Contents

| # | Document | Description |
|---|---|---|
| 1 | [Architecture Overview](docs/01-architecture-overview.md) | High-level architecture, components, and data flow |
| 2 | [Prerequisites](docs/02-prerequisites.md) | Tools, access, and configuration needed before starting |
| 3 | [Cluster Setup -- RKE](docs/03-cluster-setup-rke.md) | RKE/Rancher-specific cluster preparation (includes Rancher-native approach) |
| 4 | [Cluster Setup -- GKE](docs/04-cluster-setup-gke.md) | GKE-specific cluster preparation |
| 5 | [Akeyless Auth Configuration](docs/05-akeyless-auth-config.md) | Creating Kubernetes auth methods in Akeyless (two-step process) |
| 6 | [ESO Deployment](docs/06-eso-deployment.md) | Installing and configuring ESO with Akeyless provider |
| 7 | [Secret Management](docs/07-secret-management.md) | ExternalSecret patterns, RBAC mapping, and best practices |
| 8 | [Pipeline Automation](docs/08-pipeline-automation.md) | CI/CD integration and Terraform automation |
| 9 | [Migration from Vault](docs/09-migration-from-vault.md) | Phased migration from HashiCorp Vault to Akeyless |
| 10 | [Troubleshooting](docs/10-troubleshooting.md) | Common issues, debugging, and resolution steps |

| Resource | Description |
|---|---|
| [Terraform Modules](terraform/) | Reusable modules for automated K8s auth onboarding |
| [Kubernetes Manifests](manifests/) | Ready-to-apply YAML for SA, RBAC, SecretStore, ExternalSecrets |
| [Automation Scripts](scripts/) | Cluster param extraction and connectivity validation |
| [Validation Log](VALIDATION-LOG.md) | Full test results from live MicroK8s + Rancher validation |

## Architecture Overview

```mermaid
%%{init: {'theme': 'neutral'}}%%
graph TB
    subgraph "Kubernetes Clusters"
        direction TB
        subgraph "RKE / Rancher Cluster"
            ESO_RKE["External Secrets<br/>Operator"]
            CSS_RKE["ClusterSecretStore"]
            ES_RKE["ExternalSecret CRs"]
            K8S_SEC_RKE["K8s Secrets"]
            PODS_RKE["Application Pods"]
            ES_RKE --> CSS_RKE
            ESO_RKE --> ES_RKE
            ESO_RKE --> K8S_SEC_RKE
            K8S_SEC_RKE --> PODS_RKE
        end
        subgraph "GKE Cluster"
            ESO_GKE["External Secrets<br/>Operator"]
            CSS_GKE["ClusterSecretStore"]
            ES_GKE["ExternalSecret CRs"]
            K8S_SEC_GKE["K8s Secrets"]
            PODS_GKE["Application Pods"]
            ES_GKE --> CSS_GKE
            ESO_GKE --> ES_GKE
            ESO_GKE --> K8S_SEC_GKE
            K8S_SEC_GKE --> PODS_GKE
        end
    end

    subgraph "Akeyless Gateway Layer"
        GW1["Akeyless Gateway<br/>(Primary)"]
        GW2["Akeyless Gateway<br/>(Secondary)"]
        CACHE["Gateway Cache<br/>(Resilience)"]
        GW1 --- CACHE
        GW2 --- CACHE
    end

    subgraph "Akeyless SaaS Platform"
        API["Akeyless API"]
        SECRETS["Secrets & Keys"]
        AUTH["Auth Methods"]
        RBAC["Access Roles"]
        API --- SECRETS
        API --- AUTH
        API --- RBAC
    end

    CSS_RKE -- "K8s Auth +<br/>Secret Fetch" --> GW1
    CSS_GKE -- "K8s Auth +<br/>Secret Fetch" --> GW2
    GW1 --> API
    GW2 --> API
```

## Quick Start

1. Verify [prerequisites](docs/02-prerequisites.md) are met
2. Prepare your cluster: [RKE](docs/03-cluster-setup-rke.md) or [GKE](docs/04-cluster-setup-gke.md)
3. Configure [Akeyless K8s auth](docs/05-akeyless-auth-config.md)
4. Deploy [ESO with Akeyless provider](docs/06-eso-deployment.md)
5. Create your first [ExternalSecret](docs/07-secret-management.md)

For automated onboarding, jump to [Pipeline Automation](docs/08-pipeline-automation.md).

## Prerequisites Summary

- Akeyless account with admin access (or scoped role for auth method creation)
- Akeyless Gateway deployed and reachable from your clusters
- `kubectl` access to target clusters with `cluster-admin` privileges
- Helm v3.x installed locally or in CI
- Terraform >= 1.3 (for automation tracks)
- `akeyless` CLI installed locally

## Additional Resources

- [Akeyless Documentation](https://docs.akeyless.io)
- [External Secrets Operator Documentation](https://external-secrets.io/)
- [Akeyless Terraform Provider](https://registry.terraform.io/providers/akeyless-community/akeyless/latest/docs)
- [Akeyless Helm Charts](https://github.com/akeylesslabs/helm-charts)

## License

This project is licensed under the Apache License 2.0 -- see [LICENSE](LICENSE) for details.
