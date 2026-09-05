# springboot-gitops-eks — working notes

## What this is
Spring Boot 3.4 / Java 21 on AWS EKS 1.33, delivered by a strict two-loop model:
CI (GitHub Actions) owns Git, ArgoCD owns the cluster. Argo Rollouts drives
blue/green + Prometheus-analyzed canary. Monorepo: app/ chart/ gitops/ infra/.

## Environment (verified 2026-09-05)
- AWS account 241533126054 (user/talha), us-east-1, all probe checks ok.
- Quotas measured: 64 vCPU, **5 Elastic IPs**, 5 VPCs (1 default in use).
- GitHub connected. Marketplace: NO template matched — full generation.

## Decisions and why
- **Single NAT gateway**, not per-AZ: EIP quota is 5; per-AZ would eat 3 EIPs
  and ~$97/mo. Cost ~$32/mo instead. Trade-off: NAT AZ loss = no private egress.
- **EKS 1.33**: standard support window is 1.33–1.36. <=1.32 is extended support.
- **Spring Boot 3.4.1, NOT the scaffold's 4.1.1**. Initializr returned
  dependencies that DO NOT EXIST: spring-boot-starter-webmvc,
  spring-boot-starter-webmvc-test, spring-boot-starter-actuator-test.
  Real artifacts: spring-boot-starter-web + spring-boot-starter-test.
  Do not "restore" the scaffold pom.
- **micrometer-registry-prometheus is mandatory**: without it
  /actuator/prometheus does not exist and canary analysis has nothing to query.
- **OIDC scope**: platform injects static AWS keys for provision/destroy (TF
  backend is platform-managed — cannot change). App delivery path uses the OIDC
  role from terraform output ci_role_arn. Disclosed; user accepted.
- **Base images pinned to version TAGS, not digests.** Do not invent digests —
  a wrong digest fails with "manifest unknown". Dockerfile documents how to pin.
- **EKS access entries (authentication_mode=API)**, not the legacy aws-auth
  ConfigMap — hand-editing aws-auth is how people lock themselves out.

## Loop prevention (user's explicit requirement) — three independent layers
1. CI's image-tag commit carries `[skip ci]`.
2. app-delivery workflow ignores `gitops/**`.
3. CI has NO cluster credentials for app deploy.
Plus a 4th subtlety: ArgoCD ignoreDifferences on Rollout /spec/replicas, or
ArgoCD and the rollouts controller fight over the field forever.
Do not "simplify" by removing a layer.

## Things the validators caught (do not regress these)
1. **kubectl not installed in configure/verify.** `aws eks update-kubeconfig`
   writes a config file but does NOT install the client. Each job is a fresh
   runner. Fixed with azure/setup-kubectl@v4 in BOTH stages.
2. **AWS Load Balancer Controller was never installed** — I wrote its IAM role
   but no helm install. Ingress would have been inert and verify would time out
   with no ALB. Added to configure stage.
3. **Test asserted content type on a forwarded welcome page.** Spring maps "/"
   to a ParameterizableViewController that FORWARDS to index.html; MockMvc does
   not execute forwards, so content type is null by design. Fixed by asserting
   forwardedUrl("index.html") for "/" and fetching /index.html directly for the
   real HTML assertions. The app was always fine — the test was wrong.

## Pipeline shape
deploy: lint -> (test, security) -> build_push -> provision -> configure -> verify
app-delivery: app_test + app_security -> app_release (build/scan/push/bump tag)
- verify polls ArgoCD sync/health, NOT kubectl rollout status. Accepts
  Synced/Suspended too — a paused canary is working as designed, not stuck.
- configure/verify re-run `terraform init` + `terraform output` THEMSELVES.
  Never thread cluster name via job outputs: it embeds PROJECT_NAME (a secret)
  and GitHub silently DROPS such outputs -> empty string, confusing failure.

## Status: validated + rehearsed, ready to ship
- validate_project: PASS (41 files). Two "known issue may apply" warnings
  assessed and dismissed with reason (Alpine not Debian-apt; no @MockBean used).
- test_project: PASSED — 7 tests green.

## Progress
- [x] STEPS 1-8 complete (app, Dockerfile, infra, chart, gitops, workflows,
      README, validate + rehearse)
- [ ] STEP 9 push + secrets (NVD_API_KEY, GRAFANA_ADMIN_PASSWORD,
      ARGOCD_REPO_TOKEN — all require the repo to exist first)
- [ ] STEP 10 deploy. TWO PASSES REQUIRED:
      pass 1 provisions infra; AWS_CI_ROLE_ARN does not exist yet so the
      build_push stage CANNOT authenticate to ECR on the very first run.
      After provision, read `terraform output -raw ci_role_arn`, set it as a
      repo secret, then re-run. Explain this to the user BEFORE deploying.

## Open items for the user
- NVD_API_KEY: user must supply (free from nvd.nist.gov). Without it
  dependency-check is severely rate-limited and the security stage is slow.
- ARGOCD_REPO_TOKEN: user must supply a GitHub PAT with repo read scope.
- GRAFANA_ADMIN_PASSWORD: I generate (alphanumeric, >=20 chars, no specials).
