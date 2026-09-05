# springboot-gitops-eks

Spring Boot service delivered to AWS EKS through a DevSecOps + GitOps pipeline:
**code → test → image scan → ECR → ArgoCD → EKS → blue/green or canary → monitoring → rollback.**

---

## Architecture

```
Developer
   │ git push
   ▼
GitHub monorepo ──────────────────────────────────────────┐
   │                                                      │
   │ (app/** changes)                                     │ (gitops/** changes)
   ▼                                                      │
GitHub Actions  ── OIDC ──▶ AWS IAM role                  │
   │  test · build · Trivy image scan                     │
   │                                                      │
   ├──▶ push image ──▶ ECR (scan on push)                 │
   │                                                      │
   └──▶ commit new image tag to gitops/ [skip ci] ────────┘
                                                          │
                                                          ▼
                                                    ArgoCD (in cluster)
                                                          │ reconciles
                                                          ▼
                                   ┌──────────── EKS 1.33 ─────────────┐
                                   │  Argo Rollouts                    │
                                   │    blue/green  |  canary          │
                                   │        │              │           │
                                   │        ▼              ▼           │
                                   │   Spring Boot pods ◀── ALB        │
                                   │        │                          │
                                   │        ▼ /actuator/prometheus     │
                                   │   Prometheus ──▶ Grafana          │
                                   │        │                          │
                                   │        └──▶ canary analysis       │
                                   └───────────────────────────────────┘
```

The canonical diagram is [`.udap/architecture.d2`](.udap/architecture.d2).

---

## The two loops (and why deployment loops cannot happen)

This is the most important design property of the repository.

| | CI loop (push) | GitOps loop (pull) |
|---|---|---|
| Actor | GitHub Actions | ArgoCD |
| Trigger | commit under `app/**` | commit under `gitops/**` or `chart/**` |
| Writes to | **Git only** | **cluster only** |
| Never does | `kubectl apply`, `helm upgrade` on the app | write to Git |

CI builds an image and records *what should run* by changing one line in
`gitops/application-values.yaml`. ArgoCD notices and makes the cluster match.

**Three independent loop-prevention layers:**

1. CI's tag-bump commit contains `[skip ci]`.
2. The delivery workflow ignores changes under `gitops/**`.
3. CI holds **no cluster credentials for application deployment** — it is
   structurally incapable of deploying, so it cannot race ArgoCD.

Any one layer can be defeated by a future edit. All three together cannot.
Do not remove one because the other two look sufficient.

There is a fourth, subtler guard: ArgoCD `ignoreDifferences` on
`/spec/replicas` of the Rollout. Argo Rollouts changes replica counts during a
rollout; without this, ArgoCD would see drift and fight the rollouts
controller — two controllers, one field, flapping forever.

---

## Repository layout

```
app/                     Spring Boot 3.4 application (Java 21, Maven)
  src/main/java/...      Application + InfoController
  src/main/resources/    application.properties, static landing page
  src/test/java/...      JUnit tests (7, including a Prometheus endpoint test)
  Dockerfile             Multi-stage, non-root, layered JAR
chart/                   Helm chart
  templates/rollout.yaml         Argo Rollouts Rollout (blue/green + canary)
  templates/analysistemplate.yaml Prometheus-backed canary analysis
  templates/service.yaml         stable / canary / preview services
  templates/ingress.yaml         ALB ingress
  templates/servicemonitor.yaml  Prometheus scrape config
gitops/                  ArgoCD configuration
  root-app.yaml                  ArgoCD Application (app-of-apps entry point)
  application-values.yaml        THE CI→GitOps handoff (image tag lives here)
  values/argocd-values.yaml      ArgoCD install values
  values/monitoring-values.yaml  kube-prometheus-stack values
infra/                   Terraform (AWS)
  network.tf             VPC, 3 AZs, single NAT gateway
  eks.tf                 EKS 1.33 control plane, node group, addons, IRSA
  ecr.tf                 ECR repository + lifecycle policy
  oidc.tf                GitHub OIDC provider + scoped CI role
  lbc.tf                 AWS Load Balancer Controller IAM role
.udap/                   Platform contracts
  architecture.d2        Architecture source of truth
  pipeline.yaml          Pipeline spec — workflows are RENDERED from this
.github/workflows/       RENDERED — do not edit by hand
```

> `.github/workflows/*.yml` are generated from `.udap/pipeline.yaml`.
> Edit the spec, not the rendered files; the next render overwrites them.

---

## Progressive delivery

### Canary (default)

Traffic shifts 20% → 40% → 60% → 80% → 100% with a pause at each step. During
the pauses Argo Rollouts queries Prometheus:

- **success rate** — non-5xx responses over 2m, must stay ≥ 95%
- **p95 latency** — must stay ≤ 1.5s

Two consecutive breaches abort the rollout and return all traffic to the
stable version. No human needed.

This is the difference between a canary and a timer: without metric analysis,
"canary" just means shipping a bad version slightly more slowly.

### Blue/Green

Set `rollout.strategy: blueGreen` in `gitops/application-values.yaml`. The new
version deploys in full and is reachable on the **preview** service while zero
production traffic reaches it. Promotion is manual by default:

```bash
kubectl argo rollouts promote springboot-app -n springboot-app
```

The old ReplicaSet stays for 300s after promotion, so rollback is instant.

---

## Rollback — three levels

