---
name: SuperCollider var declarations must be at the top of a block
description: In SuperCollider, all var statements must appear before any other code within a function block
type: feedback
---

In SuperCollider, all `var` declarations must be at the top of their enclosing function block `{ }`, before any non-var statements. Placing a `var` after executable code (even in the middle of what looks like a declaration sequence) will break.

**Why:** SuperCollider's compiler requires this — it's a language-level constraint, not a style preference.

**How to apply:** When adding new variables in an existing block, either declare them uninitialized at the top (`var foo;`) and assign later, or reorder so all `var` lines come first. This applies to every `{ }` function block, including `if`-branch blocks, `schedAbs` callbacks, method bodies, etc.
