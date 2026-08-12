# ADR 0001: Remote state in Azure Storage, pipeline auth via GitHub OIDC

**Status:** Accepted
**Date:** 2026-08-12
**Phase:** 0

## Context

Terraform needs somewhere to keep state, and the pipeline needs a way to authenticate to Azure. Both decisions have to be made before any resource exists, and both are expensive to reverse once real infrastructure depends on them.

Constraints in play:

- Single Azure subscription, personal, with a hard ceiling of $50 per month. Anything with a per-seat or per-workspace price is out.
- Solo operator. State locking matters for protection against my own concurrent runs and against a scheduled workflow colliding with an interactive one, not for team coordination.
- The repository is public. Nothing sensitive can live in the repo, and the credential model has to survive being read by strangers.
- The environment is torn down and rebuilt nightly, so state is written far more often than in a typical estate. State durability matters more here than it would in a system that changes weekly.

## Options considered

### State: commit `terraform.tfstate` to the repository

State travels with the code and there is nothing to provision.

- Cost: zero
- Operational burden: no locking at all. State contains resource attributes in plaintext, including values marked sensitive in the configuration, which in a public repository is disqualifying on its own.
- Fits when: never, for anything touching a real cloud account. Unrecommended by Hashicorp.

### State: Terraform Cloud / HCP Terraform

Managed backend with locking, run history, and a policy layer.

- Cost: free tier covers a solo operator, but it is a second vendor relationship, a second identity to federate, and a second place to look when something breaks
- Operational burden: low day to day. Adds a dependency outside the Azure control plane, so an HCP outage blocks deployment even when Azure is healthy.
- Fits when: multiple contributors need visible run history and approval gates, or the estate spans several clouds and a neutral control plane is worth the extra hop

### State: Azure Storage backend (chosen)

Blob container in the same subscription, with blob leases providing the lock.

- Cost: about $1 per month for ZRS storage at this volume
- Operational burden: one more resource to bootstrap by hand, and a chicken-and-egg problem where the state store cannot be managed by the Terraform that uses it
- Fits when: the estate is Azure-only and keeping the number of vendors down is worth accepting a manual bootstrap step

### Auth: service principal with a client secret

The traditional pattern. Generate a secret, store it in GitHub Actions secrets, pass it as `ARM_CLIENT_SECRET`.

- Cost: zero
- Operational burden: the secret expires and rotation is a manual calendar item that gets missed. A long-lived credential exists in two places and can be exfiltrated from either.
- Fits when: the CI system cannot issue OIDC tokens

### Auth: GitHub OIDC federation (chosen)

GitHub Actions requests a short-lived token; Entra validates the issuer, audience, and subject claim against a federated credential and exchanges it for an Azure access token.

- Cost: zero
- Operational burden: nothing to rotate and nothing to expire. The subject claim is a literal string match, which makes misconfiguration fail loudly but obscurely.
- Fits when: the pipeline runs on a platform with an OIDC provider Entra trusts, which GitHub Actions is

## Decision

**State lives in an Azure Storage blob container** in a dedicated resource group, Standard_ZRS, with blob versioning and 30-day soft delete enabled and shared key access disabled. Data plane access is by Entra identity only.

**One state file per environment**, `dev.tfstate` and `prod.tfstate`, rather than one per architectural layer.

**The pipeline authenticates via GitHub OIDC federation** to an Entra app registration with three federated credentials, scoped to the main branch, to pull requests, and to the `dev` environment. No secret exists anywhere.

Reasoning, against the constraints above:

The Azure Storage backend keeps the whole system inside one control plane and one identity provider. Every failure is an Azure failure and gets diagnosed in one place. Against a $50 ceiling, a dollar a month is noise.

Versioning is the piece worth paying for. It gives point-in-time recovery of the state file, which is the single object whose loss would be genuinely painful, without standing up any backup product.

Shared key access is disabled deliberately. It costs a role assignment and a propagation wait during bootstrap, and it means a leaked storage account name grants nothing without an Entra identity behind it. On a public repository that tradeoff is obvious.

