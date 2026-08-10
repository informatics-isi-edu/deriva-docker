# Unified DERIVA Deployment Architecture

*A unified architecture: one service blueprint rendered to local Compose (dev) and to AWS as either containers (ECS/Fargate) or VMs (EC2/AMI) -- from a single source. Supersedes the manual `aws-recipe-basic` EC2 recipe framework and the `deriva-docker` compose-on-EC2 stop-gap.*

**Status:** Draft Proposal

**Date:** 2026-07-15 (revised 2026-07-22)

> **Reading conventions.** `D#` is used throughout and referenced inline (e.g. "see [D11](#d11)"):
> a **Working Decision** -- a design choice this proposal has *made*. Because the Status is Draft, these are provisional directions, not final commitments. All are listed in the **Working Decisions** section.

## Executive Summary

#### _The problem:_
DERIVA can be deployed today by two disconnected mechanisms: `aws-recipe-basic`
(production; manual EC2 launches + copy-pasted shell recipes; drift by construction) and
`deriva-docker` Compose (local dev, plus a single-host EC2 stop-gap pressed into production
duty). Neither scales dynamically, survives instance failure, nor satisfies our NIST 800-53 / FedRAMP
Moderate compliance posture.

#### _The proposal:_
Unify both behind one environment-invariant _service blueprint_
(`services.yaml`) describing *what* each DERIVA service is within the deployed application stack. _Renderers_ turn that blueprint
into a concrete deployment target: local Compose (unchanged developer experience), and AWS
via CDK -- as Fargate containers or EC2/AMI virtual machines. On the AWS side, a
per-environment _environment blueprint_ is the other input: it tells CDK which of the
shared AWS foundation (ALB, VPC, RDS, S3, ElastiCache, KMS) to provision fresh versus
*adopt* from what already exists in a brownfield environment (e.g. FaceBase) -- environment
blueprint in, foundation out.

#### _What changes for the team:_
- One deliberate new tool: CDK in Python (our language). Everything else is already
  known (Docker, GitHub Actions, shell) or AWS-native.
- Deployments become `cdk deploy` + gated CI/CD promotions instead of CloudShell pastes and
  phase scripts; hosts are never mutated in place.
- Local Compose workflows are preserved; the recipe `lib/` knowledge is reused, not discarded.

#### _Lead principle ([D1](#d1)):_
When the target is AWS, lean fully into AWS-managed services -- ACM at
the public edge, Private CA + a cert agent for internal TLS, RDS/ElastiCache/Amazon MQ for the
data tier, Service Connect for discovery -- to shrink self-managed surface and inherit AWS's
control attestations.

