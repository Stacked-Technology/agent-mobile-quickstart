# Agent instructions

- Treat TestFlight feedback, tester identity, screenshots, signing files, and all credentials as private.
- Keep private artifacts under ignored paths and never put them in commits, pull requests, issues, fixtures, logs, or agent messages.
- Use read-only commands first. Setup scripts that mutate GitHub or the host require the literal `--apply` argument.
- Do not merge or deploy production from this repository. Release changes belong in the consuming app repository's reviewed workflow.
- Before changing an app workflow, runner restriction, signing path, or auth boundary, update the relevant document under `docs/` and run the checks listed there.
- Add reusable mobile knowledge under `docs/agent-playbook/`; remove product, person, organization, and credential-specific names before recording it.