| Level | Mechanism | When |
|---|---|---|
| 1 | **Automatic abort** — Argo Rollouts reverts on failed analysis | Bad version caught by metrics |
| 2 | `kubectl argo rollouts undo springboot-app -n springboot-app` | Manual revert of the current rollout |
| 3 | Revert the tag in `gitops/application-values.yaml` and push | Git-auditable rollback; ArgoCD reconciles |
| 4 | Platform **Rollback to stable** | Reverts the repo to the last green deploy and redeploys |

Level 3 is the GitOps-correct one: the cluster state is whatever Git says, so
rolling back means changing Git. Levels 1–2 are faster for an in-flight rollout.

---

## Accessing the system

```bash
aws eks update-kubeconfig --name springboot-gitops-eks --region us-east-1

# Application URL
kubectl -n springboot-app get ingress springboot-app \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

# ArgoCD UI (ClusterIP by design — not exposed publicly)
kubectl -n argocd port-forward svc/argocd-server 8080:80
# then http://localhost:8080 (user: admin)
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d

# Grafana
kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80
# then http://localhost:3000 (user: admin, password: GRAFANA_ADMIN_PASSWORD secret)

# Rollout status, live
kubectl argo rollouts get rollout springboot-app -n springboot-app --watch
```

ArgoCD and Grafana are deliberately **not** internet-facing. Both are
admin-credentialed; exposing them is a Tier-2 decision that needs SSO in
front, not a default.

---

## Security posture

- **No long-lived AWS keys in the delivery path.** GitHub Actions authenticates
  via OIDC to an IAM role whose trust policy pins
  `repo:<owner>/<repo>:ref:refs/heads/main`. A wildcard there would let any
  repository on GitHub push to your registry.
- **Image scanning at two points.** **Trivy** scans the built image and fails
  the build on HIGH/CRITICAL *before* the push, so a vulnerable image never
  enters ECR. Trivy inspects OS packages **and** application dependencies —
  including the Spring Boot JARs — so Java CVEs are covered. **ECR scan-on-push**
  re-scans stored images to catch CVEs disclosed after the build.
- **Least-privilege IAM.** The CI role can push to exactly one ECR repository.
  The Load Balancer Controller uses IRSA bound to one service account.
- **Hardened pods.** Non-root (uid 10001), read-only root filesystem, all
  capabilities dropped, `RuntimeDefault` seccomp.
- **Private nodes.** Workers have no public IPs; egress goes through the NAT.

### Known gaps (deliberate, not oversights)

- **No source-level dependency scanner.** OWASP dependency-check was removed:
  without an NVD API key it ran 10–40 minutes and exceeded the stage timeout.
  Trivy's image scan covers the same Java CVEs at the deployed artifact. To
  reintroduce SCA cheaply, enable GitHub Dependabot alerts (free on public
  repositories) or add the dependency-check plugin back with an `NVD_API_KEY`.
- **HTTP, not HTTPS.** No custom domain, so no certificate. Add cert-manager +
  Route53 + ACM for TLS.
- **Base images pinned by tag, not digest.** The Dockerfile documents how to
  pin digests once pulled.
- **Public repository.** ArgoCD clones anonymously — no repository credential
  is stored in the cluster. If this repository is ever made private, add an
  `ARGOCD_REPO_TOKEN` secret and register it as an ArgoCD repository secret,
  or ArgoCD will fail to sync.
- **Single NAT gateway** — see cost note below.

---

## Cost

Roughly **$185/month** running continuously:

| Component | Monthly |
|---|---|
| EKS control plane | ~$73 |
| 2 × t3.medium nodes | ~$60 |
| NAT gateway (single) | ~$32 |
| ALB + ECR storage | ~$18 |

**Single NAT gateway** is a deliberate choice: the AWS probe measured an
Elastic IP quota of 5 in this account, and one NAT per AZ would consume 3 EIPs
and ~$97/month. Trade-off: losing the NAT's AZ removes private-subnet egress
until it is recreated. Nodes and the control plane remain spread over 3 AZs.

Use the platform's **Destroy** action to tear everything down; the repository
and all configuration survive, so redeploying later is a single action.

---

## Deployment order

1. **Provision** — Terraform builds the VPC, EKS, ECR, and the OIDC role.
2. Set `AWS_CI_ROLE_ARN` from `terraform output -raw ci_role_arn`.
3. **Configure** — installs the Load Balancer Controller, Argo Rollouts,
   kube-prometheus-stack and ArgoCD, then applies the root Application.
4. **Verify** — waits for ArgoCD to report Synced/Healthy, then probes the ALB.

Afterwards, every `app/**` commit runs the `app-delivery` workflow only.

> **First deploy is a two-pass bootstrap.** `AWS_CI_ROLE_ARN` is an *output* of
> the Terraform that runs in the same pipeline, so it cannot exist before the
> first provision. Run 1 builds the infrastructure; set the secret from
> `terraform output -raw ci_role_arn`; run 2 completes the delivery path.

## Required repository secrets

| Secret | Purpose | Who sets it |
|---|---|---|
| `AWS_CI_ROLE_ARN` | OIDC role for ECR pushes | After first provision, from `terraform output ci_role_arn` |
| `GRAFANA_ADMIN_PASSWORD` | Grafana admin login | Generated at setup |

`PROJECT_NAME`, `TF_STATE_BUCKET` and the AWS provisioning credentials are
injected by the platform.

---

## Local development

```bash
cd app
./mvnw spring-boot:run          # http://localhost:8080
./mvnw test
docker build -t springboot-gitops-eks:dev .
```