#### _Key directions (rationale in Working Decisions):_
- [**D2**](#d2) -- deliberate AWS lock-in (portability lives in the blueprint contract, not our deployment).
- [**D8**](#d8) -- CDK-Python as the single new tool.
- [**D11**](#d11) -- internal TLS = app-terminated HTTPS from Private CA (Let's Encrypt kept for non-AWS).
- [**D14**](#d14) -- ALB-native ingress (Traefik is Compose-only).
- [**D15**](#d15) / [**D19**](#d19) -- managed data tier (RDS, ElastiCache Valkey; Amazon MQ optional per-deployment).
- [**D18**](#d18) -- hatrac on S3 exclusively.
- [**D21**](#d21) -- push-based, env-gated CI/CD (dev auto-deploys; staging/prod promotion-gated).
- **Phase 1 MVP** -- the web stack (ermrest/hatrac/chaise + credenza + full data tier); the hard part first, deliberately.

**For discussion** -- this is a proposal to read and debate. Push on the directions where you
disagree; genuine decision gates are flagged inline where they occur.

## Contents

Part I is the proposal, meant to be read top to bottom (roughly increasing in depth); Part II is
reference detail to consult as needed.

**Part I -- Proposal**
- Executive Summary
- Context / Goals / Non-Goals
- What This Supersedes
- Source-of-Truth Strategy
- AWS Cloud Target
  - Compliance Baseline (NIST 800-53 / FedRAMP Moderate)
  - Target Architecture
  - Ingress: ALB-native
  - Certificate & Internal TLS Strategy
- Service Inventory and Target Tiering
- Working Decisions (D#)
- Phased Plan
- Risks / Unknowns
- Next Steps

**Part II -- Reference & Deep Detail**
- Toolchain & Tool Justification
- Scope & Deliberate AWS Lock-In
- services.yaml Schema
- IaC Configuration Model
- Compute Targets (Fargate & EC2/AMI)
- Bring-Your-Own-Host / Direct-to-Linux
- Operations & DevOps
- Future Considerations
- Appendix A -- services.yaml blueprint (full example)
- Appendix B -- Environment blueprint (full example + create-vs-adopt contract)
- Appendix C -- Glossary

---

# Part I -- Proposal

The decision/design read. Part II (after Next Steps) holds the reference-grade detail:
schemas, the IaC configuration model, the compute/renderer mechanics, operations, and the
appendices.

---

## Context

DERIVA can be deployed today via **two separate mechanisms**, and this proposal is a
single unified substrate that supersedes both.

**A. `aws-recipe-basic` -- the real production mechanism (manual, EC2-only).** A shell
"recipe" framework (a modern refactor of the old ISRD `kvm` recipes). Operators hand-launch
EC2 via `awscli` in CloudShell (AMI id, instance type, ENI, instance profile), then run
Make-built phase scripts (`phase_01_configure_os` / `phase_02_user_setup` /
`phase_03_service_stack`) on the VM. Per-deployment dirs are copy-pasted from a
`base-template` over a shared `lib/` -- heavy duplication, drift by construction. It runs the
classic DERIVA-on-a-VM stack (Apache+WSGI ermrest/hatrac/webauthn, rabbitmq, postgres on
the VM, cantaloupe/IIIF, certbot, restic + cron backups, CloudWatch agent). Its own
README calls it *"a primitive replacement for interim operations... longer term, we might
adopt other cloud-oriented tools."* **This proposal is those tools.**

**B. `deriva-docker` -- Compose, for local dev + an EC2 stop-gap.** (1) Local development
orchestration via Docker Compose (legitimate, permanent). (2) A stop-gap that runs the same
Compose stack under `dockerd` on a single EC2 instance (via `docker-compose-*-aws.yml`
overrides); temporary, and doesn't scale horizontally, survive instance failure, or satisfy
our compliance posture.

## Goals

- One blueprint, many renderers: local Compose (dev) + cloud CDK (Fargate | EC2-AMI).
- IaC provisioning (create-or-adopt) replacing manual `awscli`/CloudShell launches and
  copy-pasted shell recipes.
- Horizontal scalability of the stateless application tier.
- Managed, resilient data tier (no databases/brokers/caches self-run on a single host);
  managed backups/DR replacing restic + cron.
- Production devops posture: health-based replacement, rolling deploys, centralized logging,
  managed secrets, CI/CD, scheduled ops.
- Compliance alignment: NIST 800-53 / FedRAMP Moderate -- the binding baseline.
- Keep local Compose intact and low-friction.
- Avoid heavyweight container-orchestration complexity and its operational overhead
  (self-managed Kubernetes with Argo/Helm is one representative example of what we'd like to avoid).

## Non-Goals

- Full coverage of every peripheral service on day one (Jupyter deferred).
- Preserving the EC2-docker AWS override files, or the copy-pasted `aws-recipe-basic`
  per-deployment dirs. **Both legacy mechanisms are superseded, not maintained in parallel.**
- Multi-region design (DR is in-scope via managed backups; multi-region revisit later).
- Cloud-agnostic / multi-cloud abstraction. AWS lock-in is deliberate; the portable
  `services.yaml` contract keeps the door open for others, but we do not build or operate a
  multi-cloud layer (see Scope & Deliberate AWS Lock-In).

---

## What This Supersedes

Two legacy mechanisms are unified into one substrate:

| Legacy mechanism                   | What it is today                                                                                                                   | Replaced by                                                                                                                                                                                               |
|------------------------------------|------------------------------------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **`aws-recipe-basic`**             | Manual `awscli`/CloudShell EC2 launch + Make-built shell phase scripts, copy-pasted per deployment over a shared `lib/`. EC2-only. | IaC foundation (CDK create-or-adopt) + one **service blueprint** + an **environment blueprint** per env; **`ec2-ami` compute renderer** ([D13](#d13)) is the direct modernization of its manual VM model. |
| **`deriva-docker` compose-on-EC2** | Compose stack under `dockerd` on a single EC2 host (dev overrides pressed into prod).                                              | **local Compose** (dev, kept) + **cloud CDK / Fargate** renderers from the same blueprint.                                                                                                                |

The cloud devops concerns `aws-recipe-basic` handles by hand map onto managed services (detailed
in Operations & DevOps):

| `aws-recipe-basic` (manual)            | Unified (managed / IaC)                                                                                    |
|----------------------------------------|------------------------------------------------------------------------------------------------------------|
| `awscli` in CloudShell, per-VM         | `cdk deploy` (idempotent), ASG/ECS rolls                                                                   |
| `phase_03_service_stack.sh` on the VM  | container image (Fargate) **or** golden AMI + user-data (EC2/AMI)                                          |
| copy-pasted per-deployment recipe dirs | one service blueprint + one environment blueprint per env (no drift)                                       |
| postgres on the VM                     | RDS (managed, SSL/KMS)                                                                                     |
| **restic + `databases_backup` cron**   | RDS automated backups + PITR; S3 versioning (hatrac)                                                       |
| **certbot** (Let's Encrypt)            | ACM on the ALB                                                                                             |
| `ermrest-purge` cron                   | EventBridge-scheduled task                                                                                 |
| CloudWatch agent (already used)        | CloudWatch / Container Insights (continuity)                                                               |
| daily/hourly in-place `dev-update`     | push-based CI/CD, immutable rollout (dev auto-deploys; staging/prod promotion-gated); no GitOps controller |

This is why the doc is framed as a deployment/devops architecture, not just a
containerization: it is the unified replacement for how DERIVA is actually shipped today.

---

## Source-of-Truth Strategy

Reject a "canonical manifest that renders both Compose and ECS" approach - it is a
bespoke orchestration compiler, the heavyweight undocumented complexity we are avoiding,
and it leaks because Compose is saturated with dockerd-specific semantics.

Instead: **share the contract, not the deployment.**

- Source of truth = container/AMI images and their runtime contract: image name/tag, ports,
  health-check endpoint, required env-var keys, dependency order, persistence class,
  public path prefix (for routing intent).
- Capture the stable contract in one narrow `services.yaml`.
- **Local Compose** (developer machine): a small generator emits a thin compose fragment
  (`services.generated.yml`: image/tag/ports/env-keys/depends_on) from `services.yaml`; the
  hand-authored per-service compose files `include`/`extends` that fragment and add the
  target-specifics (Traefik labels, socket-proxy, healthcheck details). So local Compose
  consumes `services.yaml` for the shared fields, and only the shared fields are generated.
- **Cloud CDK** (all cloud envs - dev/staging/prod): authored directly as thin per-service
  CDK-Python constructs that consume the same `services.yaml` (loop to emit a Fargate
  service + target group + ALB rules + derived security-group / mTLS (mutual TLS -- both
  ends present a cert) / IAM per entry).

Terminology: local Compose = the developer-machine renderer (Docker Desktop/dockerd);
cloud CDK = the single CDK codebase that renders every cloud environment (dev, staging,
prod), one per environment blueprint. The axis is local-vs-cloud, not dev-vs-prod - all of
dev/staging/prod are cloud CDK.
- **The service blueprint (`services.yaml`) is environment-invariant.** It never contains
  per-environment infrastructure identity (VPC IDs, ALB ARNs, SG IDs, account/region).
  Those live in a separate environment blueprint - see IaC Configuration Model.

Two honest artifacts, each owning its target's specifics, sharing a narrow contract.

### Prior art & alternatives considered (are we reinventing this?)

We are not inventing the *concept* of "one workload spec, many render targets" - it exists
as a standard: Score (score.dev, CNCF), whose `score.yaml` describes a workload's
runtime contract and is rendered by generators (`score-compose` -> docker-compose,
`score-k8s` -> Kubernetes). That is almost exactly our `services.yaml` idea, which is
evidence the abstraction is sound rather than over-built.

Why `services.yaml` exists as its own artifact: the two-renderer requirement - local
Compose and cloud CDK both consume it (Compose via a generated fragment; see above), and
neither can read the other's native format. An external, declarative spec is the only thing
that satisfies that; it is precisely why Score exists.

**Score evaluation outcome: not adopted.** Score's mature generators are compose
and k8s; there is no off-the-shelf ECS generator - you must build a custom binary (Go,
per Score's implementation guidelines) that emits ECS Task Definition JSON. That is a
bad fit: (1) emitting task-def JSON bypasses our CDK constructs - the create-or-adopt
foundation, ALB/target-group wiring, derived SG/mTLS/IAM, and the cdk-nag NIST-800-53
gate; (2) we would build the ECS integration ourselves anyway, in Go; (3) Score's
headline gift, `score-compose`, largely duplicates our kept compose files. So we keep our
own `services.yaml` and generate the thin Compose fragment ourselves.

**Helm evaluation outcome: not adopted.** Helm's chart format (`values.yaml` + templates)
is the closest well-known analog to `services.yaml`'s shape, but Helm the tool is
hard-wired to Kubernetes - its templates render Kubernetes manifests exclusively; there is
no Compose or ECS/CDK output mode, pluggable or otherwise (Score at least offers both).
Adopting Helm would not remove any of the renderer work we still have to build (Compose
fragment, CDK constructs); it would only bolt a K8s-specific templating engine onto a
pipeline that targets neither K8s (Kubernetes is out of scope; see Goals) nor benefits from
Helm's chart-repository/release-management machinery, which assumes a running cluster. So
the resemblance is evidence the *shape* is sound (as with Score), not a reason to adopt
the tool.

**External validation, not a reason to build EKS: a partner's independent deployment.** A
partner (CZI, `sci-deriva-integration/.infra`) runs DERIVA on EKS via a shared Helm chart
(`stack`) + per-env `values.yaml` + an invariant `common.yaml`, scaffolded by their `argus`
tool and deployed via ArgoCD - arrived at separately, that is exactly our service
blueprint / renderer / environment blueprint split, and the field mappings hold up against
real manifests (`image/tag` -> `image`+`resources`, `ingress.health` -> liveness/readiness
probes, `env.config`/`secrets`/`wired` -> `env:`/`secretKeyRef`, `depends_on.data` -> task
IAM -> IRSA, `ingress.public_path` -> ingress paths). It is not identical decomposition -
CZI runs DERIVA as one monolithic image where our ECS target splits out credenza/mcp/chatbot
- so what is portable is field *semantics*, not service topology. That makes a third
renderer target architecturally free (an additive plug-in to the renderer boundary,
[D7](#d7)), but Kubernetes itself stays out of scope: the partner's own stack shows the
operational cost concretely (ArgoCD force-sync every ~14 min, sync-waves, revision-keyed
migration Jobs, IRSA, CNI/ingress-controller) - exactly the heavyweight orchestration this
proposal avoids (see Goals). Building an EKS renderer is deferred; if ever pursued, the
right move is emitting `values.yaml` for the partner's existing chart, not standing up a
new K8s control plane.

Dead ends worth remembering: AWS Copilot manifests and Docker's `compose -> ECS`
integration both tried "simple service spec -> ECS" and both are now discontinued -
adopting an external framework carries abandonment risk too; a boring, in-repo, data-only
file we fully control can be *more* durable.

- **Guard rail:** `services.yaml` stays flat declarative data, never a DSL. The compose
  fragment generation emits only the narrow shared fields (image/tag/ports/env-keys/
  depends_on) - it is *not* the full codegen-both-targets compiler rejected in [D5](#d5); the
  target-specifics stay hand-authored per renderer. The moment the spec grows conditionals,
  expressions, or templating we have rebuilt that compiler. All logic lives in CDK Python.

---

## AWS Cloud Target

What follows -- compliance posture, network architecture, ingress, and internal TLS -- describes the AWS cloud-CDK renderer specifically. Local Compose and BYOH renderers do not carry this detail (see Compute Targets and Bring-Your-Own-Host / Direct-to-Linux in Part II).

### Compliance Baseline (NIST 800-53 / FedRAMP Moderate)

The binding baseline is NIST 800-53 / FedRAMP Moderate. dbGaP controlled-access is not a
current requirement -- no dbGaP data is stored on this substrate today -- but the controls below
are built to accommodate it should that change. This is a primary design driver, not an
afterthought. The move to AWS-native managed
services is partly motivated by inheriting AWS's control attestations and shrinking the
self-managed surface auditors scrutinize. Controls baked into the architecture:

- **Encryption at rest (SC-28):** KMS (Key Management Service) customer-managed keys
  (CMKs -- encryption keys we own and control) on RDS, S3 (hatrac), ElastiCache, EBS,
  SSM/Secrets Manager, and CloudWatch Logs.
- **Encryption in transit (SC-8), end-to-end including internal:** no cleartext
  HTTP anywhere, including inside the VPC. ALB->target uses HTTPS target groups; east-west
  service-to-service is app-terminated HTTPS from Private CA ([D11](#d11)), with Service Connect
  (ECS's built-in service-to-service networking) providing discovery; the managed data tier uses
  its own client-side TLS (RDS SSL, ElastiCache in-transit encryption + AUTH, Amazon MQ AMQPS, S3
  HTTPS). See Certificate & Internal TLS Strategy ([D11](#d11)).
- **Network isolation (SC-7):** ALB in public subnets; app and data tiers in private
  subnets with no public IPs; egress via NAT (managed outbound-internet gateway);
  VPC endpoints (private links to AWS services, keeping traffic off the internet) for S3
  (gateway), ECR, CloudWatch, Secrets Manager, SSM (interface).
- **Audit logging (AU family):** CloudTrail (management + S3 data events on
  controlled-access buckets), ALB access logs to S3, VPC Flow Logs, GuardDuty, AWS
  Config, Security Hub with the NIST 800-53 standard enabled.
- **Controlled-access data (S3/hatrac):** S3 Block Public Access, bucket policies,
  versioning, access logging, least-privilege IAM, KMS CMK; consider Object Lock.
- **Least privilege (AC-6):** per-service task roles; no shared broad roles.
- **Policy-as-code:** enforce with cdk-nag (a CDK add-on that fails the build on control
  violations) NIST-800-53-R5 pack at synth time.

Impact level: FedRAMP Moderate applies, so we deploy in commercial AWS
(FedRAMP-authorized services in a standard region, e.g. us-east-1/us-west-2) -- no
GovCloud. This keeps ElastiCache Serverless, ECS Service Connect, and Amazon MQ fully
available.

---

### Target Architecture

```
                                     Internet
                                        |
                           [ AWS WAF ] --> [ ALB ]                            public subnets
                                        |
                                        |   ACM TLS termination, HTTP -> HTTPS, TLS 1.3 policy,
                                        |   access logs -> S3, path routing per service,
                                        |   HTTPS re-encrypt to app-terminated PCA certs (D11)
                                        v
   private subnets
   -------------------------------- APP TIER -------------------------------------------
   per-service compute renderer (D13):   Fargate containers   OR   EC2 instances from AMIs

       apache                 credenza              mcp-core                mcp-ui
    (ermrest / hatrac /         (auth)            (MCP server)            (chatbot)
     chaise)
   ------------------------------------------------------------------------------------
         |                                                                        |
         |   east-west app <-> app:  app-terminated HTTPS, PCA mTLS (D11)          |
         |   discovery:  Service Connect (Fargate / ECS)   |   Cloud Map (EC2/AMI) |
         |                                                                        |
         |   per-service client-side TLS, direct to the managed data tier         |
         |   (NOT through the discovery layer):                                   |
         v                     v                     v                     v
       RDS                 ElastiCache            Amazon MQ               S3
    (postgres)          (Valkey serverless)       (RabbitMQ)           (hatrac)
    SSL / KMS           TLS + AUTH                AMQPS                 HTTPS + IAM

   managed data tier -- identical for both compute renderers
```

Principles (the diagram is renderer-agnostic; per-service `compute` selects Fargate or EC2/AMI
over the same foundation, [D13](#d13)):

- **Compute is a selectable renderer.** Per-service `compute`
  (fargate | ecs-ec2 | ec2-ami, [D13](#d13)) over the *same* ALB/VPC/SG/data-tier foundation; which
  renderer a deployment leads with is a deployment choice, not a fixed default. For the
  container path: ECS (AWS's container orchestrator) + Fargate (serverless containers
  -- AWS runs/patches the host VMs) + CDK-Python -- not Express Mode, not Copilot (Copilot EOS
  2026-06-12; Express Mode's per-service ALB fights shared ingress); durable primitive =
  ECS/Fargate service+task definitions. EC2/AMI is the same picture with ASG/instance targets
  behind the ALB (see Compute Targets).
- **ALB-native ingress (Traefik is Compose-only; see Ingress).** Compliance win: TLS (via
  **ACM** = AWS Certificate Manager, free managed certs), **WAF** (Web Application Firewall --
  filters malicious HTTP) and access-logs on AWS-attested managed services, and we delete the
  Docker-socket exposure.
- **App tier stateless and scale-safe.** Any per-instance disk state is a bug here.
- **Data tier fully managed** - the real scaling floor, and the source of managed backups/DR.

#### Service Connect: what it does, and what we don't use it for

Service Connect appears throughout as the east-west layer for the AWS container path, so, briefly:
it is ECS's built-in service-to-service networking. Enabling it injects a **sidecar** -- a helper
process that runs alongside the app inside the same task, handling networking on its behalf with
no app code changes -- built on **Envoy**, a widely used open-source network proxy, and provides
four things:
- discovery -- stable logical names (`credenza`, `ermrest`) resolvable within the namespace;
- client-side load-balancing across the healthy task replicas of a target;
- health-aware routing -- no traffic to draining or failing tasks;
- per-service metrics in CloudWatch, without app instrumentation.

It can *also* do mTLS between the sidecars (via Private CA) -- the one feature we decline, since
[D11](#d11) app-terminates TLS at the app instead. So here Service Connect answers "how does a service
find and spread load across the replicas of another," not encryption.

One consequence worth knowing: because the apps terminate their own TLS, Service Connect carries
those hops in L4 / TCP pass-through (its Envoy sees ciphertext), so discovery + load-balancing +
health still work but the rich per-request HTTP metrics thin to connection-level. Confirming that
pass-through is clean is the one integration detail to prove early.

If it isn't, the fallback is Cloud Map (DNS) + an internal NLB (or client-side load-balancing in
the apps) -- more moving parts and per-NLB cost, but it unifies with the EC2/AMI path, which has
no Service Connect and already uses Cloud Map. Keeping Service Connect on the Fargate path is
therefore a deliberate, lowest-effort choice ([D16](#d16)), not a hard dependency.

---

### Ingress: ALB-native (Traefik is Compose-only)

Current routing (from the Compose Traefik labels) and how it maps to ALB:

| Service      | Match today                   | Rewrite today                                     | ALB approach                                                                             |
|--------------|-------------------------------|---------------------------------------------------|------------------------------------------------------------------------------------------|
| apache/`web` | Host only (catch-all, prio 1) | HTTPS backend                                     | Default target group; HTTPS target group                                                 |
| keycloak     | `PathPrefix(/auth/)`          | none                                              | Optional/deferred (unused in prod); if enabled, path rule -> target group (native /auth) |
| mcp-core     | `PathPrefix(/mcp)`            | **stripPrefix** + well-known exact path           | Path rules; **app made prefix-aware** (no strip)                                         |
| mcp-ui       | `PathPrefix(/chatbot)`        | **stripPrefix** + root redirect                   | Path rule + ALB redirect action; **app prefix-aware**                                    |
| credenza     | `PathPrefix(/authn)`          | **stripPrefix** + **replacePathRegex** well-known | Path rules; **app prefix-aware** (removes rewrite hack)                                  |

The only gap is that ALB cannot stripPrefix or rewrite paths -- and every service that
needs it is first-party code we own (mcp-core, mcp-ui, credenza). apache/web and
keycloak already serve at native paths.

Resolution: make those three apps path-prefix-aware via a configurable base path
(FastMCP `root_path`, Flask `APPLICATION_ROOT`, mcp-ui base-path env) rather than relying
on proxy stripping. This is *more correct* anyway - a prefix-unaware app behind a
stripped prefix emits wrong redirect URLs and cookie paths. Credenza's `replacePathRegex`
well-known hack is direct evidence; once credenza knows its issuer path is `/authn`, it
serves the RFC 8414 metadata path correctly and the rewrite disappears.

Benefit: once apps are prefix-aware, both local Traefik and cloud ALB stop stripping, so
local/cloud routing behavior converges. Routing intent (public path per service) lives in
the shared contract; local Compose derives Traefik labels, cloud CDK derives ALB listener rules.

Watch-items (config, not blockers):
- **ALB idle timeout** raised for MCP streaming/SSE, LLM token streaming, and slow large
  hatrac uploads (relates to the deriva-py upload-timeout work). ALB has no request-size
  cap, so large hatrac PUTs are fine.
- **X-Forwarded-Proto** propagated so auth session cookies / OAuth redirect URIs stay https.

---

### Certificate & Internal TLS Strategy

Encryption in transit on every inter-service hop -- including internal, east-west VPC
traffic -- is a non-negotiable compliance requirement (SC-8): no cleartext HTTP anywhere. How
certificates are provisioned is a per-target renderer concern, with two distinct answers.

#### Two provisioning models, by target

| Target                                | Edge cert (north-south)                         | Internal cert (east-west)          | Mechanism                                                            |
|---------------------------------------|-------------------------------------------------|------------------------------------|----------------------------------------------------------------------|
| **AWS (Fargate / EC2-AMI)**           | ACM public cert on the ALB (native, unchanged)  | **AWS Private CA**, app-terminated | **PCA issue/renew agent** -- sidecar (Fargate) / systemd unit (EC2)  |
| **Non-AWS / BYOH** (dev/experimental) | **Let's Encrypt / ACME (certbot)** -- preserved | co-located or self-provisioned     | existing certbot + host cert paths (the `aws-recipe-basic` approach) |

The AWS internal path is the compliance-critical one and is detailed below. The non-AWS path
keeps DERIVA's current Let's Encrypt / certbot mechanism unchanged: BYOH is outside the
FedRAMP envelope ([D25](#d25)), so it is not held to the AWS internal-mTLS mandate, and its public edge
still uses ACME against a public CA exactly as today. Private CA is an AWS service, so it does
not apply off-AWS.

#### AWS internal TLS: app-terminated HTTPS from Private CA ([D11](#d11))

**Every service terminates its own HTTPS using a short-lived certificate issued by AWS Private
CA**, delivered and rotated by a small issue/renew agent. Uniform across Fargate and
EC2/AMI, it gives literal HTTPS on every hop and keeps private keys on the host.

*Why app-terminated rather than proxy-terminated.* ECS Service Connect can encrypt the
task-to-task hop at its managed Envoy sidecars (PCA-backed mTLS), leaving only the
app<->sidecar loopback (127.0.0.1, never on the wire) in cleartext. That is arguably
compliant, but (a) it is an auditor argument rather than a literal guarantee, and (b) it has
no analog on EC2/AMI, where there is no sidecar and east-west calls genuinely traverse the
network. App-terminated TLS is identical on both targets and removes the caveat. apache/`web`
already terminates HTTPS today (port 8443); credenza / mcp-core / chatbot flip from internal
HTTP to HTTPS, fed by the same agent.

*The agent* (the one genuinely custom component -- a few hundred lines of Python + boto3, or a
vendored equivalent):
1. **Generates the private key locally** and sends only a CSR to PCA -- the key never leaves
   the host (a real key-custody control, the same property ACM's ACME mode advertises).
2. **Issues** via PCA `IssueCertificate` (authorized by the task role / instance profile -- no
   static creds), polls `GetCertificate`, writes cert + chain to a shared path.
3. **Establishes trust** by writing the PCA root/chain to the local trust store, so peers
   validate one another against one internal root.
4. **Renews** on a timer before expiry, atomically swaps the files, and signals the app to
   reload (SIGHUP for apache; file-watch / reload for gunicorn / uvicorn). Renewal failure,
   clock skew, and reload signaling are the parts we own and must test.

*Packaging -- one codebase, two shapes* (the shared native-provisioning artifact, [D25](#d25)):
- **Fargate:** a sidecar container sharing a volume with the app; the app container waits
  on the first cert.
- **EC2/AMI:** the same logic as a systemd unit baked into the AMI.

*Connection topology:*
- **North-south (ALB -> app):** the app serves HTTPS with its PCA cert; the ALB re-encrypts to
  an HTTPS target group and does not validate the backend chain, so any cert satisfies it. The
  public edge cert stays ACM-native.
- **East-west (app -> app):** the caller resolves the peer via Service Connect / Cloud Map
  (Fargate) or Cloud Map / Route 53 (EC2) and connects to its HTTPS port, validating the
  peer cert against the shared PCA root. Because the apps now do TLS, Service Connect's role
  narrows to discovery (names / health / metrics), not TLS termination. Implementation detail
  to validate early: run Service Connect as discovery / L4 pass-through so app TLS flows
  through cleanly (else use raw Cloud Map DNS for those ports).
- **App -> managed data tier (RDS / ElastiCache / MQ / S3):** a client-side TLS connection
  to each managed endpoint (the `wired` value -- a per-env-resolved reference such as
  `rds.endpoint`; see services.yaml Schema), validating Amazon's CA -- *not* our Private
  CA and *not* through Service Connect: RDS SSL (RDS CA bundle), ElastiCache `rediss://` + AUTH,
  Amazon MQ AMQPS, S3 HTTPS + IAM. The app's trust store holds both roots -- the cert agent
  writes the PCA root (for peers); the RDS CA bundle is baked into the image (the others chain to
  public roots). This is the `depends_on.data` edge, distinct from `depends_on.services`.

*Encryption vs. mutual auth (deliberate layering).* Server certs on every service give HTTPS
on every hop -- the mandatory SC-8 baseline, met literally on both compute targets. Mutual
TLS (each server also requires + verifies the caller's client cert -> peer authentication; a
rogue task cannot impersonate ermrest to hatrac) is one config step further on the *same*
certs. apache does this readily; for gunicorn / uvicorn the server-only TLS is easy and
client-cert verification is the fiddlier per-framework piece. So encryption everywhere is the
baseline; mutual peer-auth is a labeled defense-in-depth increment, enabled per-hop, and it
grows in value once `web` is decomposed (more east-west legs -- see Future Considerations).

#### Why not ACM's new ACME support?

ACM added a managed ACME server (2026), so it is fair to ask whether it can issue our internal
certs. It cannot, for structural (not incidental) reasons:
- It issues only publicly-trusted certificates from Amazon Trust Services; internal service
  names (`credenza.deriva.local`) are not public domains.
- It requires public DNS domain validation -- there is no way to validate an internal-only
  name.
- It is not backed by AWS Private CA -- there is no internal trust chain or controlled peer
  set, which is exactly what east-west mTLS needs.
- Its certs cannot bind to the ALB or other managed services (the private key stays with
  the client) and are short-lived (45-day) *public* certs.

So ACM-ACME solves a different problem -- automating *public* certs on customer-managed
infrastructure -- which on AWS we already get natively via ACM on the ALB. It has no bearing on
internal service-to-service TLS. Where ACME / Let's Encrypt does remain the right tool is
the non-AWS / BYOH public edge (above), which is why that path is retained rather than
replaced.

*Cost / ownership.* PCA short-lived-cert mode (~$50/mo base + ~$0.058/cert) + one agent we own
and test + per-framework TLS config for the three HTTP apps + the Service-Connect-passthrough
detail. In exchange: literal HTTPS on every inter-container hop, one mechanism across Fargate
and EC2, keys never leaving the host, and no loopback caveat.

---

## Service Inventory and Target Tiering

| Compose service                                             | Role                    | Target on AWS                            | Notes                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
|-------------------------------------------------------------|-------------------------|------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `web` (apache: ermrest/hatrac/chaise; webauthn2 deprecated) | Core web/API            | **Fargate service**                      | **Phase 1 (MVP) - the baseline composition to validate; everything hinges on it.** Stateless over Postgres; HTTPS target group; scales horizontally. **webauthn2 is deprecated** - the shared code it currently provides to ermrest/hatrac moves into a `server-common` library module, after which webauthn2 is not a separate component. Future: decompose co-located ermrest/hatrac/chaise into per-service containers for defense in depth (see Future Considerations) |
| hatrac object storage                                       | Object store            | **S3 (exclusive)**                       | S3-only; unblocks multi-replica; FedRAMP data-protection controls on bucket                                                                                                                                                                                                                                                                                                                                                                                                |
| `database` (postgres)                                       | Primary DB              | **RDS (SSL enforced, KMS)**              | Read replicas later if ermrest read load demands                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `queue` (rabbitmq)                                          | Broker                  | **Amazon MQ (optional; per-deployment)** | Optional, first-class. ermrest change-notification is optional ermrest config (publishes to a fanout exchange; a no-op when unset), with no in-stack consumer today, so it is off by default. The blueprint always carries the optional `depends_on: mq` edge, so any deployment can enable it (`data.mq.mode`); provisioned only where enabled.                                                                                                                           |
| `credenza`                                                  | Auth broker / OAuth AS  | **Fargate service**                      | Made prefix-aware for `/authn`; stateless; session state in Valkey. **Phase 1 (MVP)** - co-deployed in the target use-case                                                                                                                                                                                                                                                                                                                                                 |
| `credenza-redis`                                            | Session + consent store | **ElastiCache Serverless (Valkey)**      | Low-ops + AWS-managed patching + encryption-by-default (reduces self-owned compliance scope); Multi-AZ. credenza has a native `valkey` backend. Store loss forces re-login/reconsent -- plus any ADR-0007 refresh/derived sessions -- an acceptable degradation that still argues for Multi-AZ + backups.                                                                                                                                                                  |
| `keycloak`                                                  | IDP                     | **Optional / deferred**                  | **No current production deployments use it** - not on the critical path. If ever needed: Fargate service + RDS, serves under `/auth` natively; consider a managed IDP instead of self-running Keycloak                                                                                                                                                                                                                                                                     |
| `deriva-mcp` (mcp-core)                                     | MCP server              | **Fargate service**                      | Made prefix-aware for `/mcp`; stateless (stateless_http=True); **Phase 2 add-on (gravy)**                                                                                                                                                                                                                                                                                                                                                                                  |
| `deriva-chatbot` (mcp-ui)                                   | Chatbot UI              | **Fargate service**                      | Made prefix-aware for `/chatbot`; stateless; **Phase 2 add-on (gravy)**                                                                                                                                                                                                                                                                                                                                                                                                    |
| `rproxy` (Traefik)                                          | Ingress                 | **Local Compose only**                   | The Compose reverse proxy; no cloud render target uses it -- cloud ingress = ALB + WAF + ACM                                                                                                                                                                                                                                                                                                                                                                               |
| `logging` (rsyslog + Loki/Promtail)                         | Logging                 | **CloudWatch Logs (KMS)**                | awslogs already used; work transfers                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| `monitoring` (Prometheus/Grafana)                           | Monitoring              | **CloudWatch + Container Insights**      | Revisit; managed Grafana optional                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `jupyter`                                                   | Notebooks               | **Deferred**                             | Per-user, stateful; likely stays on EC2 - do NOT block migration                                                                                                                                                                                                                                                                                                                                                                                                           |
| `ddns-updater`                                              | DDNS                    | **Drop**                                 | Route 53 makes it obsolete                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `groups`                                                    | Group mgmt              | TBD                                      | Confirm current role/dependencies                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `cantaloupe (IIIF)`                                         | Image server            | **Fargate service (per-deployment)**     | From the `aws-recipe-basic` fleet (not in deriva-docker compose); IIIF tile server, present in some deployments. scope: optional; stateless over S3/object store. Add to the blueprint when a target deployment needs it.                                                                                                                                                                                                                                                  |

---

## Working Decisions (D#) -- draft direction, not final

*Each `D#` is a decision this proposal has made (provisional while Draft); referenced inline elsewhere as "[D11](#d11)", "per [D21](#d21)", etc. Numbered by scope -- principles first, then blueprint, compliance, compute, operations, scope boundaries.*

### Guiding principles

#### D1

**Maximize AWS-native/managed surface when the target is AWS.** Prefer AWS-managed
services and native integrations to the fullest extent -- ACM at the public edge, Private CA +
the cert agent for internal TLS ([D11](#d11)), RDS/ElastiCache/Amazon MQ for the data tier, Service
Connect for discovery -- to shrink self-managed scope and inherit AWS's control attestations.
This is the lead principle behind [D10](#d10)/[D11](#d11)/[D14](#d14)/[D15](#d15)/[D16](#d16)/[D18](#d18)/[D19](#d19). It is distinct from [D2](#d2) (which
accepts the resulting lock-in) and bounded by [D3](#d3) (net-new *third-party* tooling still must
clear the bar -- hence Private CA + a boto3 agent rather than a new ACME server).

#### D2

**Deliberate AWS lock-in; unification, not a cloud-abstraction platform.** What we build
and operate is AWS-native/AWS-only, with no cloud-abstraction layer -- a conscious trade for
simplicity, a smaller toolchain, and inherited AWS compliance attestations. Portability lives
in the target-agnostic `services.yaml` contract, not our deployment: the BYOH/native path
([D25](#d25)) is genuinely cloud-independent and cheap, and a foreign-cloud renderer is *possible* for
others but not something we build. Cloud-agnostic multi-cloud as a first-class capability
would require the larger abstraction/orchestration systems this proposal exists to avoid. See
Scope & Deliberate AWS Lock-In.

#### D3

**Minimize net-new tooling; justify every tool.** The one deliberate new tool for the
core is CDK-Python (+ cdk-nag as a library). AMI baking uses AWS-native
EC2 Image Builder (configured via CDK, with managed CIS/STIG hardening components).
Host provisioning reuses shell (reused recipe `lib/`) -- not Ansible.
Prefer already-known or AWS-native tools; each new tool must clear a justification bar (see
Toolchain & Tool Justification).

### Blueprint & configuration model

#### D4

**`services.yaml` is the service blueprint + dependency graph.** Env-invariant;
references data tiers by resource class, injects per-env values via `wired`/`secrets`.
Its `depends_on` edges are the source of truth for security-group rules and the east-west
mTLS peer set. See services.yaml Schema.

#### D5

**No codegen-both-targets compiler.** Share the runtime contract via `services.yaml`;
cloud CDK consumes it directly, and local Compose consumes a generated thin fragment
(narrow shared fields only) that hand-authored compose overlays `include`. Generating the
narrow fragment is *not* the rejected full compiler - target-specifics stay per-renderer.

#### D6

**Two-axis IaC config:** the service blueprint (env-invariant `services.yaml`, external
YAML, read by both renderers) + an environment blueprint per env (CDK-native Python by
default; YAML only if ops-edited) with per-resource create-or-adopt. Brownfield resources
(an existing VPC + some SGs + hosted zone + hatrac S3 buckets) are referenced, never
managed; CDK owns only the net-new DERIVA layer. Keep both blueprints flat declarative
data, never a DSL. See IaC Configuration Model.

#### D7

**Formalize a renderer boundary; keep both blueprints target-agnostic.** The service
blueprint + environment blueprint are shared; each target (`compose-fragment`, `ecs-cdk`,
future `eks`) is a renderer plug-in. Validated by the partner's own blueprint/renderer/
environment-blueprint split (CZI argus
+ `stack` Helm chart + values.yaml). EKS is a portability property, not a plan to self-run
K8s; if built, the renderer targets the partner's existing `stack` chart values, not a new
control plane. Building any EKS renderer is deferred. See Source-of-Truth Strategy's
prior-art discussion.

#### D8

**IaC = CDK-Python**, with cdk-nag NIST-800-53-R5 enforced at synth.

### Compliance & security

#### D9

**FedRAMP Moderate -> commercial AWS (no GovCloud).** Standard region
(us-east-1/us-west-2). ElastiCache Serverless, Service Connect, and Amazon MQ are all
available.

#### D10

**Encryption in transit is end-to-end, including internal VPC traffic.** No
cleartext HTTP anywhere. East-west is app-terminated HTTPS from AWS Private CA via the
issue/renew agent ([D11](#d11)), not proxy-terminated; ALB->target uses HTTPS target groups; RDS
enforces SSL; ElastiCache uses in-transit encryption + AUTH. See Certificate & Internal TLS
Strategy.

#### D11

**Internal TLS = app-terminated HTTPS from AWS Private CA** (short-lived-cert mode),
delivered and rotated by an issue/renew agent -- a sidecar on Fargate, a systemd unit on
EC2/AMI (one codebase). Every service serves HTTPS; Service Connect narrows to discovery.
Mutual peer-auth is a labeled defense-in-depth increment on the same certs. Non-AWS/BYOH keeps
Let's Encrypt/ACME (certbot) for its public edge. ACM's ACME feature is public-cert-only and
cannot issue internal certs. See Certificate & Internal TLS Strategy.

#### D12

**Adopted resources are audited, not assumed.** A deploy-time preflight gate (SDK)
asserts adopted resources against the same control set (fail-closed, with documented
expiring waivers), and Config/Security Hub monitor drift continuously. Residual gap is
remediation authority, not detection.

### Compute & platform

#### D13

**Compute target is a swappable renderer axis** (`fargate` | `ecs-ec2` |
`ec2-ami`), per-service/per-env -- no fixed default; a deployment chooses. The foundation (ALB/VPC/SG/RDS/MQ/cache/S3) is
compute-agnostic - ALB target groups accept instance targets - and the blueprint contract
survives (`image`->AMI, env via user-data/SSM, `depends_on`->instance profile). No-containers
AMI costs: discovery/mTLS without Service Connect (-> Cloud Map) and OS/AMI patching
re-entering compliance scope (SI-2). The `fargate` and `ec2-ami` renderers are implemented
together over the shared foundation. See Compute Targets.

#### D14

**Ingress = ALB-native; Traefik is Compose-only.** Every non-Compose render target uses
the ALB; Traefik is the local-Compose reverse proxy and is absent from all cloud targets
(nothing to "retire"). Requires making mcp-core, mcp-ui, credenza path-prefix-aware.

#### D15

**Managed data tier:** RDS (postgres) and ElastiCache Serverless (Valkey, see [D19](#d19)) are
core. Amazon MQ (rabbitmq) is optional, per-deployment -- ermrest change-notification is
optional ermrest config, so Amazon MQ is provisioned only where a deployment enables it
(`data.mq.mode: none` otherwise); supported in every scenario, required in none.

#### D16

**Service discovery = ECS Service Connect** (Fargate path) for discovery +
client-side load-balancing + health across task replicas -- not TLS (east-west TLS is
app-terminated, [D11](#d11)), so Service Connect runs L4 pass-through. A deliberate, lowest-effort
choice, not a hard dependency: the fallback is Cloud Map + internal NLB (which the EC2/AMI path
already uses). See "Service Connect: what it does" under Target Architecture.

#### D17

**No ECS Express Mode, no Copilot.** ECS/Fargate primitives.

#### D18

**hatrac backend = S3 exclusively** (+ data-protection controls: BPA, KMS CMK, versioning,
access logging, least-privilege IAM).

#### D19

**credenza-redis = ElastiCache Serverless (Valkey).** Chosen for low ops and
reduced self-owned compliance scope (AWS-managed engine patching per SI-2/RA-5;
encryption at rest + in transit always-on and non-optional per SC-28/SC-8; Multi-AZ per
CP-10). Durability is a bonus, not the driver: losing the store forces re-login/reconsent
(acceptable degradation). Valkey removed the old 1 GB Serverless storage floor (now
~100 MB), so cost at this scale is roughly ~$6-12/mo + modest ECPU. Single node is
technically viable but forfeits the managed-patching/encryption-by-default compliance
benefits, so it is not preferred.

### Operations & delivery

#### D20

**Immutable-artifact config management.** Config is baked into the image (Fargate) or
golden AMI via EC2 Image Builder (EC2/AMI) + delivered via task-def/user-data/SSM; never applied to a
running host. No operator SSH -- break-glass is SSM Session Manager. Supersedes
`aws-recipe-basic`'s phase-script-on-host model and kills in-place `dev-update` drift.

#### D21

**CI/CD is first-class -- push-based, env-gated, no GitOps.** GitHub Actions build+scan
image/AMI -> ECR/register -> `cdk deploy`; gates = Amazon Inspector CVE scan + cdk-nag.
Deploy scope is a per-environment policy: dev auto-deploys on a configured branch/tag
trigger (default `main`);
staging/prod are promotion-gated (explicit
approval / change control), never auto-commit-to-deploy (FedRAMP CM fit). Same artifact
promoted dev->staging->prod. Immutable rollout via ECS rolling deploy / ASG instance-refresh;
no ArgoCD/reconciliation controller (that pull-based always-on infra is avoided per [D2](#d2)).
Replaces the `dev-update` timer with deploy-on-change.

#### D22

**Managed backups / DR** replace restic + cron: RDS automated backups + PITR + KMS
snapshots; S3 versioning for hatrac; Multi-AZ for availability. Multi-region deferred.

#### D23

**Scheduled ops:** infra crons (backups/cert-renew/rpm-cleanup) subsumed by managed
services and dropped; app-domain jobs (`ermrest-purge`) -> EventBridge-scheduled ECS tasks.

#### D24

**Secrets:** SSM Parameter Store SecureString (KMS) for config/secrets; Secrets
Manager only for the RDS master credential (native managed rotation).

### Scope boundaries

#### D25

**Bring-Your-Own-Host / Direct-to-Linux is a supported *dev/experimental* target.**
Configure the stack onto a pre-existing Linux host (local VM / bare metal / manual cloud VM):
containers via the Compose renderer over a remote Docker context, or native install via a
blueprint-generated shell script (reusing the recipe `lib/`, no new tool). The native
provisioning is one artifact shared with the EC2/AMI bake. Explicitly outside the compliance
envelope and the immutable-infra principle ([D20](#d20)) - not a production posture. Deferred.

#### D26

**EC2-docker AWS override files are disposable.**

---

## Phased Plan

### Implementation gap: distance to first real deploy

Honest status: **the architecture is largely settled; the implementation is at zero.** Every
decision maps to a concrete AWS primitive, so this is a real path -- but nothing is validated
until code runs. The first milestone is the Phase 1 web-stack MVP (detailed below); the
Phase 0 + Phase 1 items are the buildable artifacts to get there.

The web stack is the deliberate hard-part-first target: MCP/chatbot are lower-risk, additive
gravy, so validating them first would prove the easy path and leave the real risk unproven --
the stateful managed data tier, the Postgres->RDS and (create-mode) hatrac->S3 cutover, credenza
issuer-identity prefix-awareness, the east-west mTLS edges ([D11](#d11)), and both compute renderers.
Genuinely still open (not merely unbuilt): the brownfield-adoption inventory for any
adopt-mode target (subnets, exact hatrac buckets + posture) and a cost model -- neither
blocks starting.

### Phase 0 - Foundations and decisions
- Certificate strategy ([D11](#d11)): stand up Private CA (short-lived mode) + the issue/renew agent
  scaffold; decide whether to enable mutual peer-auth now or defer to `web` decomposition.
- `services.yaml` schema is defined + populated (this doc); materialize it as `deploy/services.yaml`.
- Stand up landing zone: VPC (public/private subnets, NAT), VPC endpoints, KMS CMKs,
  CloudTrail/Config/Security Hub (NIST standard), GuardDuty, ECR.
- Establish CDK-Python project + cdk-nag baseline.
- CI/CD baseline ([D21](#d21)): GitHub Actions -> build+scan image -> ECR -> `cdk deploy`.

### Phase 1 - MVP / POC: the web stack
Scope = ALB + WAF + the full managed data tier (RDS postgres, hatrac->S3, ElastiCache
Valkey) + apache `web` (ermrest/hatrac/chaise) + credenza. The container (Fargate)
rendering is the likely first cut; the EC2/AMI rendering of the same stack follows
immediately, or in parallel if a second dev takes it. This is the baseline composition that must
be validated; it is the harder path (stateful data tier, data cutover, auth) but it is the real
product, so it is the POC.
- Stand up the data tier: RDS (postgres, SSL/KMS, automated backups + PITR per [D22](#d22)),
  ElastiCache (Valkey) for credenza, hatrac->S3 (versioning + data-protection controls). Postgres
  dump/restore into RDS; hatrac object migration into S3 for create-mode envs (adopt-mode
  envs skip it).
- Make web routing + credenza path-prefix-aware; drop stripPrefix (credenza is the
  sensitive one - issuer identity - validate it here).
- One ALB (ACM, TLS1.3) -> HTTPS target groups (PCA app-terminated certs, [D10](#d10)/[D11](#d11)) -> Fargate
  services; east-west edges (ermrest/hatrac -> credenza, -> RDS, -> S3) over app-terminated
  HTTPS with Service Connect for discovery ([D11](#d11)).
- `ec2-ami` rendering of the same stack (immediately after Fargate, or in parallel): Launch
  Template / ASG / instance profile / user-data, ALB `instance` target groups, Cloud Map
  discovery, and the EC2 Image Builder AMI pipeline (recipe phase-scripts -> CIS/STIG-hardened,
  Amazon Inspector-scanned components). East-west mTLS here uses PCA certs without the Service
  Connect proxy ([D11](#d11)).
- Amazon MQ only if the deployment enables ermrest change-notification (optional; [D15](#d15)).
- Secrets in SSM; logs to CloudWatch (KMS). First CDK constructs become the template.

### Phase 2 - MCP / chatbot add-on (gravy)
- Additive on top of the running web stack: `deriva-mcp` + `deriva-chatbot` (stateless,
  lower risk). Make mcp-core (`root_path`) and mcp-ui (base path) prefix-aware.
- Their `credenza` dependency resolves to the co-deployed credenza (internal east-west edge);
  federating to a remote credenza via `--auth-hostname` stays a supported config variant.

### Phase 3 - Cutover and cleanup
- DNS cutover (Route 53); drop `ddns-updater`.
- Delete EC2-docker AWS override files.
- Monitoring/alerting via CloudWatch / Container Insights.

### Phase 4 - Deferred / hardening
- `web` decomposition for defense in depth (see Future Considerations).
- Per-service autoscaling policies; CI/CD hardening ([D21](#d21) -- rollback/canary); deploy strategy.
- Jupyter treatment (separate design). Keycloak only if a future deployment needs a
  self-hosted IDP. DR / multi-AZ posture review.

---

## Risks / Unknowns

- **App prefix-awareness work** (mcp-core, mcp-ui, credenza): scope and side effects on
  redirect URLs, cookie paths, OAuth issuer/redirect URIs. Credenza is the most sensitive
  (issuer identity). Validate against RFC 8414 metadata paths.
- **Internal TLS provisioning** ([D11](#d11)): the PCA issue/renew agent is a component we own
  (issuance, rotation, reload signaling); Private CA carries a monthly cost.
- **ALB idle timeout** vs MCP streaming and large hatrac uploads; tune and test.
- **Stateful data cutover:** Postgres -> RDS migration window (hatrac needs none where the
  bucket is adopted).
- **Cost modeling:** Fargate + ALB + RDS + Amazon MQ + ElastiCache + NAT + VPC endpoints
  vs the current `aws-recipe-basic` EC2 footprint.
- **Backup/DR validation ([D22](#d22)):** managed backups are only real once *restores* are
  rehearsed (RDS PITR restore, hatrac S3 version recovery) - schedule restore drills.
- **EC2/AMI-path surface ([D13](#d13)):** the golden-AMI pipeline (EC2 Image Builder + CIS/STIG),
  patch/refresh cadence, and non-Service-Connect discovery/mTLS are real ops+compliance work,
  delivered alongside the container path.

---

## Next Steps

Begin Phase 0 -> Phase 1 above. Nothing is blocked: the blueprint and both schemas are drafted
(env-keys, credenza backend, and health endpoints verified), so the first code is the
`deploy/services.yaml` lift plus the CDK skeleton for the web-stack MVP.

---

# Part II -- Reference & Deep Detail

Skip unless you are building against the design. Everything here is referenced from Part I:
the toolchain justification, the deliberate lock-in argument, the two blueprint schemas
(service + environment), the compute/renderer mechanics, the operational model, and the
worked examples in the appendices.

---

## Toolchain & Tool Justification

New tooling is a real cost (learning curve, maintenance, hiring, cognitive load). Principle
([D3](#d3)): minimize net-new tools; every new tool must clear a justification bar; prefer
already-known or AWS-native tools over new third-party toolchains.

| Tool                  | Team status                      | Used for                                                                                      | Verdict / justification                                                                                                                                                                                                                                                                                                                                    |
|-----------------------|----------------------------------|-----------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Python                | existing                         | everything                                                                                    | the team's language                                                                                                                                                                                                                                                                                                                                        |
| Docker / Compose      | existing                         | local dev renderer; BYOH-container                                                            | already used daily                                                                                                                                                                                                                                                                                                                                         |
| GitHub Actions        | existing                         | CI/CD ([D21](#d21))                                                                           | already used                                                                                                                                                                                                                                                                                                                                               |
| shell + Make          | existing                         | host provisioning (`aws-recipe-basic`)                                                        | already used; reused + blueprint-driven, not replaced                                                                                                                                                                                                                                                                                                      |
| awscli                | existing (manual)                | ad hoc                                                                                        | largely retired in favor of CDK                                                                                                                                                                                                                                                                                                                            |
| **CDK (Python)**      | **NEW -- the one core new tool** | IaC foundation + rendering the blueprint -> AWS ([D8](#d8))                                   | It *is* Python (no new language). Replaces manual awscli/CloudShell + copy-pasted recipes; enables cdk-nag. Alternatives are worse for a Python shop: raw CloudFormation (verbose, no loops), Terraform (new HCL language + state).                                                                                                                        |
| **cdk-nag**           | NEW (library, trivial)           | compliance gate at synth                                                                      | a `pip install` CDK plugin, not a separate toolchain; ships the NIST-800-53 pack                                                                                                                                                                                                                                                                           |
| **EC2 Image Builder** | NEW (YAML spec)                  | bake + harden golden AMIs (`ec2-ami`)                                                         | AWS-native, configured via CDK -- no new third-party tool. Ships AWS-managed CIS/STIG hardening components; the golden-AMI bake reuses the `aws-recipe-basic` phase-script logic as Image Builder components (see Compute Targets). Its build components are authored in a small YAML document schema (a new *format*, though not a standalone toolchain). |
| **Amazon Inspector**  | NEW (managed service)            | CVE scanning gate for container images (ECR) and AMIs (Image Builder), in CI/CD ([D21](#d21)) | AWS-native, no agents or infrastructure of our own to run; one service covers both the container and AMI compute paths. A third-party scanner (Trivy/Grype/Snyk) would mean operating a second scanning toolchain for no coverage gain.                                                                                                                    |

**Bottom line:** the one deliberate new tool for the core is CDK-Python (plus cdk-nag as a
library). AMI baking uses AWS-native Image Builder; host provisioning reuses shell (not
Ansible). Nothing else is net-new.

---

## Scope & Deliberate AWS Lock-In

The solution this proposal *builds and operates* is deliberately AWS-native and AWS-only, and
it does not attempt to be cloud-portable. The foundation is composed of AWS primitives with no
cloud-abstraction layer -- CDK/CloudFormation, the ALB, VPC, RDS, ECS/Fargate, Service Connect,
EC2 Image Builder, KMS, and cdk-nag -- together with the FedRAMP control attestations the
platform inherits. These are not portable to another cloud, by design ([D2](#d2)).

What remains portable is the thin *contract* -- the `services.yaml` blueprint -- not the
deployment we operate. Because the contract describes what the services are in a target-agnostic
way, additional renderers can be built against it without redesigning the service model. Two
directions illustrate the range, at very different cost:

- **Cloud-independent, low cost: the bring-your-own-host path.** The blueprint together with its
  generated native-install script ([D25](#d25)) can stand up DERIVA on any Linux host -- bare metal, a
  local VM, or a raw VM on any cloud -- with no AWS dependency and no orchestration platform at
  all. This is the one genuinely portable path that is inexpensive, because it reuses existing
  recipe knowledge.
- **Foreign-cloud renderer, high cost: possible, not ours to build.** A Google Cloud or Azure
  renderer (or a Terraform- or Kubernetes-based one) could be authored against the same
  contract. Doing so would require a full foundation for that platform, but the service model
  itself would not have to be re-derived. We do not build or maintain such a renderer; the
  design simply does not preclude one.

What we deliberately avoid is operating a cloud-agnostic abstraction ourselves. Genuine
multi-cloud deployment as a first-class capability would demand a substantially larger and more
complex system -- a portable orchestration and abstraction layer plus the toolchains to run it
(Kubernetes with Argo and Helm is one well-known example of this, though not the only approach)
-- which is disproportionate to a team of our size and to our current needs.

The proposal should therefore be read as a pragmatic unification for current needs, achievable
through a backwards-compatible, incremental effort rather than a ground-up platform build: local
Compose is preserved, the recipe fleet is modernized rather than rebuilt, and new tooling is
held to a single primary addition (CDK). AWS lock-in is accepted as a conscious trade for
simplicity, a smaller toolchain, and the compliance leverage of AWS's attestations -- while the
target-agnostic contract keeps a portability door open for others to walk through later.

---

## services.yaml Schema

The environment-invariant service blueprint. It declares **what** each service is and its
runtime contract, and nothing about **where** it runs (no VPC/ALB/SG IDs, no account/region,
no secret values). It is consumed by both renderers: local Compose and cloud CDK.

Each service references data-tier dependencies by resource class (`rds`, `cache`, `mq`,
`object_store`) - never by endpoint. The class is invariant (every env has an `rds`); the
foundation layer (from `environments/<env>.yaml`) resolves the actual endpoint and injects
it via a `wired` env key. That reference-by-class is what keeps this file env-invariant.

The full populated example (all five services) is in Appendix A.

### What each field drives (local Compose + cloud CDK)

| Field                                                                | Cloud (CDK)                                                                                       | Local (Compose)                      |
|----------------------------------------------------------------------|---------------------------------------------------------------------------------------------------|--------------------------------------|
| `image` / `tag`                                                      | task-def container image                                                                          | service image                        |
| `container.port` / `protocol`                                        | target group + Service Connect port                                                               | expose / healthcheck target          |
| `ingress.public_path` / `priority` / `root_redirect` / `extra_paths` | ALB listener rules + target group                                                                 | Traefik router labels                |
| `ingress.base_path_env`                                              | env var injecting the prefix (prefix-aware app)                                                   | same env var                         |
| `ingress.health`                                                     | target-group health check                                                                         | container healthcheck                |
| `persistence`                                                        | volume/EFS or managed-datastore binding                                                           | volume / bind mount                  |
| `depends_on.services`                                                | SG ingress rule (caller->callee:port), Service Connect client wiring, mTLS peer set ([D11](#d11)) | `depends_on` ordering + internal DNS |
| `depends_on.data`                                                    | SG rule app->data:port, wired env, least-privilege task IAM (e.g. S3 for hatrac, secret read)     | wired env / local service            |
| `env.config` / `secrets` / `wired`                                   | task-def `environment` + `secrets` (valueFrom SSM/SM) + foundation-computed                       | `env_file` / `environment`           |
| `scope`                                                              | included per env (keycloak excluded)                                                              | profile selection                    |
| `cpu` / `memory` / `desired_count`                                   | Fargate sizing + service count (autoscaling baseline; policies later)                             | (advisory)                           |

### Boundary and per-env overrides

- **Env-invariant here; env-specific there.** `services.yaml` never holds endpoints, IDs, or
  secret values. Anything per-env is either a `secrets` key (resolved from SSM/Secrets Manager)
  or a `wired` binding -- a reference the foundation resolves at deploy time from a small fixed
  vocabulary: `env.domain` (the env's public FQDN); `self.public_url` / `<service>.public_url`
  (= `env.domain` + that service's `public_path`, e.g. credenza -> `https://<host>/authn`); and
  `<resource>.endpoint` / `.bucket` (the data tier's actual address, resolved by class -- `rds`,
  `cache`, `mq`, `object_store` -- to a real instance). This is what replaces today's compose
  `${CONTAINER_HOSTNAME}` / `${AUTH_HOSTNAME}` interpolation, and it is why `services.yaml` can
  stay environment-invariant: the blueprint names *which* wired value it needs, never the value
  itself.
- **`tag`, `cpu`, `memory`, `desired_count`** are the fields most likely to differ per env
  (staging vs prod). `environments/<env>.yaml` may carry a small `service_overrides` block for
  these; everything else stays canonical here.
- **The dependency graph is the SG/mTLS source of truth.** `depends_on` edges are what the
  foundation turns into security-group rules and the east-west mTLS peer set.
- **Co-deployed vs external dependency (per-env).** A `depends_on.services` target is normally
  co-deployed (internal east-west edge -> SG rule + app-terminated mTLS ([D11](#d11)) + Service
  Connect discovery); the target use-case is self-contained (credenza runs in the deployment).
  But DERIVA also supports federating to a remote service (e.g. `--auth-hostname` points
  mcp/chatbot at an external
  credenza). When a dependency is external, its value comes from a config URL (no internal SG
  edge). The environment blueprint selects co-deployed vs external per dependency; the service
  blueprint declares the edge, the environment blueprint decides how it resolves.

Two open items remain: whether task images stay one-per-service or the `web` bundle is versioned
as a unit; and whether the prefix-awareness change moves each app's internal health path under
its `base_path` (which would shift the ALB target-group health-check path).

### Local values (`generate-env.sh`)

`services.yaml` holds env keys (`config`/`secrets`/`wired`), not values, so local Compose
still needs a values provider. The existing `generate-env.sh` re-scopes to fill exactly that
role: it sheds the composition/blueprint half (the `--enable-*` flags, image tags, ports,
dependency wiring -- now in `services.yaml`) and keeps supplying per-deployment local values
(hostname, LLM API key, cert paths, region/log-group, ports). It becomes the local counterpart
of the environment blueprint -- the same role on both sides of the local/cloud axis: cloud
values from the environment blueprint + SSM/Secrets Manager, local values from
`generate-env.sh`'s `.env`.

---

## IaC Configuration Model

There are two orthogonal blueprints; keeping them separate is what lets one CDK codebase
serve greenfield and legacy (brownfield) environments alike. The **service blueprint**
(`services.yaml`) says *what* each service is, once, for every environment. The
**environment blueprint** (`environments/<env>`) says *where/how* one specific environment
is wired -- the scaffolding around the services: VPC, ALB, SG, RDS, KMS, and whether each
is created fresh or adopted from what already exists. One service blueprint pairs with as
many environment blueprints as there are environments (dev/staging/prod/brownfield/...).

| Blueprint                                        | Answers                                                                                                                | Format                                                                                  | Varies by                     |
|--------------------------------------------------|------------------------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------|-------------------------------|
| **Service blueprint** (`services.yaml`)          | **What** services exist and their runtime shape (image, ports, health, public path, env keys, deps)                    | external YAML (must be read by both Compose and CDK)                                    | never (environment-invariant) |
| **Environment blueprint** (`environments/<env>`) | **Where/how** an environment is wired, and per foundational resource: **create** or **adopt** (+ id/arn when adopting) | **CDK-native Python by default** (typed dataclasses / context); YAML only if ops-edited | per environment               |

**Format asymmetry - deliberate.** The service blueprint is external YAML because two
renderers (Compose + CDK) must read it. The environment blueprint is consumed by
CDK only, so its natural form is CDK-native typed Python (dataclasses passed as
stack props, or CDK context) plus `from_lookup` for adopt - CDK already does this
create-or-adopt natively, with no parser or schema to maintain. Externalize it to an
`environments/<env>.yaml` only if non-developer operators must edit it without
touching Python; otherwise keep it in code. The YAML schema shown below is illustrative
of the *fields* either way - the same fields map 1:1 to a Python dataclass.

### Create-or-adopt is per-resource, not per-environment

The key requirement (typical of a brownfield environment): an environment is a mix. Often the
VPC exists and some security groups exist, but there is no ALB, no RDS, no Amazon MQ,
etc. So the environment blueprint declares a mode per foundational resource - not a
single global brownfield flag:

- adopt: VPC, selected existing security groups
- create: ALB + listeners, RDS, Amazon MQ, ElastiCache, new DERIVA security groups,
  target groups, ECS cluster/services, log groups

CDK has first-class primitives for both sides, so the same constructs handle create vs
adopt behind a uniform interface:

- VPC: `ec2.Vpc(...)` vs `ec2.Vpc.from_lookup(vpc_id=...)`
- ALB + listener: create vs `ApplicationLoadBalancer.from_lookup` / `ApplicationListener.from_lookup`
- SG: create vs `SecurityGroup.from_security_group_id(...)`
- Cert: issue via ACM vs `Certificate.from_certificate_arn(...)`
- DNS: create zone vs `HostedZone.from_lookup(...)`
- KMS: create CMK vs `Key.from_key_arn(...)`

A thin foundation layer resolves each resource (create or adopt) and returns the same
interface (`IVpc`, `IApplicationLoadBalancer`, listener, SGs, cert) to the service layer.
The service layer (driven by `services.yaml`) consumes those interfaces and never knows
which happened.

This create-vs-adopt duality is structurally the same one Terraform expresses via
`resource` blocks (create) versus `data` sources (reference existing) - brownfield IaC
needs it regardless of tool. We are not reinventing Terraform's model here; we are using
CDK's own native equivalent (`from_lookup` already plays the `data`-source role), which is
why choosing CDK-Python over Terraform (see Toolchain & Tool Justification) does not cost
us this capability - it comes for free.

### Proposed layout

```
deploy/
  services.yaml                 # env-invariant service blueprint (external YAML; read by Compose + CDK)
  gen-compose-fragment.py       # emits services.generated.yml (narrow shared fields) from services.yaml
  cdk/
    config/                     # environment blueprints as typed Python (DEFAULT)
      greenfield.py             #   create all foundational resources
      brownfield.py             #   adopt VPC + some SGs + zone + hatrac buckets; create rest
      dev.py
    foundation.py               # per-resource create-or-adopt; returns uniform interfaces
    service_stack.py            # instantiate services.yaml against the foundation
    app.py
  environments/                 # OPTIONAL: YAML form of the environment blueprint, only if ops-edited
    brownfield.yaml

# local compose (existing tree) includes the generated fragment:
#   services.generated.yml      # GENERATED from services.yaml (image/tag/ports/env/deps)
#   deriva/<svc>/docker-compose.yml   # hand-authored overlay: include: services.generated.yml + Traefik labels, etc.
```

(A full illustrative `environments/brownfield.yaml` is shown in Appendix B; the
environment blueprint is Python-by-default and only externalized to YAML if ops-edited.)

### Brownfield safety rules

1. **Reference, do not CloudFormation-import.** The `from_*` lookups give CDK a read-only
   handle; CDK attaches new resources to the adopted VPC/SGs without owning them. Do not
   bring legacy resources under stack management (invasive; risks `cdk destroy` touching
   infra we do not own).
2. **CDK owns only the net-new DERIVA layer.** Everything adopted is *referenced, never
   managed.* This boundary must stay crisp so tearing down a DERIVA deployment can never
   damage a legacy environment.
3. **Do not mutate adopted security groups.** Create new DERIVA SGs and reference adopted
   ones only as source/target; mark imported SGs immutable in CDK to avoid orphaned rules.
4. **Manage listener-rule priorities** when the ALB is adopted (only when a brownfield env
   already has an ALB -- many do not): allocate a reserved priority
   band to avoid colliding with existing rules.
5. **`from_lookup` needs resolvable account/region context** (cached in
   `cdk.context.json`); deterministic but a bootstrapping detail.

### Guiding principle: create where we can, adopt where we must - and audit either way

cdk-nag enforces controls on resources CDK creates (it inspects the synthesized
template; adopted `from_*` references have no body to inspect). So the default bias is:

- Adopt network scaffolding whose compliance is owned elsewhere: VPC, subnets,
  sometimes SGs, the hosted zone.
- Create anything that carries a control we must evidence: RDS, Amazon MQ, ElastiCache,
  ALB, WAF, KMS keys, log groups.

Exception - adopt a compliance-bearing resource when the data already lives there.
A brownfield environment often already has S3 hatrac buckets and a Route 53 hosted zone, so
those are adopted (migrating hatrac data out would be pointless and costly). Adopting the buckets
means no hatrac data migration.

For such an environment, then: adopt VPC + some SGs + hosted zone + hatrac S3 buckets;
create ALB / RDS / MQ / ElastiCache / KMS / WAF / log groups.

Adoption does not mean "assume and hope." Adopted resources are audited, not just
attested (see next section).

### Adopted-resource compliance auditing (fail-closed) - designed in from the start

Because cdk-nag can't see adopted resources, we add an explicit audit layer that inspects
their live configuration via the AWS SDK and asserts the same control set we enforce on
created resources. Three layers:

1. **Deploy-time preflight gate (fail-closed).** A pipeline stage (boto3) describes each
   adopted resource and asserts controls before `cdk deploy`. Examples mapped to NIST
   controls:
   - S3 hatrac bucket: `get_public_access_block` (BPA on), `get_bucket_encryption`
     (SSE-KMS/CMK), `get_bucket_versioning`, `get_bucket_logging`, bucket policy (no public
     grants) -> SC-28, AU, AC.
   - VPC: `describe_flow_logs` (enabled) -> AU.
   - Security groups: `describe_security_groups` (no 0.0.0.0/0 on sensitive ports) -> SC-7.
   - Hosted zone: query-logging config -> AU.
   - (RDS/MQ/cache if ever adopted: encryption, TLS, backups.)
   A violation fails the deploy by default, so DERIVA cannot be stood up on top of a
   non-compliant adopted resource.
2. **Documented waivers.** An explicit, expiring `waivers:` list (per control, per resource,
   with justification) downgrades a specific check from fail to warn - mapping to the
   FedRAMP deviation / POA&M concept. No silent exceptions.
3. **Continuous drift detection.** The compliance baseline already includes AWS Config +
   Security Hub (NIST 800-53 standard); scope those rules to include the adopted
   resources so posture is monitored continuously and drift raises findings/alerts. The
   deploy-time gate catches issues *before* standing up; Config catches drift *after*.

Output: a compliance report artifact (adopted-resource posture + waivers) for the SSP /
evidence package.

Honest residual risk: this gives us detection, evidence, and drift alerting, but not
remediation authority - the adopted resource is still owned by the brownfield environment
and we may not be able to fix a violation ourselves. So the audit converts a
silent inherited assumption into an explicit, monitored, fail-closed assertion; the
remaining gap is who fixes a deviation, not whether we detect it.

### Environment blueprint schema (fields; Python by default, YAML if ops-edited)

These are the fields of the environment blueprint regardless of form - a Python
dataclass by default, or the illustrative YAML in Appendix B if externalized for operators. Top-level
blocks: `env` (identity/tags), `network` (vpc/subnets/security_groups), `ingress`
(alb/certificate/waf/dns), `data` (rds/mq/cache/object_store), `platform`
(ecs/service_connect/kms/logging/secrets/private_ca), `compliance` (audit/waivers). Each
foundational resource carries a `mode: create | adopt`. Cross-links between resources use
logical names (e.g. an ALB references `security_group: deriva_alb`), which the
foundation layer resolves to created or adopted objects.

The full illustrative `environments/brownfield.yaml` and the per-resource create-vs-adopt contract table are in Appendix B.

### Invariants the foundation layer enforces (create or adopt)

- App-tier subnets always span >=2 AZs (near-zero cost; validate adopted subnet
  selections). Data-tier Multi-AZ (`multi_az`, a standby replica) is a per-environment
  config choice, not a universal gate -- expect `true` for staging/prod, optionally
  `false` for dev/experimental to cut cost.
- Created data/storage/log resources are encrypted with a CMK and, where applicable,
  TLS + AUTH on (cdk-nag NIST-800-53-R5 gate).
- Adopted SGs are immutable; DERIVA ingress/egress goes on created SGs.
- Adopted resources are referenced, never managed ([D6](#d6) boundary).
- Adopted resources are audited against the control set at deploy (fail-closed) and
  monitored continuously via Config/Security Hub (see Adopted-resource compliance auditing).

Per adoption, an operator inventories the target: subnet/AZ coverage per tier, the exact hatrac
buckets to adopt and their compliance posture (feeds the audit gate), and whether the env CMK is
adopt-or-create.

---

## Compute Targets (Fargate & EC2/AMI)

The foundation layer is compute-agnostic, so the compute target is a swappable renderer
concern - a service runs on Fargate containers or on EC2 instances from baked AMIs
over the same ALB / VPC / SG / RDS / Amazon MQ / ElastiCache / S3 / KMS / DNS / WAF
foundation, unchanged.

**Why it drops in:** an ALB target group targets EC2 instances (`target-type: instance`)
exactly as it targets Fargate IPs; the network + data foundation does not care what is
behind the target group. So the create-or-adopt foundation is reused wholesale; only the
compute/service rendering changes. This is the renderer boundary ([D7](#d7)) applied to the
*compute model*, not just the platform.

### Two distinct "EC2" options (very different effort)
1. **ECS on the EC2 launch type** - still containers, still ECS services/task-defs/Service
   Connect/cdk-nag, but on EC2 capacity you own (capacity provider + ASG) rather than
   Fargate-managed capacity. Near-trivial: keep everything, add a capacity provider. Right if
   the goal is "own the hosts."
2. **Plain EC2 + ASG + baked AMI (no containers)** - the service runs directly on the VM from
   a golden AMI (like DERIVA's legacy EC2 model). A genuine new compute renderer: Launch
   Template + ASG + instance profile + user-data; ALB target group of type `instance`.

### What the blueprint contributes (renderer-agnostic)
`container.port`/`protocol`, `ingress.health`, `public_path` -> ALB rules, `depends_on`
(-> SG rules + IAM), and `env.{config,secrets,wired}` all survive. Two things become
renderer-specific (same "packaging is per-target" principle as the EKS/CZI case): `image`/`tag`
resolves to an AMI id / build ref, and env injection is via user-data / SSM / instance
profile at boot instead of a task-def `environment`. `depends_on.data` derives an
instance profile instead of a task role; autoscaling maps to ASG target-tracking.

### Two real costs for the no-containers AMI renderer (option 2)
1. **Service discovery + east-west mTLS.** Service Connect ([D16](#d16)) is ECS-only, so non-ECS EC2
   uses Cloud Map (AWS's service-discovery registry) / Route 53 / internal NLB for
   discovery, and [D11](#d11) app-terminated mTLS must be
   solved without the Service Connect proxy (app-level TLS, a mesh, or Private CA certs baked
   into the AMI). Cloud Map registers both ECS tasks and EC2 instances, so it is the
   natural spanning layer for mixed-mode (some Fargate, some AMI).
2. **OS patching / AMI hardening re-enters our compliance scope.** Fargate gave managed OS
   patching (NIST controls SI-2 flaw-remediation / RA-5 vuln-scanning) for free; AMIs mean
   owning a golden-image pipeline (AWS EC2 Image Builder -- AWS-native, driven from CDK,
   no new tool -- with AWS-managed CIS/STIG hardening components; CIS/STIG = published OS
   hardening baselines), Amazon Inspector CVE scanning, and an AMI-refresh + rolling-replace
   cadence - all of which must be evidenced. cdk-nag's rule set shifts to EC2/ASG/EBS. A real
   trade: VM control + a hardened-image attestation vs Fargate's managed-scope reduction.

**How Image Builder reuses the recipes.** An Image Builder pipeline bakes a golden AMI from an
image recipe (a base image + an ordered list of components -- small YAML build documents)
plus a validation stage, then distributes the resulting AMI. This is where the existing
`aws-recipe-basic` provisioning knowledge is reused rather than discarded: the phase-script logic
that configures the stack today becomes Image Builder components, layered under AWS-managed
CIS/STIG hardening (Operations & DevOps has the per-phase mapping). It is the *same* native
provisioning shared with the direct-to-Linux target ([D25](#d25)) -- so Image Builder does not replace the
recipes, it repackages them as an immutable, hardened, Amazon Inspector-scanned, versioned
image built off the host rather than mutated onto it ([D20](#d20)).

### Per-service (mixed-mode)
Because both attach to ALB target groups and share the SG/IAM derivation, `compute` is a
per-service (or per-env) selector (`fargate | ecs-ec2 | ec2-ami`); the CDK picks the
compute renderer while the foundation stays shared. So the stateless app tier can run on
Fargate while a specific component runs on a hardened AMI; the data tier is identical either
way. This also gives a gentler on-ramp for any DERIVA service not ready to containerize -
same VPC/ALB/RDS/SG plumbing, VM compute.

Both compute renderers ship together over the shared foundation: Fargate and the
`ec2-ami` renderer (Launch Template / ASG / instance-profile / user-data + Cloud Map
discovery + the EC2 Image Builder AMI pipeline). `ecs-ec2` (ECS on owned EC2 capacity) is a
near-trivial capacity-provider variant of the Fargate path.

---

## Bring-Your-Own-Host / Direct-to-Linux (dev/experimental target)

Preserve the most primitive capability of the legacy recipes: configure and deploy the
stack directly onto an existing Linux host -- a dev's local VM, bare metal, or a hand-made
cloud VM -- with no IaC provisioning. This same host-configuration pattern is how some devs
ran a stack on a local VM or bare metal -- and, via `aws-recipe-basic`, how legacy
*production* EC2 instances were provisioned too (manually launch the VM, then run the phase
scripts on it). In the unified model its *production* use is superseded by the IaC-provisioned,
immutable EC2/AMI renderer; what survives here is the dev/experimental convenience of
pushing the stack onto an arbitrary existing host -- a fourth target.

Separate *packaging* (containers vs native) from *who owns the host* (IaC-provisioned vs
bring-your-own). Two flavors:
- **Containers on the host** -- install Docker/Podman and run the stack. Already covered: the
  local Compose renderer pointed at a remote host (Docker context over SSH, or copy the
  generated compose fragment to the box). Essentially free.
- **Native install (no containers)** -- rpm/dnf + apache/wsgi + systemd, as `aws-recipe-basic`
  does today. Handled by a blueprint-generated host-provisioning shell script that reuses
  the recipe `lib/` knowledge. No new tool (Python generator emitting shell -- both known).

The full target matrix:

|                         | Container packaging                                     | Native packaging                                     |
|-------------------------|---------------------------------------------------------|------------------------------------------------------|
| **IaC-provisioned AWS** | Fargate / ECS-on-EC2                                    | EC2/AMI (Image Builder-baked)                        |
| **Bring-your-own host** | local Compose (laptop, or remote VM via Docker context) | **direct-to-Linux** (shell provisioning on the host) |

**Shared native-provisioning artifact.** The native install is defined once (blueprint-
driven shell -- the modernized recipe phase scripts) and reused by two consumers: the
EC2/AMI bake (as Image Builder components) and direct-to-Linux (run on the host). Same
logic, two targets, still no new tool. So the EC2/AMI bake and bare-metal (direct-to-Linux)
provisioning come from one artifact -- building either gives most of the other for free.

**Boundary (why it's dev-only, not production).** Configuring a mutable, pre-existing host is
the opposite of immutable infrastructure ([D20](#d20)) and sits entirely outside the AWS-managed
compliance envelope -- no cdk-nag, no managed patching, no ALB/WAF, no IaC audit trail. So
it is a developer / experimental / bare-metal convenience, not a FedRAMP Moderate production
posture. Deferred; build only if the dev demand is real. ([D25](#d25))

---

## Operations & DevOps

The dimensions `aws-recipe-basic` handles manually, redesigned around managed services and
immutable artifacts. This is what makes the proposal a *deployment/devops* architecture, not
just a service topology.

### Configuration management (immutable artifacts, not host mutation)
Config is built into the artifact, never applied to a running host -- the opposite of
"transfer phase scripts to the VM and run them." Three layers:
- **App runtime config** -> the blueprint's `env.{config,secrets,wired}` (already defined),
  delivered as task-def env + SSM/Secrets Manager (Fargate) or user-data + SSM (EC2/AMI).
- **OS + service config** (httpd/wsgi conf, systemd units, cantaloupe, SELinux) --
  `aws-recipe-basic`'s `phase_01`/`phase_03` territory -> baked into the container image
  (Fargate) or the golden AMI via EC2 Image Builder (EC2/AMI). `phase_03_service_stack` becomes an
  image/AMI *build*, gated by cdk-nag + Amazon Inspector CVE scan.
- **Bootstrap/identity** (accounts, sshkeys, sudoers) -- `phase_02` -> largely obsolete:
  no operator SSH to disposable hosts; break-glass is SSM Session Manager (audited
  browser/CLI shell to a host -- no SSH keys or open ports). Least-privilege via task role /
  instance profile.

Principle ([D20](#d20)): immutable infrastructure -- a version change is a new image/AMI +
redeploy, not an in-place edit. This kills the daily/hourly in-place `dev-update` drift.

### Backups & DR (managed, not restic + cron)
- **Postgres -> RDS automated backups + PITR** (point-in-time recovery -- restore to any
  moment in the retention window) + KMS-encrypted snapshots (optional cross-region
  snapshot copy). Replaces `databases_backup` cron / pg_dump.
- **hatrac -> S3 versioning** (a data-protection control) + optional replication. Replaces
  restic of the object store.
- **credenza Valkey -> ElastiCache backups** -- nice-to-have (store loss = re-login, [D19](#d19)).
- App tier is stateless -> nothing to back up.
- DR posture: Multi-AZ (a standby in a second availability zone with automatic failover;
  RDS / ElastiCache / ALB) for availability + managed snapshots for recovery; multi-region
  deferred (Non-Goal). DR becomes a managed-service property, not a self-run restic workflow. ([D22](#d22))

### Observability & scheduled ops
- **Logs -> CloudWatch Logs (KMS)**; Container Insights (per-container metrics; Fargate) /
  CloudWatch agent (EC2/AMI) -- continuity with the recipe fleet's existing agent.
- **Metrics/alarms -> CloudWatch alarms + dashboards**; compliance posture via Config +
  Security Hub (NIST standard, from Compliance Baseline).
- **Scheduled ops:** the recipe crons split -- infra crons (`databases_backup`,
  `certbot-renew`, `erase-rpms`) are subsumed by managed services (RDS backups, ACM,
  immutable images) and simply disappear; the few app-domain jobs (`ermrest-purge`)
  become EventBridge (AWS's event bus + cron-like scheduler) -scheduled ECS tasks (or
  Lambda). ([D23](#d23))

### Lifecycle & operator workflow
- Replace "launch VM (awscli) -> scp scripts -> run phases -> destroy/repeat" with:
  `cdk deploy` (idempotent, create-or-adopt) to provision/update; ECS rolling deploy
  or ASG instance-refresh to roll new versions; `cdk destroy` tears down only the
  net-new DERIVA layer (adopted resources untouched, [D6](#d6)).
- **No SSH / no `operator_key_name`**: SSM Session Manager for audited break-glass.
- **Environments** (dev/staging/prod) are environment-blueprint inputs to one CDK app -- not
  copy-pasted per-deployment dirs.

### CI/CD -- push-based, env-gated, no GitOps controller (first-class; [D21](#d21))
This is how we replace `aws-recipe-basic`'s daily/hourly in-place `dev-update` (a *timer* that
mutated running hosts) without a GitOps controller like ArgoCD -- a pull-based reconciliation
controller is exactly the always-on infrastructure this proposal avoids ([D2](#d2)).

- **Push-based and event-driven, with per-environment deploy controls.** GitHub Actions builds
  + scans on merge/tag, but how far a build auto-deploys is an environment policy, never a
  global one:
  - **dev auto-deploys on a configured trigger** -- a branch or tag pattern per environment
    (default `main`, overridable to any branch/tag) -- the continuous "track latest" behavior
    `dev-update` provided, done immutably.
  - **staging and prod are promotion-gated** -- an explicit, approved release (manual approval /
    protected-environment gate / change ticket), never automatic commit-to-deploy. Each
    environment defines who may deploy and under what approval. This also satisfies FedRAMP
    change-management (CM) expectations for controlled production changes.
  The same artifact is promoted dev -> staging -> prod; only the environment blueprint and
  the gate differ.
- **The rollout is a replacement, not a mutation.** `cdk deploy` (or `ecs update-service
  --force-new-deployment`) drives an ECS rolling deployment -- a new task set is
  health-checked and swapped in (zero-downtime), old tasks torn down -- or, on the AMI path, an
  ASG instance-refresh onto the new AMI. The running artifact is *replaced*, never edited in
  place. That is the immutability ([D20](#d20)).
- **Nothing runs between deploys.** Unlike a GitOps model (an always-on controller
  continuously reconciling to git -- e.g. ArgoCD's ~14-min force-sync at the partner),
  push-based CI/CD has no reconciliation controller to operate; ECS/ASG perform the rollout
  natively. Continuous delivery with no always-on orchestration control plane -- one reason ECS
  (with built-in rolling deploys) fits.
- **Gates:** image/AMI Amazon Inspector CVE scan + cdk-nag NIST-800-53-R5 at synth, plus
  the per-env approval gates above. Rollback/canary detail remains iterative.

---

## Future Considerations (deferred, non-blocking)

### Web-container decomposition for defense in depth
The apache `web` container currently co-locates ermrest, hatrac, and chaise under a
single Apache process. (webauthn2 co-locates today but is deprecated; its shared code is
moving into a `server-common` library linked by ermrest/hatrac, so it does not survive as
a separate component.) Not required now, but a future defense-in-depth step is to split
the remaining services into individual Fargate services, each with:
- its own least-privilege task IAM role (e.g. only hatrac touches the S3 data bucket),
- its own security group / network policy and blast-radius isolation,
- independent scaling and patching.

Implications to plan for (the container split is the easy part; these are the real work):
- It multiplies east-west service-to-service legs, strengthening the case for mTLS
  via a private internal CA (see [D11](#d11)).
- Inter-service trust that is currently implicit in co-location (shared host, localhost
  calls, the shared auth code now folding into `server-common`) must become explicit:
  authenticated mTLS + per-service authorization. Map the ermrest <-> hatrac call patterns
  before splitting.
- Sequence in Phase 4, after the web-stack MVP and MCP add-on; do not block the initial
  migration on it.

---

## Appendix A -- services.yaml blueprint (full example)

The populated blueprint for the current service set. Field semantics: see *services.yaml
Schema* in Part II.

```yaml
# services.yaml (environment-invariant)
version: 1

defaults:                       # applied unless a service overrides
  compute: fargate              # fargate | ecs-ec2 | ec2-ami; per-service/per-env override -- see Compute Targets
  cpu: 512
  memory: 1024
  desired_count: 2
  health: { interval_seconds: 30, healthy_threshold: 3 }

services:
  web:                                              # apache: ermrest/hatrac/chaise
    image: informatics-isi-edu/deriva-web
    tag: "2026.1"                                   # canonical version; per-env override allowed
    scope: core                                     # core | optional
    container: { port: 8443, protocol: https }      # backend scheme (apache is https + skipVerify)
    ingress:
      public: true
      routing: catch-all                            # catch-all (default rule) | prefix
      priority: 1                                    # ALB rule ordering (catch-all is the fallback)
      health: { path: /healthcheck.txt, port: 8443, protocol: https }   # path verified from compose healthcheck; in-container port 8443 is target design (final port set at image build)
    persistence: managed-datastore                  # ephemeral | volume | managed-datastore
    depends_on:
      data:
        - { resource: rds, port: 5432 }             # ermrest -> postgres  (SG rule + wired)
        - { resource: object_store }                # hatrac -> S3         (task IAM, no SG)
      services:
        - { name: credenza, port: 8999 }            # -> auth              (SG rule + mTLS peer)
    env:                                            # extracted from deriva/web/docker-compose.yml + generate-env.sh
      config:  [DEPLOY_ENV, CREATE_TEST_DB, ERMREST_ADMIN_GROUP, HATRAC_ADMIN_GROUP,
                AUTHN_SESSION_HOST, AUTHN_SESSION_HOST_VERIFY, POSTGRES_USER]
      secrets: [POSTGRES_PASSWORD, POSTGRES_ERMREST_PASSWORD, POSTGRES_HATRAC_PASSWORD,
                POSTGRES_WEBAUTHN_PASSWORD, POSTGRES_DERIVA_PASSWORD]
      wired:
        CONTAINER_HOSTNAME: { from: env.domain }
        POSTGRES_HOST:      { from: rds.endpoint }
        HATRAC_S3_BUCKET:   { from: object_store.bucket }   # NEW: S3 backend (D18); not in current compose (local fs)
    # bundled-credenza mode adds CREDENZA_* + KEYCLOAK_BASE_URL + credenza/mcp secrets here;
    # our target isolates credenza as its own service, so those live on `credenza` below.

  credenza:
    image: informatics-isi-edu/credenza
    tag: "..."
    scope: core
    container: { port: 8999, protocol: http }
    ingress:
      public: true
      routing: prefix
      public_path: /authn
      priority: 60
      base_path_env: APPLICATION_ROOT               # NEW (prefix-awareness work); credenza key TBD (Flask)
      health: { path: /health, port: 8999 }         # container-internal (served at root today; see health note)
      extra_paths: ["/.well-known/oauth-authorization-server/authn"]   # exact paths -> this service
    persistence: ephemeral
    depends_on:
      data:
        - { resource: cache, port: 6379 }           # -> ElastiCache (Valkey) session store (D19)
    env:                                            # extracted from deriva/credenza/docker-compose.yml
      config:  [DEPLOY_ENV, CREDENZA_DEFAULT_REALM, CREDENZA_DB_BACKEND, CREDENZA_DB_USER,
                CREDENZA_DB_PORT, CREDENZA_DEBUG, KEYCLOAK_BASE_URL]
      secrets: [CREDENZA_DB_PASSWORD, CREDENZA_ENCRYPTION_KEY,
                KEYCLOAK_DERIVA_CLIENT_SECRET, MCP_CLIENT_SECRET]
      wired:
        CONTAINER_HOSTNAME: { from: env.domain }
        CREDENZA_DB_HOST:   { from: cache.endpoint }   # single-backend model; our target CREDENZA_DB_BACKEND=valkey (D19)
    # ONE session backend (credenza STORAGE_BACKENDS: redis|valkey|sqlite|postgresql|memory); CREDENZA_DB_{HOST,PORT,
    # USER,PASSWORD} uniformly parametrize it. CREDENZA_DB_PASSWORD is the single connection secret (Valkey AUTH for us).
    # No separate metadata DB. env_file: STACK_ENV_FILE removed under D5.

  mcp-core:
    image: informatics-isi-edu/deriva-mcp-core
    tag: "..."
    scope: core
    container: { port: 8000, protocol: http }
    ingress:
      public: true
      routing: prefix
      public_path: /mcp
      priority: 50
      base_path_env: DERIVA_MCP_ROOT_PATH           # NEW (prefix-awareness): FastMCP root_path
      health: { path: /health, port: 8000 }         # container-internal (served at root today; see health note)
      extra_paths: ["/.well-known/oauth-protected-resource/mcp"]
    persistence: ephemeral
    depends_on:
      services:
        - { name: credenza, port: 8999 }
    env:                                            # extracted from deriva/mcp/docker-compose.yml
      config:  [DEPLOY_ENV, DERIVA_MCP_SSL_VERIFY, DERIVA_MCP_HOSTNAME_MAP, CA_FILENAME]
      secrets: [MCP_CLIENT_SECRET]
      wired:
        DERIVA_MCP_CREDENZA_URL:    { from: credenza.public_url }   # = https://<host>/authn
        DERIVA_MCP_SERVER_URL:      { from: self.public_url }       # = https://<host>/mcp
        DERIVA_MCP_SERVER_RESOURCE: { from: self.public_url }
    # image constant (not blueprint env): REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt

  chatbot:
    image: informatics-isi-edu/deriva-mcp-ui
    tag: "..."
    scope: core
    container: { port: 8001, protocol: http }
    ingress:
      public: true
      routing: prefix
      public_path: /chatbot
      priority: 51
      base_path_env: DERIVA_CHATBOT_BASE_PATH       # NEW (prefix-awareness)
      root_redirect: true                           # / -> /chatbot/ (ALB redirect action / Traefik middleware)
      health: { path: /health, port: 8001 }         # container-internal (served at root today; see health note)
    persistence: ephemeral
    depends_on:
      services:
        - { name: mcp-core, port: 8000 }
        - { name: credenza, port: 8999 }
    env:                                            # extracted from deriva/mcp-ui/docker-compose.yml
      config:  [DEPLOY_ENV, DERIVA_CHATBOT_HOSTNAME_MAP, DERIVA_CHATBOT_SSL_VERIFY, CA_FILENAME]
      secrets: [DERIVA_CHATBOT_LLM_API_KEY]         # delivered via env (not a Docker secret today)
      wired:
        HOSTNAME:                    { from: env.domain }
        DERIVA_CHATBOT_CREDENZA_URL: { from: credenza.public_url }
        DERIVA_CHATBOT_MCP_URL:      { from: mcp-core.public_url }
        DERIVA_CHATBOT_MCP_RESOURCE: { from: mcp-core.public_url }
        DERIVA_CHATBOT_PUBLIC_URL:   { from: self.public_url }
    # image constant (not blueprint env): REQUESTS_CA_BUNDLE

  keycloak:
    image: quay.io/keycloak/keycloak
    tag: "..."
    scope: optional                                 # currently unused in cloud; not deployed unless enabled
    container: { port: 8080, protocol: http }
    ingress: { public: true, routing: prefix, public_path: /auth, priority: 20, health: { path: /auth/health/ready, port: 9000 } }   # health on mgmt port 9000, not 8080
    persistence: ephemeral
    depends_on: { data: [ { resource: rds, port: 5432 } ] }     # cloud: KC_DB=postgres (compose uses dev-file)
    env:                                            # extracted from deriva/keycloak/docker-compose.yml (KC_* mostly static)
      config:  [KC_DB, KC_HTTP_RELATIVE_PATH, KC_BOOTSTRAP_ADMIN_USERNAME, KC_LOG_LEVEL, KC_PROXY_HEADERS]
      secrets: [KC_BOOTSTRAP_ADMIN_PASSWORD]
      wired:
        KC_HOSTNAME:       { from: self.public_url }   # https://<host>/auth
        KC_HOSTNAME_ADMIN: { from: self.public_url }
        KC_DB_URL_HOST:    { from: rds.endpoint }
```

---

## Appendix B -- Environment blueprint (full example + create-vs-adopt contract)

The illustrative brownfield-mix `environments/brownfield.yaml` and the per-resource
create-vs-adopt contract. Design rationale: see *IaC Configuration Model* in Part II.

```yaml
# environments/brownfield.yaml  (illustrative; brownfield mix)
env:
  name: brownfield
  account: "123456789012"
  region: us-west-2
  domains: ["www.example.org"]      # public FQDN(s): ALB host rules + DNS + cert SANs
  task_tls: private-ca              # private-ca (AWS internal; app-terminated via cert agent, D11) | acme (non-AWS/BYOH edge)
  tags: { Project: DERIVA, Environment: brownfield, Compliance: "fedramp-moderate" }

network:
  vpc:
    mode: adopt
    id: vpc-0abc                    # adopt: id (or lookup_tags: {...})
    # create: { cidr: 10.20.0.0/16, max_azs: 3, nat_gateways: 2 }
  subnets:                          # map DERIVA tiers -> subnets; each tier needs >=2 AZs
    public: { ids: [subnet-a, subnet-b] }   # ALB
    app:    { ids: [subnet-c, subnet-d] }   # Fargate tasks (private w/ egress)
    data:   { ids: [subnet-e, subnet-f] }   # RDS/MQ/cache (isolated)
    # create mode: derived from vpc creation (tier + cidr_mask) instead of ids
  security_groups:
    adopt: { legacy_app: sg-0abc }          # referenced, immutable
    create: [deriva_alb, deriva_app, deriva_data]   # rules derived by foundation
    rules:                                  # optional cross-links (adopted <-> created)
      - { from: legacy_app, to: deriva_app, port: 443 }

ingress:
  alb:
    mode: create
    scheme: internet-facing
    subnets: public                 # logical ref
    security_group: deriva_alb
    tls_policy: ELBSecurityPolicy-TLS13-1-2-2021-06
    idle_timeout_seconds: 300       # MCP streaming / large hatrac uploads
    access_logs: { bucket: create, prefix: alb }
    # adopt: { arn: ..., https_listener_arn: ..., listener_rule_priority_base: 200 }
  certificate:
    mode: create                    # create (ACM + DNS validation) | adopt: { arn: ... }
    domains: ["www.example.org"]
  waf:
    mode: create                    # create | adopt | none
    managed_rule_groups: [AWSManagedRulesCommonRuleSet]
  dns:
    mode: adopt                     # adopt existing hosted zone (typical); app A/ALIAS -> ALB created regardless
    hosted_zone_id: Z123
    zone_name: example.org

data:
  rds:
    mode: create
    engine_version: "16"
    instance_class: db.r6g.large
    multi_az: true
    kms: env                        # env CMK ref, or adopt: arn
    backup_retention_days: 14
    # adopt: { endpoint: ..., port: 5432, secret_arn: ... }
  mq:
    mode: create
    engine_version: "3.13"
    host_instance_type: mq.m5.large
    deployment_mode: ACTIVE_STANDBY_MULTI_AZ
    # adopt: { endpoints: [...], secret_arn: ... }
  cache:
    mode: create
    engine: valkey
    serverless: true
    # adopt: { endpoint: ..., auth_secret_arn: ... }
  object_store:                     # hatrac: brownfield env has existing buckets -> adopt (no data migration)
    mode: adopt
    buckets: [brownfield-hatrac-data]   # one or more existing buckets
    # create: { kms: env, object_lock: false }

platform:
  ecs: { mode: create, cluster_name: deriva-brownfield, container_insights: true }
  service_connect: { namespace: { mode: create, name: deriva.local } }   # or adopt Cloud Map ns
  kms: { env_cmk: { mode: create, rotation: true } }                     # shared CMK; per-resource can override
  logging: { retention_days: 400, kms: env }
  secrets: { provider: ssm, path_prefix: /deriva/brownfield }            # values provisioned out-of-band
  private_ca: { mode: create }      # create (short-lived mode; issues internal certs consumed by the cert agent, D10/D11) | adopt: { arn: ... } | none (non-AWS)

compliance:                         # adopted-resource audit (fail-closed by default)
  audit_adopted: true
  waivers: []                       # e.g. { resource: brownfield-hatrac-data, control: versioning, reason: ..., expires: 2026-12-31 }
```

### Create-vs-adopt contract (foundational resources)

| Resource           | adopt requires                                 | create key fields                                          | Brownfield                            |
|--------------------|------------------------------------------------|------------------------------------------------------------|---------------------------------------|
| VPC                | `id` (or lookup tags)                          | `cidr`, `max_azs`, `nat_gateways`                          | adopt                                 |
| Subnets            | `ids` per tier (public/app/data), each >=2 AZs | tier + `cidr_mask` (from VPC create)                       | adopt (select existing)               |
| Security groups    | `sg-id` per adopted name                       | list of new SGs; rules derived                             | mixed (adopt some, create DERIVA SGs) |
| ALB + listener     | `arn`, `https_listener_arn`, `priority_base`   | scheme, subnets, SG, TLS policy, idle timeout, access logs | create                                |
| Certificate        | `arn`                                          | domains + DNS validation (needs hosted zone)               | create                                |
| WAF                | web-ACL `arn`                                  | managed rule groups                                        | create                                |
| DNS zone           | `hosted_zone_id`, `zone_name`                  | zone name                                                  | adopt (exists)                        |
| KMS                | key `arn`(s)                                   | rotation-enabled CMK                                       | create                                |
| RDS                | `endpoint`, `port`, `secret_arn`               | engine, class, multi-AZ, KMS, backups                      | create                                |
| Amazon MQ          | `endpoints`, `secret_arn`                      | engine, instance, deployment mode                          | create                                |
| ElastiCache        | `endpoint`, `auth_secret_arn`                  | Valkey serverless, KMS, TLS+AUTH                           | create                                |
| S3 (hatrac)        | `buckets` (existing)                           | bucket + KMS + BPA + versioning + logging                  | **adopt (exists, no migration)**      |
| ECS cluster        | cluster `arn`/name                             | name, container insights, capacity providers               | create                                |
| Service Connect ns | Cloud Map ns `id`                              | namespace name                                             | create                                |

---

## Appendix C -- Glossary

Assumes no prior AWS/DevOps background. DERIVA services (ermrest, hatrac, webauthn2, chaise,
credenza, mcp-core, chatbot) are assumed known.

### AWS services & primitives
- **EC2** (Elastic Compute Cloud) - AWS virtual machines. The classic "server you rent."
- **AMI** (Amazon Machine Image) - the template a VM boots from (OS + preinstalled software). A
  "golden AMI" is a pre-hardened, pre-baked image.
- **ASG** (Auto Scaling Group) - a managed pool of identical EC2 instances AWS keeps at a target
  count and can scale/replace. **Launch Template** = the recipe (AMI, instance type) it launches
  from. **Instance refresh** = rolling replacement onto a new AMI/template.
- **ECS** (Elastic Container Service) - AWS's container orchestrator. **Task** = one running set
  of containers; **service** = a maintained set of tasks; **task definition** = the spec.
- **Fargate** - serverless compute for ECS: run containers without managing the host VMs (AWS
  owns/patches them). Alternative = the **EC2 launch type** (you own the hosts).
- **ECR** (Elastic Container Registry) - AWS's private Docker image registry.
- **ALB** (Application Load Balancer) - an HTTP(S) load balancer that routes to backends
  (**target groups**) by host/path and health-checks them. Backends = container IPs or EC2
  instances. **NLB** (Network Load Balancer) = a lower-level TCP load balancer.
- **VPC** (Virtual Private Cloud) - your isolated private network. **Subnets** partition it
  (public = internet-reachable, private = not). **NAT gateway** = outbound internet for private
  hosts. **VPC endpoints** = private links to AWS services (traffic stays off the internet).
- **Security Group (SG)** - a stateful virtual firewall on a resource (allow-list of ports/sources).
- **RDS** (Relational Database Service) - managed PostgreSQL/etc.; AWS handles backups, patching,
  failover. **PITR** (point-in-time recovery) = restore to any moment in the backup window.
  **Multi-AZ** = a standby in another availability zone for automatic failover.
- **Amazon MQ** - managed message broker (managed RabbitMQ).
- **ElastiCache** - managed Redis/Valkey (in-memory store). **Serverless** = no node sizing,
  pay-per-use. **Valkey** = an open-source Redis fork.
- **S3** (Simple Storage Service) - object storage (buckets of files). **Versioning**, **Block
  Public Access (BPA)**, **Object Lock** = data-protection features.
- **KMS** (Key Management Service) - managed encryption keys. **CMK** (customer-managed key) = a
  key you control. **SSE-KMS** = server-side encryption with a KMS key.
- **ACM** (AWS Certificate Manager) - issues/renews TLS certs for AWS services (free public
  certs). **ACM Private CA** = a private certificate authority for internal/mutual-TLS certs
  (billed monthly).
- **Route 53** - AWS DNS (hosted zones + records).
- **Sidecar** - a helper process/container that runs alongside an app inside the same task,
  handling a concern (here, networking) on the app's behalf with no app code changes. **Envoy** -
  a widely used open-source network proxy; the sidecar Service Connect (below) injects is built
  on it.
- **Service Connect** - ECS's built-in service-to-service networking: injects an Envoy sidecar
  giving stable service names (discovery), client-side load-balancing across healthy task
  replicas, health-aware routing, and per-service metrics; optionally mTLS, which we do not use
  (east-west TLS is app-terminated, [D11](#d11)). See "Service Connect: what it does" under Target
  Architecture. **Cloud Map** = the underlying discovery registry (works for ECS tasks *and* EC2
  instances).
- **IAM** (Identity and Access Management) - AWS permissions. A **role** grants permissions to a
  workload: a **task role** (Fargate) / **instance profile** (EC2) is the role a running workload
  assumes. **IRSA** (IAM Roles for Service Accounts) is the Kubernetes/EKS equivalent.
- **SSM** (Systems Manager) - ops toolkit. **Parameter Store** = config/secret storage
  (**SecureString** = KMS-encrypted). **Session Manager** = audited shell access to instances
  with no SSH keys or open ports. **Secrets Manager** = managed secrets with auto-rotation.
- **CloudWatch** - logs, metrics, alarms, dashboards. **Container Insights** = per-container
  metrics. **CloudWatch agent** = collects logs/metrics from a VM.
- **CloudTrail** - records all AWS API calls (audit trail). **AWS Config** - tracks resource
  configuration + evaluates compliance rules over time. **Security Hub** - aggregates
  security/compliance findings (supports the NIST 800-53 standard). **GuardDuty** - managed
  threat detection. **Amazon Inspector** - automated vulnerability (CVE) scanning; covers
  container images in ECR and AMIs built via EC2 Image Builder, the CI/CD scan gate ([D21](#d21)).
- **WAF** (Web Application Firewall) - filters malicious HTTP traffic at the ALB (managed rules).
- **EventBridge** - event bus + scheduler (runs scheduled tasks, replacing cron).
- **EBS** (Elastic Block Store) - network-attached disk volumes. **CloudShell** - a browser
  terminal in the AWS console (where operators paste `awscli` today).

### IaC, build & CI/CD tooling
- **IaC** (Infrastructure as Code) - defining cloud resources in code/config, not by clicking
  consoles.
- **CDK** (Cloud Development Kit) - AWS's IaC framework where you define infra in a real language
  (we use Python); it synthesizes **CloudFormation** (AWS's native provisioning engine).
  "Constructs" = reusable building blocks. **`from_lookup` / `from_*`** = CDK calls that
  *reference* an existing resource instead of creating one (how we "adopt" brownfield infra).
- **cdk-nag** - a CDK add-on that checks synthesized infra against compliance rule packs (e.g.
  NIST 800-53) and fails the build on violations.
- **cdk8s** - a CDK-family tool that generates Kubernetes manifests (for a hypothetical EKS
  target). **Terraform** - a popular third-party IaC tool (HCL language), the main CDK alternative.
- **EC2 Image Builder** - an **AWS-native service** that builds, hardens, tests, and
  distributes golden **AMIs** via a managed pipeline (configured from CDK; ships AWS-managed
  CIS/STIG hardening components). Our AMI-baking tool for the EC2/AMI compute path
  ([D3](#d3)) - it adds no new third-party toolchain.
- **Ansible** - an agentless config-management tool (runs over SSH). **Not adopted** ([D3](#d3));
  the dev direct-to-Linux target uses blueprint-generated shell instead. Listed for reference.
- **boto3** - the AWS SDK for Python (used for the deploy-time compliance audit of adopted
  resources).
- **GitHub Actions** - the CI/CD system (build/test/deploy pipelines) already in use.
- **Docker Compose / dockerd** - Compose defines multi-container apps in YAML; dockerd runs them.
  Used for local dev. **Traefik** - the reverse proxy/router in the local Compose stack
  (discovers routes from container labels); Compose-only -- no cloud render target uses it
  (they use the ALB).
- **Score (score.dev)** - a CNCF spec for a platform-agnostic "workload" description with
  renderers to Compose/Kubernetes (evaluated as prior art; not adopted - no ECS renderer).
- **Kubernetes (K8s) / EKS / Helm / ArgoCD** - K8s is a container orchestrator; **EKS** = AWS's
  managed K8s; **Helm** packages K8s apps (charts + values); **ArgoCD** = GitOps deployment for
  K8s. The partner (CZI) uses these; this proposal avoids self-running them. **AWS Copilot** = a
  now-discontinued AWS CLI that scaffolded ECS apps (a cautionary dead end).

### Compliance standards, benchmarks & control IDs
- **NIST 800-53** - the US federal catalog of security/privacy controls (the basis of FedRAMP).
- **FedRAMP** - US government cloud-security authorization program; **Moderate** / **High** are
  impact tiers (Moderate can use commercial AWS; High usually needs GovCloud).
- **dbGaP** - NIH's database of Genotypes and Phenotypes; its "controlled-access" data carries
  strict handling requirements. (Not a current requirement for this substrate; see Compliance
  Baseline.)
- **CIS Benchmark** (Center for Internet Security) / **STIG** (Security Technical Implementation
  Guide, US DoD) - published OS/software **hardening** standards; a "CIS/STIG-hardened AMI" is a
  golden image locked down to one of these baselines.
- **NIST control IDs** cited inline: **AC-6** least privilege; **AU** audit/logging; **CP-10**
  recovery; **RA-5** vulnerability scanning; **SC-7** boundary protection; **SC-8** protection in
  transit; **SC-28** protection at rest; **SI-2** flaw remediation (patching).
- **POA&M** (Plan of Action & Milestones) - the FedRAMP artifact tracking accepted
  deviations/remediation. **SSP** (System Security Plan) - the master compliance document.

### Security / networking terms
- **TLS / mTLS** - TLS encrypts a connection; **mutual TLS** also authenticates *both* ends (each
  presents a cert). **TLS 1.3** = the current version.
- **immutable infrastructure** - ship a new pre-built image/AMI and replace instances, rather than
  editing running servers in place.
- **RFC 8414 / RFC 9728** - OAuth/OIDC standards for how a server advertises its metadata
  endpoints (relevant to credenza's `.well-known` URLs).
