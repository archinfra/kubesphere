# Agent Control Plane Roadmap

This document defines the first AI-native control plane slice for safe Agent/LLM-assisted Kubernetes operations.

## Objective

Add an Agent-facing operations layer that helps maintain Kubernetes clusters through explainable, auditable, RBAC-aware actions.

The Agent layer should not get unrestricted shell access. It should use typed platform tools that can be reviewed, tested, permissioned, audited, and rate-limited.

## First Capability Layers

### L0: Read-Only Inventory

Purpose:

- Let an Agent understand cluster state without changing anything.

Examples:

- List clusters, namespaces, nodes, workloads, pods, services, ingresses, storage classes, PVCs, events, and recent warnings.
- Summarize unhealthy workloads.
- Explain why a pod is pending, restarting, or unschedulable.
- Map a namespace to owners, quotas, events, and top risky resources.

Required controls:

- Kubernetes RBAC must be honored.
- Responses should include source resource references.
- High-volume results need pagination and filtering.

### L1: Diagnosis And Plan

Purpose:

- Let an Agent propose what it would do before changing anything.

Examples:

- Propose a deployment restart.
- Propose scaling a deployment.
- Propose editing resource requests/limits.
- Propose deleting evicted pods.
- Propose creating a debug job.

Plan schema:

- Intent
- Target resources
- Preconditions
- Proposed Kubernetes operations
- Risk level
- Expected impact
- Rollback hint
- Required approval level

### L2: Approved Execution

Purpose:

- Execute bounded, reviewed operations under a known identity.

Examples:

- Restart workload
- Scale workload
- Patch image
- Patch resource requests/limits
- Cordon or uncordon node
- Drain node only through a stricter workflow

Required controls:

- Strong operation allowlist.
- Dry-run where Kubernetes supports it.
- Human approval for risky operations.
- Audit event for every executed Kubernetes call.
- Idempotency key to avoid duplicate execution.

### L3: Continuous Maintenance

Purpose:

- Move from one-shot operations to scheduled recommendations and guarded automation.

Examples:

- Daily cluster health digest.
- Risk drift report.
- Workload restart-loop watch.
- Certificate and quota pressure watch.
- Image pull failure watch.

Required controls:

- Rate limiting.
- Clear ownership.
- Suppression rules.
- No autonomous destructive actions.

## Initial API Shape

Candidate API groups:

- `agent.kubesphere.io/v1alpha1`
- `operations.kubesphere.io/v1alpha1`

Candidate resources:

- `AgentSession`
- `OperationPlan`
- `OperationApproval`
- `OperationRun`
- `OperationAudit`

Candidate read-only KAPIs:

- `GET /kapis/agent.kubesphere.io/v1alpha1/clusters/{cluster}/inventory`
- `GET /kapis/agent.kubesphere.io/v1alpha1/clusters/{cluster}/diagnostics`
- `POST /kapis/agent.kubesphere.io/v1alpha1/clusters/{cluster}/plans`
- `POST /kapis/agent.kubesphere.io/v1alpha1/operationruns`

## Execution Safety Model

Every mutating operation should pass these gates:

1. Identity: who requested the operation and which platform/Kubernetes identity will execute it.
2. Scope: which cluster, namespace, and resources are affected.
3. Authorization: platform RBAC and Kubernetes RBAC both allow the action.
4. Plan: the Agent produced a structured plan.
5. Dry-run: server-side dry-run or equivalent validation completed when available.
6. Approval: approval policy matched the risk level.
7. Execution: bounded tool executes only the approved operations.
8. Audit: store input, plan, approval, operation result, and resource references.

## Non-Goals For The First Slice

- No unrestricted shell execution.
- No autonomous deletion of workloads, namespaces, PVs, secrets, users, roles, or clusters.
- No bypass of platform RBAC.
- No hidden background mutation without an audit event.
- No appstore ownership work in the first slice.

## First Implementation Sequence

1. Inventory current resource KAPIs and reuse their stores where possible.
2. Add a read-only Agent inventory endpoint that aggregates existing resource APIs.
3. Add an `OperationPlan` model and persistence boundary.
4. Add approval and audit models.
5. Add the first safe executor: restart deployment.
6. Add smoke tests that prove read-only, plan-only, approved execution, and denial paths.
