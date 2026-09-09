# Hoverfly Helm chart

Helm chart for the [Hoverfly](https://hoverfly.io) API simulator, with optional persistence
of recorded simulations across Pod restarts. Packaged into a Helm repository hosted on
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

CI never touches a live cluster: it lints the chart and renders the templates. The hardened
`securityContext`, the `preStop` dump and `snapshot.nativeSidecar` (which needs Kubernetes
1.29+) are only exercised on a real install, so verify those against a cluster before
relying on them.

`charts/hoverfly/README.md` is written by hand: it documents the common values, and
`charts/hoverfly/values.yaml` is the full reference. Keep both in step when adding a value.

## Releasing

Bump `version` in `charts/hoverfly/Chart.yaml` and merge to the default branch.
[chart-releaser](https://github.com/helm/chart-releaser-action) packages the chart,
creates a GitHub release and updates `index.yaml` on the `gh-pages` branch.

## License

[MIT](LICENSE). This covers the chart only — Hoverfly itself is distributed by
[SpectoLabs](https://github.com/SpectoLabs/hoverfly) under the Apache License 2.0.
