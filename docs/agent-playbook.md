# Agent playbook

Use this file as the index for durable mobile-agent knowledge. Add a short topic document under `docs/agent-playbook/` when a workflow, invariant, or setup detail will save future agents repeated discovery.

## What belongs here

- simulator/device setup that is stable across app changes;
- release, signing, and TestFlight sequencing;
- runner labels, environment gates, and validation commands;
- accessibility or privacy checks that must accompany common mobile tasks;
- known framework-specific traps with a reproducible verification command; and
- decisions about where a secret or private artifact is allowed to live.

## What does not belong here

- API keys, private keys, passwords, registration tokens, or JWTs;
- tester emails, screenshots, submission IDs, or verbatim private feedback;
- transient incident details that cannot generalize; or
- copied product logic that belongs in the app repository.

## Topic template

Create a document with:

1. **Trigger** — when an agent should read it.
2. **Invariant** — what must remain true.
3. **Procedure** — the smallest reliable sequence.
4. **Verification** — commands or manual checks that prove it.
5. **Failure handling** — when to stop and ask a human.
6. **Last reviewed** — date and owner role, never a private identity.

Prefer links to authoritative vendor documentation over copied pages. Keep the index small and move detailed variants into directly linked topic files.
