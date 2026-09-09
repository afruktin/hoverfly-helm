# hoverfly

Hoverfly API simulator, with optional persistence of recorded simulations across Pod restarts

**Homepage:** <https://hoverfly.io>

## TL;DR

```console
helm repo add hoverfly https://afruktin.github.io/hoverfly-helm
helm repo update
helm install my-hoverfly hoverfly/hoverfly
```

## Introduction

[Hoverfly](https://hoverfly.io) is an API simulator: it records real traffic and replays it,
so tests run against a stand-in for a slow, rate-limited or not-yet-built dependency.

Hoverfly keeps simulations **in memory** and never writes them to disk on its own, so a Pod
restart normally throws away everything recorded. This chart can persist them: a `preStop`
hook dumps `/api/v2/simulation` onto a volume and the next start imports the file back.
An optional sidecar snapshots the simulation periodically, covering an `OOMKill` where
`preStop` never runs.

## Prerequisites

- Kubernetes 1.23+ (1.29+ if you enable `snapshot.nativeSidecar`)
- Helm 3.8+
- A StorageClass that supports dynamic provisioning, if you enable persistence

## Installing the chart

```console
helm install my-hoverfly hoverfly/hoverfly
```

Verify the release:

```console
helm test my-hoverfly
```

## Uninstalling the chart

```console
helm uninstall my-hoverfly
```

The PVC is deleted with the release unless you set `persistence.retain=true`.

## Persisting simulations across restarts

```yaml
persistence:
  enabled: true
  size: 1Gi
  retain: true      # keep the PVC when the release is removed

snapshot:
  enabled: true     # off by default; covers OOMKill, at the cost of one more container
  intervalSeconds: 600
```

How it works:

| Moment | What happens |
|--------|--------------|
| Startup | The state file on the volume is imported with `-import`, if it exists and is non-empty |
| Every `snapshot.intervalSeconds` | The sidecar dumps `/api/v2/simulation` to the volume, if `snapshot.enabled` |
| Graceful shutdown | The `preStop` hook takes a final dump before the container exits |

Two caveats worth knowing:

- A `ReadWriteOnce` volume cannot be attached by two Pods at once, so the chart forces
  `strategy: Recreate` and refuses `replicaCount > 1` unless `persistence.accessModes`
  contains `ReadWriteMany`.
- The preStop hook needs to finish within `terminationGracePeriodSeconds`. Raise it if you
  record large simulations.

Set `snapshot.nativeSidecar=true` on Kubernetes 1.29+ to run the snapshotter as a native
sidecar, which guarantees it terminates *after* the main container rather than racing it.

## Supplying simulations declaratively

Simulations can be baked into the release instead of recorded at runtime:

```yaml
simulations:
  inline:
    greeting.json: |
      {
        "data": {
          "pairs": [
            {
              "request": {"path": [{"matcher": "exact", "value": "/greeting"}]},
              "response": {"status": 200, "body": "hello", "encodedBody": false}
            }
          ]
        },
        "meta": {"schemaVersion": "v5.2"}
      }
```

Changing them rolls the Pod, because the ConfigMap checksum is part of the Pod annotations.

To reuse a ConfigMap you manage elsewhere, set `simulations.existingConfigMap` together with
`simulations.existingConfigMapFiles` (the keys to import). It is mutually exclusive with
`simulations.inline` — both mount at `simulations.mountPath`.

`-import` is repeatable, and the chart orders the sources so that **runtime state wins**:
ConfigMap simulations first, then `simulations.extraImports`, then the persisted snapshot.

## Protecting the admin API

```yaml
auth:
  enabled: true
  username: admin
  password: change-me
```

The chart creates the Secret for you; point `auth.existingSecret` at your own Secret (with
`auth.usernameKey` / `auth.passwordKey`) if you manage credentials with an external operator.

The password is never written into the Deployment manifest — it reaches the container through
`secretKeyRef`, and the snapshot helper exchanges it for a token at `/api/token-auth`.
`/api/health` stays public under `-auth`, so probes and `helm test` keep working.

## Exposing admin and proxy on one hostname

The admin API and the proxy listen on different ports. `ingress.hosts[].paths[].servicePortName`
routes each path to the right one:

```yaml
ingress:
  enabled: true
  className: nginx
  hosts:
    - host: hoverfly.example.com
      paths:
        - {path: /api/v2,     pathType: Prefix, servicePortName: admin}
        - {path: /api/health, pathType: Prefix, servicePortName: admin}
        - {path: /dashboard,  pathType: Prefix, servicePortName: admin}
        - {path: /,           pathType: Prefix, servicePortName: proxy}
```

## Security context

The upstream image ships no `USER` directive and runs as root. Because the Hoverfly binary is
statically linked and writes nothing to the root filesystem under the chart's defaults, the
chart pins an unprivileged UID, drops all capabilities and mounts the root filesystem
read-only, with an `emptyDir` on `/tmp`. Relax `podSecurityContext` / `securityContext` if you
add middleware that needs to write.

## Requirements

Kubernetes: `>=1.23.0-0`

## Values

The settings below cover the common cases. Every value the chart accepts is listed,
with comments, in [values.yaml](values.yaml) and validated by `values.schema.json`.

### Workload

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| replicaCount | int | `1` | Number of Hoverfly replicas. Note that simulations live in each Pod's memory: with more than one replica the instances diverge unless every simulation is supplied through `simulations`. |
| image.repository | string | `"spectolabs/hoverfly"` | Container image repository. |
| image.tag | string | `.Chart.AppVersion` | Container image tag. |
| resources | object | `{}` | Resource requests and limits for the hoverfly container. |

### Hoverfly

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| hoverfly.logLevel | string | `"info"` | Log level (`-log-level`): panic, fatal, error, warn, info or debug. |
| hoverfly.webserver | bool | `true` | Run as a webserver in simulate mode instead of a forward proxy (`-webserver`). |
| hoverfly.upstreamProxy | string | `""` | Upstream proxy to route traffic through (`-upstream-proxy`). |
| hoverfly.middleware | string | `""` | Middleware to run, as `<binary> <script path>` (`-middleware`). |
| hoverfly.extraArgs | list | `[]` | Additional raw flags appended verbatim, for example `["-spy", "-journal-size=5000"]`. |

### Persistence

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| persistence.enabled | bool | `false` | Persist simulations across Pod restarts on a PersistentVolumeClaim. This also installs the preStop hook that dumps the simulation to the volume on shutdown; there is no separate switch for it. |
| persistence.size | string | `"1Gi"` | Size of the PVC. |
| persistence.storageClass | string | `""` | StorageClass for the PVC. `""` uses the cluster default; `"-"` disables dynamic provisioning. |
| persistence.existingClaim | string | `""` | Use an existing PVC instead of creating one. |
| persistence.retain | bool | `false` | Keep the PVC on `helm uninstall` (`helm.sh/resource-policy: keep`). |
| snapshot.enabled | bool | `false` | Run a sidecar that periodically dumps the simulation to the volume, so an OOMKill (where preStop never runs) loses at most one interval of traffic. Only takes effect together with `persistence.enabled`. |
| snapshot.intervalSeconds | int | `600` | Seconds between snapshots. |
| snapshot.nativeSidecar | bool | `false` | Run as a native sidecar (init container with `restartPolicy: Always`) so it terminates after the main container. Requires Kubernetes >= 1.29. |

### Simulations

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| simulations.inline | object | `{}` | Simulations rendered into a ConfigMap and imported on startup. Map of file name to simulation JSON, for example `{"basic.json": "{\"data\": {...}, \"meta\": {...}}"}`. |
| simulations.existingConfigMap | string | `""` | Import simulations from an existing ConfigMap instead. Mutually exclusive with `inline`. |
| simulations.extraImports | list | `[]` | Extra `-import` sources passed verbatim (URLs, or paths you mounted yourself). |

### Admin API auth

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| auth.enabled | bool | `false` | Protect the admin API with a username and password (`-auth`). `/api/health` stays public, so probes keep working. |
| auth.username | string | `"hoverfly"` | Admin username. |
| auth.password | string | `""` | Admin password. Required unless `auth.existingSecret` is set. Avoid control characters: the value is sent as a JSON string by the snapshot helper. |
| auth.existingSecret | string | `""` | Use an existing Secret instead of creating one. |

### Networking

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| service.type | string | `"ClusterIP"` | Service type. |
| ingress.enabled | bool | `false` | Create an Ingress. |
| ingress.className | string | `""` | IngressClass name. |
| ingress.hosts | list | `[{"host":"hoverfly.local","paths":[{"path":"/api/v2","pathType":"Prefix","servicePortName":"admin"},{"path":"/api/health","pathType":"Prefix","servicePortName":"admin"},{"path":"/dashboard","pathType":"Prefix","servicePortName":"admin"},{"path":"/","pathType":"Prefix","servicePortName":"proxy"}]}]` | Host rules. Each path may target a named Service port through `servicePortName`, which is how the admin API and the proxy get split across one hostname. |
## Maintainers

| Name | Email | Url |
| ---- | ------ | --- |
| Artyom Fruktin | <68115238+afruktin@users.noreply.github.com> | <https://github.com/afruktin> |

## Source Code

* <https://github.com/afruktin/hoverfly-helm>
* <https://github.com/SpectoLabs/hoverfly>
