# shopnexus (umbrella)

## Compose and the cluster stay in step

The system runs two ways: `docker-compose.yml` locally and the k3s cluster
from `infra/` (Argo CD, the chart in `infra/stack`). A feature must not need
the same change written twice, once in compose and once in the chart.

- Put the change where both read it. Database roles, grants, extensions and
  seed rows go in a server migration (`server/migrations`), which compose's
  migrate service and the cluster's migrate hook both run. Behaviour goes in
  the app's code.
- A setting that is the same in compose and in every cluster stack goes in
  `infra/stack/env/server.env`, `infra/stack/env/agent.env` or
  `infra/stack/env/litellm.env`. The chart
  reads them with `.Files.Get` and compose with `env_file`. Only a setting
  that differs between stacks, or between compose and the cluster, goes in
  `_server-env.tpl`, `agent.yaml` and compose's `x-server-env*`,
  `x-agent-env*` and `x-litellm` blocks. A key in both places fails the chart's render and
  `infra/check.sh`.
- A change only one side can have (Traefik routes, NetworkPolicies,
  SealedSecrets, Argo CD options, Caddy on the server) stays on that side and
  needs nothing on the other.
- A new service, such as a new dashboard or a new app, may add itself to
  both: its compose service and its chart templates.
- When a change would still need both edited, say so before writing it and
  propose the shared place instead.