One state file per environment, not per layer, is the honest call for a single-subscription estate with one operator. Splitting networking state from application state limits blast radius, but it introduces `terraform_remote_state` lookups, an ordering dependency between pipelines, and more places to be wrong. At this size the blast radius of a bad apply is one environment that gets rebuilt nightly anyway. See Consequences for the threshold at which this stops being true.

OIDC over a client secret needs little defense. The deciding factor is not just rotation hygiene: a public repository invites scrutiny, and a credential model where no secret exists is far easier to reason about than one where a secret exists but is claimed to be well protected.

The pipeline identity holds Owner at subscription scope. This is broader than it should be. Phase 1 creates role assignments and policy assignments, both of which need rights beyond Contributor, and the tighter pattern of Contributor plus Role Based Access Control Administrator was not worth the setup time for a single-subscription environment. In a real tenant this would be a PIM-eligible assignment activated per run rather than a standing one. Recorded here as a known deviation rather than a defensible choice.

## Consequences

**The bootstrap step cannot be managed by Terraform.** The state account and the app registration are created by `bootstrap/Initialize-AzureBootstrap.ps1`, which is idempotent but is still imperative code doing work the rest of the repository does declaratively. Anyone reproducing this environment has to run it first. The script is checked in and documented, which is the best available mitigation, not a fix.

**Losing the state file is worse than losing the code.** Versioning and soft delete are the mitigation. The recovery path has not been tested, which is a gap worth closing before Phase 4 puts a database behind it. A restore drill belongs on the Phase 6 list.

**The single state file gets slower and riskier as the estate grows.** Every plan refreshes every resource. Revisit when the environment exceeds roughly 200 resources, when a second contributor arrives, or when the platform layer stops changing at the same rate as the applications on top of it. The migration path is `terraform state mv` into split state files, which is mechanical but tedious and is best done before it is urgent.

**The subject claim is a literal string, and it broke twice during bootstrap.** Both failures are worth recording, because neither is obvious from the documentation.

First, GitHub does not necessarily send the subject format the documentation shows. This account emits an immutable subject containing numeric owner and repository IDs:

```
repo:{owner}@{ownerId}/{repo}@{repoId}:ref:refs/heads/main
```

A federated credential built on the documented `repo:{owner}/{repo}:ref:refs/heads/main` fails with AADSTS700213, which reports the presented subject but does not explain why it differs. The numeric IDs are a security improvement, since they bind the credential to a specific repository rather than to a name that could be released and re-registered by someone else. The correct approach is to read the prefix from the API rather than construct it:

```powershell
(gh api repos/{owner}/{repo}/actions/oidc/customization/sub | ConvertFrom-Json).sub_claim_prefix
```

Second, and more surprising: the immutable subject does not protect against an owner rename. The numeric IDs survive a rename, but the human-readable name is still part of the prefix, so every federated credential broke when the account was renamed from `josholliff-com` to `josholliff`. Git remotes are transparently redirected by GitHub, which makes this worse rather than better, because the push succeeds and only the pipeline fails. The failure surfaces as an authentication error with no indication that a rename caused it.

Operationally this means the federated credentials are coupled to the account name, and renaming the account or transferring the repository is a breaking change requiring credential updates in Entra. That coupling should be in the runbook.

**No secret means no break-glass.** If GitHub's OIDC provider is unavailable, the pipeline cannot deploy and there is no fallback credential to fall back to. Accepted: this environment has no availability requirement, and adding a standing secret to work around an outage would reintroduce exactly the risk OIDC removes. In an estate with a real SLA, the answer is a separately governed break-glass identity, not a second credential on the pipeline app.

## Revisit when

- Resource count in a single state file passes roughly 200, or `terraform plan` takes longer than two minutes
- A second contributor joins, making concurrent applies and run history a real concern rather than a hypothetical
- The platform layer and the application layer diverge in change rate enough that one blocks the other
- A second subscription enters scope, at which point per-layer state and a per-subscription identity both need rethinking
- The GitHub account or organization is renamed, or the repository is transferred
