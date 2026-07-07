# Design — Localize remaining chart-declared images for full air-gap (#2024)

- **Issue:** platform-mesh/helm-charts#2024 — "Localize remaining chart-declared images for full air-gap"
- **Branch:** `feat/2024-localize-airgap-images` (off `upstream/main` @ `ccaeed63`)
- **Date:** 2026-07-07

## Goal

A real air-gap means **0 external pulls**. Under egress isolation, any image that still
resolves to `ghcr.io`/`docker.io` goes `ImagePullBackOff`. The operator-side image injection
already localizes every image that is declared as an OCM `ociImage` resource (14 first-party
services proven). The images in this issue still pull externally because they are **hardcoded
literals** or use a **non-localizable value schema**, so OCM cannot rewrite them and the
operator cannot inject them.

This work makes each remaining image localizable via the standard three-part fix.

## The three-part fix (applied per image)

1. **OCM resource** — declare the image as a `type: ociImage` resource so `ocm transfer`
   / CTF mirrors it into the in-cluster registry and the operator can resolve `toOCI()`.
2. **Localizable chart value** — expose the image as a `{registry, repository, tag, digest}`
   map and render it through the **existing** `charts/common` `common.image` helper, called
   with a constructed sub-context dict:
   `include "common.image" (dict "Values" (dict "image" <the map>) "Chart" .Chart)`.
   No change to `common`, no version bump, no re-vendoring of the 14 consumers.
3. **Profile wiring** — add an `imageResources` entry (`resource:` = the constructor resource
   name, `annotations.path:` = the Helm values path) so the platform-mesh-operator injects the
   localized `{registry, repository, tag, digest}` into the HelmRelease `spec.values`.

## Resolved decisions

- **Scope:** full checklist (Scope C), including the CNPG postgres image for the keycloak DB.
  Postgres is a CloudNativePG runtime-CR image, which the issue's own "Out of scope" note
  excludes — it is included here as a deliberate expansion and will be **called out explicitly
  in the PR description**.
- **Render helper:** reuse existing `common.image` via dict-passing. `observability` currently
  has **no `common` dependency** and must add one (`Chart.yaml` dependency + vendored `.tgz` +
  `Chart.lock`).
- **Plumbing depth:** full CI/production wiring — charts + `.ocm` constructors + aggregate otel
  resources + profile + overlays + `.github` workflow `serviceComponentConstructorFile` wiring +
  aggregator version variables.
- **Proof:** static suite + local `--airgap` E2E + CI dry-run.

## Per-image implementation plan

Values-path names below are the target injection paths; exact leaf names to be confirmed at
implementation.

| # | Image | Chart change | `.ocm` resource | Profile `imageResources` path |
|---|-------|--------------|-----------------|-------------------------------|
| 1 | busybox (infra keycloak init) | new `keycloak.operator.waitForDb.image` map; replace literal `busybox:1.37` at `charts/infra/templates/keycloak/keycloak.yaml:49` with `common.image` render | `busybox-image` | `keycloak.operator.waitForDb.image` |
| 2 | keycloak **server** (infra) | reshape `keycloak.operator.image` (currently `repository` + `tag` with embedded `@sha256`) → `{registry,repository,tag,digest}`; render at `keycloak.yaml:9` | `keycloak-image` | `keycloak.operator.image` |
| 3 | **postgres** (infra CNPG) | add `spec.imageName` to `charts/infra/templates/cnpg/cluster.yaml` sourced from a new `{registry,repository,tag,digest}` values map | `postgres-image` | the CNPG image path |
| 4 | otel-collector (observability) | reshape `otelCollector.image` flat string → map; render at `charts/observability/templates/otel-collector.yaml:8` | `otel-collector-image` | `otelCollector.image` |
| 5 | kubectl cert-job (observability) | new `serviceMonitors.kcp.certExtractor.image` map, **digest-pinned** (ships only `:latest`); replace literal at `charts/observability/templates/kcp-metrics-cert-job.yaml:101` | `kubectl-image` | `serviceMonitors.kcp.certExtractor.image` |
| 6 | keycloak-operator `keycloakImage` | add `digest`; render via `common.image` (migrate off chart-local helper for consistency) | `keycloak-image` (on keycloak-operator) | `keycloakImage` |
| 7 | opentelemetry-operator (manager / collector / target-allocator) | none in charts — images overridden via the `opentelemetryOperator` profile `values` | **3 `ociImage` resources inline in `.ocm/component-constructor-aggregate.yaml`** | override in profile `values` |

## OCM component structure (`.ocm/`)

`infra`, `observability`, `keycloak-operator` are `appVersion: 0.0.0` chart-only components
today (only a `helmChart` resource; image ref suppressed). Their new image resources must use
the **split sub-component** shape — the operator resolves images at
`referencePath [{service},{image}]`, so resources placed directly on the service component do
**not** resolve (verified the hard way in prior work).

- **Local build path** (`ocm-build-local-charts.sh`, auto-selects `.ocm/component-constructor-<comp>.yaml`):
  add `.ocm/component-constructor-{infra,observability,keycloak-operator}.yaml`, modeled on
  `.ocm/component-constructor-local-prerelease.yaml`: service component →
  `componentReferences: [{chart → helm-charts/<svc>}, {image → images/<svc>}]`; the
  `images/<svc>` sub-component holds the multiple `ociImage` resources.
