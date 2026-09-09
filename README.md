# Hoverfly Helm chart

Helm chart for the [Hoverfly](https://hoverfly.io) API simulator, with optional persistence
of simulations across Pod restarts. Packaged into a Helm repository hosted on
GitHub Pages.

## Usage

```console
helm repo add hoverfly https://afruktin.github.io/hoverfly-helm
helm repo update
helm install my-hoverfly hoverfly/hoverfly
```

Values reference, examples and upgrade notes live with the chart:
[charts/hoverfly/README.md](charts/hoverfly/README.md).

## Development

Requires [helm](https://helm.sh), the
[helm-unittest](https://github.com/helm-unittest/helm-unittest) plugin, and
[chart-testing](https://github.com/helm/chart-testing) for the full lint pass.

```console
helm plugin install https://github.com/helm-unittest/helm-unittest

helm lint charts/hoverfly --strict
helm unittest charts/hoverfly
ct lint --config .github/ct.yaml
```

On Helm 3, append `--version v1.0.3`. From v1.1.0 the plugin declares
`platformHooks` in its manifest, which only Helm 4 understands -- Helm 3 unpacks the
plugin and then refuses to load it. CI runs Helm 3 deliberately, so v1.0.3 is what the
suites are verified against.

CI runs the chart on a real cluster. A [kind](https://kind.sigs.k8s.io) node is created for
every pull request, and `ct install` installs the chart once per file in
[charts/hoverfly/ci/](charts/hoverfly/ci/) -- defaults, persistence, the snapshot sidecar in
both its plain and native form, `-auth`, declarative simulations and proxy mode -- waiting for
readiness and running the `helm test` hook each time. Each file says in its header what a green
run proves.

A second job, [.github/scripts/e2e-persistence.sh](.github/scripts/e2e-persistence.sh), covers
what an install alone cannot: it posts a simulation, replaces the Pod and checks the simulation
is still being served. It does that three times -- a graceful restart (only the `preStop` hook
can have written the file), a force-delete with grace period 0 (`preStop` is skipped, exactly as
in an OOMKill, so only the sidecar can have written it) and the same again behind `-auth`, which
additionally exercises the sidecar's `/api/token-auth` exchange.

Every values example in [charts/hoverfly/README.md](charts/hoverfly/README.md) is templated as
well, by [.github/scripts/render-doc-examples.py](.github/scripts/render-doc-examples.py), so a
renamed value or a new validation breaks the build rather than a reader's terminal.

Two gaps worth knowing. kind cannot run anything near the 1.23 floor the chart advertises, so the
lower bound of `kubeVersion` is only checked by rendering. And the Ingress is not installed in CI,
because a cluster with no ingress controller cannot make it ready.

`charts/hoverfly/README.md` is written by hand: it documents the common values, and
`charts/hoverfly/values.yaml` is the full reference. Keep both in step when adding a value.

## Releasing

Bump `version` in `charts/hoverfly/Chart.yaml` and merge to the default branch.
[chart-releaser](https://github.com/helm/chart-releaser-action) packages the chart,
creates a GitHub release and updates `index.yaml` on the `gh-pages` branch.

## License

[MIT](LICENSE). This covers the chart only — Hoverfly itself is distributed by
[SpectoLabs](https://github.com/SpectoLabs/hoverfly) under the Apache License 2.0.
