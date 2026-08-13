# ADR 0002: Management group hierarchy depth and shape

**Status:** Accepted
**Date:** 2026-08-13
**Phase:** 1

## Context

Policy and RBAC inherit downward through the Azure resource hierarchy. Before any governance can be written, there has to be a structure to attach it to, and that structure is expensive to change later: renaming a management group forces replacement, moving one relocates every child, and any policy assignment scoped to the old node breaks.

The estate is one subscription. That makes the hierarchy look absurd on its face, four top-level groups and nine total for a single subscription, and the temptation is to skip it and assign policy at subscription scope directly.

That temptation is worth resisting for a specific reason. Assigning at subscription scope means the governance is bound to the subscription, and adding a second one later means duplicating every assignment or retrofitting a hierarchy underneath resources that already exist. The hierarchy is the artifact being built here, not the resource count inside it.

Constraints:

- One subscription, personal, single operator
- No compliance framework mandating a particular structure, so the shape has to be justified on operational grounds rather than by citing a regulator
- The environment is destroyed nightly, but management groups are not part of that teardown. They persist, which makes getting the names right more important than usual
- Everything in this phase must cost nothing

## Options considered

### Flat: no management groups, assign at subscription scope

- Cost: zero
- Operational burden: lowest today, highest later. Every new subscription needs its own copy of every assignment, and there is no way to express "this applies to all internet-facing workloads" as a single statement
- Fits when: one subscription is genuinely permanent and nobody expects growth, which is almost never true and is not a claim worth making in a portfolio repository

### Minimal: one group above the subscription

A single `jbo-root` with the subscription beneath it.

- Cost: zero
- Operational burden: low. Gives one inheritance point, which is better than none
- Fits when: a small estate wants a place to hang tenant-wide policy without modeling workload differences. Real option, and defensible

### CAF-aligned: platform, landing zones, sandbox, decommissioned (chosen)

Four top-level groups, with platform and landing zones each having children. Three levels below tenant root.

- Cost: zero
- Operational burden: moderate. More nodes to reason about, and the definition-scope rule becomes something you have to think about rather than something that resolves itself
- Fits when: the structure needs to survive growth, or when the arrangement itself is meant to demonstrate understanding of why the separations exist

### Deep: CAF plus per-environment and per-business-unit tiers

Adding dev/test/prod tiers or business unit tiers beneath the landing zones.

- Cost: zero
- Operational burden: high, and the cost is not obvious until it bites. Azure permits six levels below tenant root, so depth is available, but every level added multiplies the number of places a policy could be assigned and makes answering "why is this resource non-compliant" require walking the whole chain
- Fits when: business units have genuinely different regulatory obligations and separate platform teams. Not the case here, and building it anyway would be modeling an organization that does not exist

## Decision

Adopt the CAF-aligned hierarchy, three levels below tenant root:

```
Tenant Root
  jbo-platform
    jbo-platform-identity
    jbo-platform-management
    jbo-platform-connectivity
  jbo-landing-zones
    jbo-lz-corp          <- the subscription
    jbo-lz-online
  jbo-sandbox
  jbo-decommissioned
```

The single subscription sits in `jbo-lz-corp`.

**Why platform is separated from landing zones.** They change at different rates and are owned by different roles. Platform holds shared services that applications depend on: identity, the hub network, the logging workspace. Landing zones hold the applications themselves. This is the same separation as the layered state discussed in ADR 0001, expressed in the governance tree rather than in Terraform state files. A policy that makes sense for a workload subscription, such as denying public IPs, would break a connectivity subscription whose entire job is hosting public ingress.

**Why corp and online are split.** This is the split doing the most work in the whole hierarchy and it is the one worth being able to explain. Corp workloads expect hybrid connectivity and no direct internet exposure. Online workloads are internet-facing by design. The split exists so that `deny public IP on network interfaces` can be assigned to corp and simply not assigned to online, rather than being assigned broadly and then punctured with exemptions. Exemptions are a maintenance liability; not assigning a policy where it does not belong is free.

