# ADR NNNN: Short title stating the decision

**Status:** Accepted | Superseded by ADR-NNNN | Proposed
**Date:** YYYY-MM-DD
**Phase:** N

## Context

What forced a decision. Constraints that were real: budget, existing skills on the team, compliance requirement, an SLA someone already signed. Two or three paragraphs at most.

State the constraints honestly. "Single subscription, $60 monthly ceiling" is a legitimate constraint and saying so is more credible than pretending you were designing for a Fortune 500.

## Options considered

### Option A: name

How it works in two sentences. Then:

- Cost: an actual number, monthly
- Operational burden: who runs it, what breaks at 2am
- Fits when: the conditions under which this is the right answer

### Option B: name

Same shape.

### Option C: name

Same shape.

## Decision

The one you picked, stated in a sentence. Then the reasoning, tied directly back to the constraints in Context. If the deciding factor was cost, say so. If it was that you already know one of these and not the other, say that too. Real architecture decisions get made on team capability constantly and pretending otherwise reads as inexperience.

## Consequences

What this costs you. Every decision closes doors and an ADR that lists only benefits is marketing, not engineering.

- What gets harder now
- What you would have to unwind to change course later, and roughly how expensive that unwind is
- What you are explicitly accepting as a risk
- What would trigger revisiting this: a scale threshold, a headcount change, a new compliance requirement

## Revisit when

A concrete trigger, not "periodically." For example: spoke count exceeds fifteen, or a second region enters scope, or monthly egress passes 500 GB.