- **CI/production path** (`serviceComponentConstructorFile`, threads
  `pipeline-chart.yml` → `job-ocm.yml` → `ocm-service-component.yaml`): add
  `.ocm/component-constructor-service-{infra,observability,keycloak-operator}.yaml`, modeled on
  `.ocm/component-constructor-service-example-httpbin-operator.yaml`, declaring the umbrella
  service component **and** the inline `images/<svc>` sub-component with the same `ociImage`
  resources. Wire each per-service `.github/workflows/{infra,observability,keycloak-operator}.yaml`
  to pass this file as `serviceComponentConstructorFile`.

Keep the local and CI resource sets identical (same resource names, same image refs) so both
build paths localize the same images.

## opentelemetry-operator specifics

The `github.com/open-telemetry/opentelemetry-operator` component in the aggregate currently
declares only a `chart` `helmChart` resource. Add 3 `ociImage` resources (manager / collector /
target-allocator). This requires **3 new version variables** (e.g.
`OTEL_OPERATOR_IMAGE_VERSION`, `OTEL_COLLECTOR_IMAGE_VERSION`, `OTEL_TARGET_ALLOCATOR_VERSION`),
sourced from the upstream opentelemetry-operator chart `0.114.1` defaults, added in **both**:
- `.github/workflows/ocm-aggregator.yaml` `env:` block (alongside the existing otel pins), and
- `local-setup/scripts/ocm-build-component.sh` — export via the `yq … "$agg"` pattern in
  `resolve_component_versions` **and** pass through in `build_final_component`'s
  `ocm add components -- …` arg list (both are required or the templater errors on undefined vars).

The operator manager, collector, and target-allocator images are overridden to the localized
refs via the `opentelemetryOperator` FluxCD component `values` in the profile.

## Profile & overlays

Add/populate `imageResources` entries in all three profile copies:
- `local-setup/kustomize/components/platform-mesh-operator-resource/default-profile.yaml` (base)
- `local-setup/kustomize/overlays/platform-mesh-resource-argocd/default-profile.yaml`
- `local-setup/kustomize/overlays/platform-mesh-resource-fluxcd/default-profile.yaml`

`infra.imageResources` is currently `[]` (a deliberate comment about kcp custom tag) — replace
with the new entries. Add `observability.imageResources` and the keycloak-operator entry. Add
the opentelemetry-operator image `values` overrides.

## Chart version bumps + docs

- `charts/infra/Chart.yaml`: `0.34.0` → `0.35.0` (minor).
- `charts/observability/Chart.yaml`: `0.4.0` → `0.5.0` (minor; also adds `common` dependency).
- `charts/keycloak-operator/Chart.yaml`: `0.3.0` → `0.4.0` (minor).
- Regenerate READMEs via `task docs` (helm-docs v1.14.2).
- Regenerate `charts/infra` unittest snapshots (`helm unittest -u charts/infra`).
- **Add** minimal unittest coverage for observability image rendering (chart currently has no
  `tests/` — otel-collector and kubectl images are untested today).

## Landmines / constraints (from prior work)

- **Keycloak image:** MUST stay `ghcr.io/platform-mesh/custom-images/keycloak`, tag **`v26.6.0`**
  (the `26.6.0` *without* the `v` is a different digest / different build), digest
  `sha256:207cdc27e513bc7a6a6d2e429e1a9346dd62654c92573866c4a091b844f7b800`. The `upstream-images`
  (bitnami) variant runs `exec "$@"` and crashes on the Keycloak CR's entrypoint args
  (`exec: -D: invalid option`). Do **not** swap the base image.
- `common.image` requires a non-empty `.registry` (no empty-registry fallback) — every image map
  must set `registry`.
- kubectl and any other mutable-tag images must be **digest-pinned**.

## Verification strategy

Static gate (must pass before "done"):
- `helm lint charts/{infra,observability,keycloak-operator}`
- `helm unittest charts/infra` (regenerated snapshots) + new observability tests
- `task docs` → READMEs byte-identical to committed
- `ct lint` on the changed charts
- `kustomize build` of the base + argocd + fluxcd profile overlays
- `ocm add components` (dry parse) of the modified aggregate + new per-component/service
  constructors — must template and resolve with the new version vars

Runtime proof:
- Local `--airgap` E2E (the previously proven method: containerd-mirror + in-cluster registry +
  egress isolation) demonstrating the 6/7 target images resolve to the in-cluster registry and
  the pods run with no `ImagePullBackOff`.
- CI dry-run of the modified workflows where feasible.

## Out of scope / known separate bugs (do not fix here)

- Runtime-CR images placed by other operators beyond the keycloak-DB postgres (kcp-operator,
  etcd-druid).
- CTF transfer bugs: doubled `platform-mesh/` postgres prefix; openfga migrate init container.
- Finding-2 doubled-prefix in `toOCI().repository` for keycloak (separate constructor base-path bug).
- `global.imageRegistry` (deferred).

## Proposed commit structure (one PR)

1. `charts/infra` — value schema + helpers + keycloak/busybox/postgres templates + Chart bump +
   README + snapshot.
2. `charts/observability` — add `common` dep + value schema + otel-collector/kubectl templates +
   Chart bump + README + new tests.
3. `charts/keycloak-operator` — `keycloakImage` digest + `common.image` migration + Chart bump +
   README + snapshot.
4. `.ocm` — per-component local override constructors + CI service-component constructors +
   aggregate opentelemetry-operator `ociImage` resources.
5. `.github` + build script — `serviceComponentConstructorFile` wiring + 3 otel version vars in
   `ocm-aggregator.yaml` and `ocm-build-component.sh`.
6. Profile — base + argocd + fluxcd `imageResources` + opentelemetry-operator value overrides.
