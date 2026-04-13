# Module Boundary Map

This map guides product separation work before invasive code changes.

## Keep As Core Platform

Backend:

- `cmd/ks-apiserver`
- `cmd/ks-controller-manager`
- `pkg/apiserver`
- `pkg/kapis/resources`
- `pkg/kapis/iam`
- `pkg/kapis/terminal`
- `pkg/controller/cluster`
- `pkg/controller/iam`
- `pkg/controller/tenant`
- `config/ks-core`

Frontend counterpart:

- Console shell and routing.
- Login and session flow.
- Cluster/resource management pages.
- IAM/workspace/project/namespace management pages.
- Logs, events, terminal, and kubeconfig surfaces.

## Replace With Internal Product Capability

Entitlement and license:

- Introduce an internal entitlement interface.
- Keep it independent from upstream edition assumptions.
- Gate product capabilities through explicit feature flags and policy.
- Store decision logs for which checks are kept, replaced, or removed.

Telemetry and cloud defaults:

- Disable by default in development.
- Replace with internal observability/audit integration if needed.
- Remove outbound cloud assumptions from production builds.

Brand and product metadata:

- Replace only after runtime smoke tests pass.
- Avoid mixing brand changes with functional refactors.

## Defer And Separate Later

Application/appstore:

- Keep first so the baseline stays deployable.
- Inventory CRDs, role templates, routes, stores, controllers, and extension dependencies.
- Remove or isolate only after core K8s management smoke tests are stable.

Extension marketplace:

- Keep disabled in dev values.
- Separate museum/repository defaults from extension runtime mechanics.
- Decide later whether extensions become an internal plugin system.

## First Inventory Categories

Run `hack/ai-native/module-inventory.sh` to generate a report for these categories:

- License and entitlement candidates.
- Appstore/application surfaces.
- Extension and museum surfaces.
- Telemetry/support/about/cloud defaults.
- IAM/auth/RBAC surfaces.
- K8s resource management KAPIs.
- Terminal/kubeconfig/exec surfaces.
- Agent-related candidate names.

## Boundary Decision Template

For each module or surface:

- Current path:
- Runtime owner:
- User-facing capability:
- Keep, replace, defer, or remove:
- Dependencies:
- Smoke tests required before change:
- Migration or compatibility concern:
- AI-native relevance:

## First Safe Refactor Rule

Do not remove code just because it looks like appstore, license, or extension code.

First classify it, write the expected behavior after separation, add a smoke test or manual verification step, and only then change runtime behavior.
