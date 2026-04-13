# AI-Native K8s Platform Bootstrap

This directory records the engineering baseline for building an internal, self-developed, AI-native Kubernetes management platform while learning from this codebase.

The immediate goal is not a shallow rebrand. The goal is to establish a reproducible development loop, identify product boundaries, and then evolve the platform around safe Agent/LLM-assisted cluster operations.

## Direction

Keep first:

- Kubernetes cluster, namespace, workload, pod, service, ingress, storage, node, event, log, and terminal management.
- IAM, RBAC, users, roles, role bindings, workspace/project models, and multi-cluster control paths.
- API aggregation and resource discovery that make the platform useful as a K8s operations surface.

Defer first:

- Appstore and application marketplace ownership.
- Extension marketplace and museum cleanup.
- Deep visual rebrand.

Replace deliberately:

- Product entitlement and license checks with an internal entitlement interface.
- Upstream telemetry, support, about, marketplace, and cloud defaults.
- Any unsafe or unaudited Agent execution path.

## AI-Native Principles

- Read-only first: cluster inventory, explainability, and risk discovery come before mutation.
- Plan before action: every mutating operation should produce a proposed plan, affected resources, rollback hint, and risk level.
- Human approval for risky actions: destructive or privilege-changing actions need explicit approval.
- RBAC-aware execution: Agent actions must run as a known Kubernetes identity and honor platform permissions.
- Full audit trail: store prompt intent, proposed plan, approval, executed Kubernetes calls, and result.
- Tool contracts over raw shell: expose typed, bounded operations instead of unrestricted command execution.

## Current Bootstrap Assets

- `engineering-baseline.md`: verified local and remote build/deploy baseline.
- `agent-control-plane.md`: first AI-native control plane slice and safety model.
- `module-boundaries.md`: current module boundary map and planned separation order.
- `hack/ai-native/dev-loop.sh`: remote build, image packaging, Helm deploy, and smoke workflow.
- `hack/ai-native/run-remote-dev-loop.ps1`: Windows wrapper to upload and run the remote dev loop.
- `hack/ai-native/module-inventory.sh`: codebase inventory helper for boundary work.

## First Milestones

1. M0 bootstrap: reproducible build, deploy, and smoke test on the remote K8s cluster.
2. M1 boundary inventory: license/entitlement, appstore, extension, telemetry, IAM, K8s resource APIs, and console routes.
3. M2 internal entitlement: introduce a narrow entitlement interface before removing or replacing upstream surfaces.
4. M3 Agent read-only APIs: inventory, explain, diagnose, and summarize cluster state with audit logging.
5. M4 Agent execution APIs: dry-run plans, approval workflow, RBAC-scoped execution, and rollback hints.
