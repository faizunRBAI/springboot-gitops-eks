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
   │ (app/** changes)                                     │
   ▼                                                      │
GitHub Actions ───────────▶ AWS                           │
   │  test · build · Trivy image scan                     │
   │                                                      │
   ├──▶ push image ──▶ ECR (scan on push)                 │
   │                                                      │
   └──▶ prints the image reference to promote             │
                                                          │
Developer commits the new tag to gitops/ ─────────────────┘
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

| | CI loop | GitOps loop (pull) |
|---|---|---|
| Actor | GitHub Actions | ArgoCD |
| Trigger | commit under `app/**` | commit under `gitops/**` or `chart/**` |
| Writes to | **ECR only** | **cluster only** |
| Never does | `kubectl apply`, `helm upgrade` on the app | write to Git |

CI builds and publishes an image. `gitops/application-values.yaml` records
*what should run*. ArgoCD notices and makes the cluster match.

**Loop prevention:**

1. CI cannot write to Git at all (see below), so it cannot trigger itself.
2. The delivery workflow ignores changes under `gitops/**`.
3. CI holds **no cluster credentials for application deployment** — it is
   structurally incapable of deploying, so it cannot race ArgoCD.

There is a fourth, subtler guard: ArgoCD `ignoreDifferences` on
`/spec/replicas` of the Rollout. Argo Rollouts changes replica counts during a
rollout; without this, ArgoCD would see drift and fight the rollouts
controller — two controllers, one field, flapping forever.

### Promoting a new image (the one manual step)

CI publishes the image and prints the reference in its job summary. To deploy
it, set the tag in [`gitops/application-values.yaml`](gitops/application-values.yaml)
and commit:

```yaml
image:
  repository: 241533126054.dkr.ecr.us-east-1.amazonaws.com/springboot-gitops-eks
  tag: <the tag printed by the app-delivery run>
```

ArgoCD reconciles the commit onto the cluster within minutes.

**Why this is not automatic.** Rendered workflows receive
`GITHUB_TOKEN` with `contents: read`, and the platform's pipeline spec has no
`permissions` key to raise it. A CI-side `git push` therefore fails:

```
remote: Permission to <owner>/<repo>.git denied to github-actions[bot].
fatal: ... The requested URL returned error: 403
```

The commit succeeds locally and only the push is denied, which makes this
failure look like something else entirely — worth knowing if you see it.

This remains GitOps: Git is still the single source of truth and ArgoCD is
still the only writer to the cluster. The tag bump is a deliberate commit
rather than an automated one. Restoring automation needs
`permissions: contents: write`, which requires platform support.

---

## Repository layout

```
app/                     Spring Boot 3.5 application (Java 21, Maven)
  src/main/java/...      Application + InfoController
  src/main/resources/    application.properties, static landing page
  src/test/java/...      JUnit tests (7, including a Prometheus endpoint test)
  Dockerfile             Multi-stage, non-root, layered JAR
  .trivyignore           Accepted vulnerability exceptions (dated, justified)
chart/                   Helm chart
  templates/rollout.yaml         Argo Rollouts Rollout (blue/green + canary)
  templates/analysistemplate.yaml Prometheus-backed canary analysis
  templates/service.yaml         stable / canary / preview services
  templates/ingress.yaml         ALB ingress
  templates/servicemonitor.yaml  Prometheus scrape config
gitops/                  ArgoCD configuration
  root-app.yaml                  ArgoCD Application (app-of-apps entry point)
  application-values.yaml        THE HANDOFF (image tag lives here)
  values/argocd-values.yaml      ArgoCD install values
  values/monitoring-values.yaml  kube-prometheus-stack values
infra/                   Terraform (AWS)
  network.tf             VPC, 3 AZs, single NAT gateway
  eks.tf                 EKS 1.33 control plane, node group, addons, IRSA
  ebs-csi.tf             EBS CSI driver + default gp3 StorageClass
  ecr.tf                 ECR repository + lifecycle policy
  oidc.tf                GitHub OIDC provider + scoped role (provisioned,
                         not currently used — see Security posture)
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
| 3 | Revert the tag in `gitops/application-values.yaml` and commit | Git-auditable rollback; ArgoCD reconciles |
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

- **Image scanning at two points.** **Trivy** scans the built image and fails
  the build on HIGH/CRITICAL *before* the push, so a vulnerable image never
  enters ECR. Trivy inspects OS packages **and** application dependencies —
  including the Spring Boot JARs — so Java CVEs are covered. **ECR scan-on-push**
  re-scans stored images to catch CVEs disclosed after the build.
- **Least-privilege IAM for in-cluster workloads.** The Load Balancer
  Controller and the EBS CSI driver each use IRSA bound to one service
  account, not node-level credentials.
- **Hardened pods.** Non-root (uid 10001), read-only root filesystem, all
  capabilities dropped, `RuntimeDefault` seccomp.
- **Private nodes.** Workers have no public IPs; egress goes through the NAT.
- **No secrets in Git.** All credentials are repository secrets referenced as
  `${{ secrets.NAME }}`; none are committed.
- **CI cannot write to the repository**, which removes an entire class of
  supply-chain risk — though here it is a platform constraint rather than a
  deliberate choice (see above).

### CI authentication: static keys, not OIDC — and why

**The pipeline authenticates to AWS with the platform's injected static
credentials.** GitHub OIDC was the intended design and the IAM infrastructure
for it is fully provisioned in [`infra/oidc.tf`](infra/oidc.tf) — an OIDC
provider plus a role whose trust policy is pinned to
`repo:<owner>/<repo>:ref:refs/heads/main` with a least-privilege ECR policy.

It is **not currently used**, for a platform reason rather than a design one:
OIDC requires `permissions: id-token: write` on the workflow job, and the
platform's pipeline spec has no `permissions` key. `write_pipeline` refuses it:

```
unknown key 'permissions' — allowed: [approval, env, id, kind, needs,
outputs, steps, timeout_minutes]
```

Workflow files are rendered from that spec, so the permission cannot be added
by hand either. Without it GitHub never mints an OIDC token:

```
It looks like you might be trying to authenticate with OIDC.
Did you mean to set the `id-token` permission?
Credentials could not be loaded: Could not load credentials from any providers
```

The same missing field blocks `contents: write`, which is why CI cannot commit
the image tag. **One absent capability, two consequences.**

**What this costs.** The static credentials were already in the job's
environment because the Terraform steps read remote state with them, so using
them for the ECR push adds no credential that was not already there. What is
lost is the *short-lived, repo-scoped* property of OIDC: the delivery job holds
long-lived account credentials rather than a 15-minute token scoped to one ECR
repository.

**To restore OIDC** once the platform supports job permissions: add
`permissions: { id-token: write, contents: read }` to the `build_push` and
`app_release` stages, then reinstate the auth step documented at the top of
`infra/oidc.tf`. Note that `unset-current-credentials: true` is required on
that step — static keys in the job environment otherwise take precedence and
OIDC is silently skipped, producing a confusing `sts:TagSession` error that
names the IAM user rather than the real cause. No Terraform changes are needed.

### Accepted vulnerability exceptions — REVIEW BY 2026-10-05

Three CVEs are suppressed in [`app/.trivyignore`](app/.trivyignore). This is a
**risk acceptance**, not a fix, and it is documented here so it gets reviewed
rather than forgotten.

| CVE | Severity | Issue |
|---|---|---|
| CVE-2026-65182 | **CRITICAL** | Tomcat security-constraint bypass |
| CVE-2026-65905 | HIGH | Tomcat DIGEST authentication replay bypass |
| CVE-2026-68525 | HIGH | Tomcat FORM authentication bypass |

**Why they are not fixed:** all three require Tomcat **10.1.58**. No released
Spring Boot version ships it — 3.5.16 (the newest stable) manages 10.1.55. The
project already moved 3.4.1 → 3.5.16 to close the *earlier* Tomcat advisories,
which it did; these were disclosed against the newer version. This is an
upstream release-timing gap.

**Why the practical exposure is limited:** all three bypass Tomcat's *own*
authentication and security-constraint machinery. This application defines no
security constraints, uses no DIGEST or FORM authentication, has no Spring
Security dependency, and serves only public endpoints (`/`, `/api/info`,
`/actuator/health`, `/actuator/prometheus`). There is no auth layer to bypass.

**This acceptance becomes invalid immediately if** Spring Security or any
authentication is added, any endpoint becomes access-controlled, or a
security-constraint / DIGEST / FORM login config is introduced. In those cases
remove the entries and upgrade Tomcat *first*.

**To retire it:** bump the Spring Boot parent once a release manages Tomcat
≥ 10.1.58, or set `<tomcat.version>10.1.58</tomcat.version>` in `app/pom.xml`
once that release is on Maven Central, then delete the entries. Enabling
GitHub Dependabot (free on public repositories) surfaces those bumps
automatically instead of via a failed deploy.

The severity threshold is **untouched** — every other HIGH/CRITICAL finding
still fails the build. Only these three IDs are suppressed, and the build
prints them in the job summary on every run.

### Known gaps (deliberate, not oversights)

- **CI uses long-lived AWS credentials** — see above.
- **Image promotion is a manual commit** — see above.
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

1. **Provision** — Terraform builds the VPC, EKS, ECR, EBS CSI and IAM.
2. **Build and push** — image built, Trivy-scanned, pushed to ECR.
3. **Configure** — installs the Load Balancer Controller, Argo Rollouts,
   kube-prometheus-stack and ArgoCD.
4. **GitOps handoff** — verifies the committed values are concrete and applies
   the ArgoCD root Application.
5. **Verify** — waits for ArgoCD to report Synced/Healthy, then probes the ALB.

Afterwards, every `app/**` commit runs the `app-delivery` workflow, which
publishes a new image and prints the tag to promote.

## Required repository secrets

| Secret | Purpose | Who sets it |
|---|---|---|
| `GRAFANA_ADMIN_PASSWORD` | Grafana admin login | Generated at setup |
| `AWS_CI_ROLE_ARN` | OIDC role ARN — set, but unused until the platform supports `id-token` | From `terraform output ci_role_arn` |

`PROJECT_NAME`, `TF_STATE_BUCKET` and the AWS credentials are injected by the
platform.

---

## Local development

```bash
cd app
./mvnw spring-boot:run          # http://localhost:8080
./mvnw test
docker build -t springboot-gitops-eks:dev .
```