**Why sandbox is a peer of landing zones rather than a child.** Sandbox exists so that experimentation happens under deliberately lighter policy. If it were a child of landing zones it would inherit the landing zone assignments, which defeats the purpose. Making it a peer means it inherits only tenant-root policy. It gets its own restrictions instead, notably a VM SKU size cap, because "lighter governance" should mean fewer correctness constraints and not fewer cost constraints.

**Why decommissioned exists with nothing in it.** A subscription being retired needs somewhere restrictive to sit while data is extracted and stakeholders confirm nothing is still running. Deleting a subscription is not reversible in any useful sense. An empty node costs nothing and having it before it is needed is the difference between a process and an improvisation.

**Why three levels and not more.** Azure supports six levels below tenant root, so the limit is not the constraint. The constraint is diagnosis. When a deployment is rejected by policy, answering "which assignment blocked this" means walking the chain from the resource up to the root. Each level added makes that walk longer and makes the aggregated effective policy harder to hold in your head. Three levels is deep enough to express platform-versus-workload and corp-versus-online, and shallow enough that the chain is short. Adding a dev/test/prod tier was considered and rejected: environments here are separated by Terraform workspace and subscription intent, not by management group, and duplicating that separation in two places creates two things to keep in sync.

**Why the subscription lands in corp rather than sandbox.** The build is meant to exercise real governance. Placing it in sandbox would mean the interesting policies never apply to anything.

## Consequences

**Names are immutable and this is the sharpest edge in the phase.** The `name` argument on `azurerm_management_group` is the resource ID, not a label. Changing it forces replacement, which relocates every child group and breaks every policy assignment scoped beneath it. Only `display_name` is safe to change. The names chosen here are terse and permanent for that reason, and the display names carry readability. Anyone extending this hierarchy should assume the IDs are final.

**Definition scope now requires thought.** A policy definition can only be assigned at or below the scope where it is defined. With a flat structure this never comes up. With this structure, defining a policy at `jbo-platform` and trying to assign it at `jbo-landing-zones` fails, because those are siblings. The resolution adopted here is to define custom policies at the tenant root management group and assign them lower. That is what production landing zones do, and the reasoning belongs in ADR 0003.

**Management group operations are slow and eventually consistent.** The first apply is expected to take minutes and may fail partway with a 429 or a parent-not-found error on a child group whose parent was created seconds earlier. Re-running resolves it. This is an Azure API characteristic rather than a Terraform defect, and it is worth knowing before it happens rather than debugging it in the moment.

**Subscription association has two competing representations.** The `subscription_ids` argument on `azurerm_management_group` and the separate `azurerm_management_group_subscription_association` resource both manage the same relationship. Using both against the same group produces a permanent diff as each tries to assert ownership on every plan. This configuration uses the argument form exclusively.

**The hierarchy persists through the nightly destroy.** It is not in the dev environment state and is not torn down. That is deliberate, since rebuilding management groups nightly would be slow, would hit rate limits, and would churn policy assignments for no benefit. The practical consequence is that the hierarchy is the one part of this build that accumulates drift silently, because nothing rebuilds it from scratch to prove the code still produces it. A quarterly `terraform plan` against it, confirming no changes, is the cheap mitigation.

**Four top-level groups for one subscription looks disproportionate and will be questioned.** The honest answer is that it is disproportionate to the current resource count and proportionate to what the structure is for. Anyone reading this repository should understand the hierarchy is being demonstrated rather than being sized to a workload.

## Revisit when

- A second subscription enters scope, at which point corp versus online stops being hypothetical and the placement decision becomes real
- Any policy requires an exemption in one landing zone but not another, which is the signal that the corp/online split is either drawn in the wrong place or needs a third sibling
- A workload appears that fits neither corp nor online, most likely something requiring PCI or HIPAA isolation, which typically becomes a separate landing zone child rather than a fourth level
- The chain from a resource to tenant root becomes hard to reason about during an incident, which is the practical signal that depth has exceeded its usefulness
