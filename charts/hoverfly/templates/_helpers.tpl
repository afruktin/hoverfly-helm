{{/*
Expand the name of the chart.
*/}}
{{- define "hoverfly.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
Truncated at 63 chars because some Kubernetes name fields are limited to this.
*/}}
{{- define "hoverfly.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Chart name and version as used by the helm.sh/chart label.
*/}}
{{- define "hoverfly.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Render a value that may contain Go template syntax.
Usage: {{ include "hoverfly.tplvalues" (dict "value" .Values.foo "context" $) }}
*/}}
{{- define "hoverfly.tplvalues" -}}
{{- $value := typeIs "string" .value | ternary .value (toYaml .value) }}
{{- if contains "{{" $value }}
{{- tpl $value .context }}
{{- else }}
{{- $value }}
{{- end }}
{{- end }}

{{/*
Selector labels. These end up in an immutable field, so they must stay minimal.
*/}}
{{- define "hoverfly.selectorLabels" -}}
app.kubernetes.io/name: {{ include "hoverfly.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Common labels applied to every object.
*/}}
{{- define "hoverfly.labels" -}}
helm.sh/chart: {{ include "hoverfly.chart" . }}
{{ include "hoverfly.selectorLabels" . }}
{{- with .Chart.AppVersion }}
app.kubernetes.io/version: {{ . | quote }}
{{- end }}
app.kubernetes.io/component: api-simulator
app.kubernetes.io/part-of: hoverfly
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.commonLabels }}
{{ include "hoverfly.tplvalues" (dict "value" . "context" $) }}
{{- end }}
{{- end }}

{{/*
Common annotations applied to every object.
*/}}
{{- define "hoverfly.annotations" -}}
{{- with .Values.commonAnnotations }}
{{- include "hoverfly.tplvalues" (dict "value" . "context" $) }}
{{- end }}
{{- end }}

{{/*
Image tag, defaulting to the chart's appVersion.
*/}}
{{- define "hoverfly.imageTag" -}}
{{- default .Chart.AppVersion .Values.image.tag }}
{{- end }}

{{/*
Fully qualified image reference. A digest, when set, wins over the tag.
*/}}
{{- define "hoverfly.image" -}}
{{- $repository := .Values.image.repository -}}
{{- if .Values.image.registry -}}
{{- $repository = printf "%s/%s" .Values.image.registry .Values.image.repository -}}
{{- end -}}
{{- if .Values.image.digest -}}
{{- printf "%s@%s" $repository .Values.image.digest -}}
{{- else -}}
{{- printf "%s:%s" $repository (include "hoverfly.imageTag" .) -}}
{{- end -}}
{{- end }}

{{/*
Image used by the snapshot sidecar. Unset fields fall back to .Values.image.
*/}}
{{- define "hoverfly.snapshot.image" -}}
{{- $override := .Values.snapshot.image | default dict -}}
{{- $base := deepCopy .Values.image -}}
{{- /*
tag and digest name the same thing two different ways, and `hoverfly.image`
prefers the digest. Inheriting them field by field would therefore let the main
image's digest silently outrank an explicit snapshot.image.tag -- the sidecar
would run whatever the main image is pinned to. Drop both from the inherited
half as soon as the override supplies either one.
*/ -}}
{{- if or $override.tag $override.digest -}}
{{- $base = omit $base "tag" "digest" -}}
{{- end -}}
{{- $image := merge (deepCopy $override) $base -}}
{{- include "hoverfly.image" (dict "Values" (dict "image" $image) "Chart" .Chart) -}}
{{- end }}

{{- define "hoverfly.snapshot.imagePullPolicy" -}}
{{- default .Values.image.pullPolicy (.Values.snapshot.image).pullPolicy }}
{{- end }}

{{/*
Name of the ServiceAccount to use.
*/}}
{{- define "hoverfly.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "hoverfly.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Name of the Secret holding admin API credentials.
*/}}
{{- define "hoverfly.auth.secretName" -}}
{{- default (printf "%s-auth" (include "hoverfly.fullname" .)) .Values.auth.existingSecret }}
{{- end }}

{{/*
Name of the ConfigMap holding simulations.
*/}}
{{- define "hoverfly.simulations.configMapName" -}}
{{- default (printf "%s-simulations" (include "hoverfly.fullname" .)) .Values.simulations.existingConfigMap }}
{{- end }}

{{/*
Whether a simulations volume needs to be mounted at all.
*/}}
{{- define "hoverfly.simulations.mounted" -}}
{{- if or .Values.simulations.inline .Values.simulations.existingConfigMap -}}true{{- end -}}
{{- end }}

{{/*
Name of the PersistentVolumeClaim backing simulation state.
*/}}
{{- define "hoverfly.pvcName" -}}
{{- default (printf "%s-data" (include "hoverfly.fullname" .)) .Values.persistence.existingClaim }}
{{- end }}

{{/*
Absolute path of the persisted simulation snapshot.
*/}}
{{- define "hoverfly.stateFile" -}}
{{- printf "%s/%s" (trimSuffix "/" .Values.persistence.mountPath) .Values.persistence.filename }}
{{- end }}

{{/*
Admin API base URL as reachable from inside the pod.
*/}}
{{- define "hoverfly.localAdminUrl" -}}
{{- printf "http://127.0.0.1:%v" .Values.hoverfly.adminPort }}
{{- end }}

{{/*
Whether the container command needs a shell wrapper. A shell is only used when
something has to be decided at runtime: importing a snapshot that may not exist
yet, or injecting credentials that must not appear in the pod spec.
*/}}
{{- define "hoverfly.needsShell" -}}
{{- if or .Values.persistence.enabled .Values.auth.enabled -}}true{{- end -}}
{{- end }}

{{/*
Hoverfly command line flags, as a YAML list.

These are passed through the container's `args`, never spliced into a shell
string, so no value here can break out of its argument.
*/}}
{{- define "hoverfly.args" -}}
{{- $args := list -}}
{{- with .Values.hoverfly.listenOnHost -}}
{{- $args = append $args (printf "-listen-on-host=%s" .) -}}
{{- end -}}
{{- $args = append $args (printf "-ap=%v" .Values.hoverfly.adminPort) -}}
{{- $args = append $args (printf "-pp=%v" .Values.hoverfly.proxyPort) -}}
{{- if .Values.hoverfly.webserver -}}
{{- $args = append $args "-webserver" -}}
{{- else -}}
{{- $modeFlags := dict "capture" "-capture" "spy" "-spy" "diff" "-diff" "synthesize" "-synthesize" "modify" "-modify" -}}
{{- $modeFlag := index $modeFlags .Values.hoverfly.mode -}}
{{- if $modeFlag -}}
{{- $args = append $args $modeFlag -}}
{{- end -}}
{{- if .Values.hoverfly.captureOnMiss -}}
{{- $args = append $args "-capture-on-miss" -}}
{{- end -}}
{{- end -}}
{{- with .Values.hoverfly.logLevel -}}
{{- $args = append $args (printf "-log-level=%s" .) -}}
{{- end -}}
{{- with .Values.hoverfly.logsFormat -}}
{{- $args = append $args (printf "-logs=%s" .) -}}
{{- end -}}
{{- with .Values.hoverfly.journalSize -}}
{{- $args = append $args (printf "-journal-size=%v" .) -}}
{{- end -}}
{{- with .Values.hoverfly.cacheSize -}}
{{- $args = append $args (printf "-cache-size=%v" .) -}}
{{- end -}}
{{- if .Values.hoverfly.disableCache -}}
{{- $args = append $args "-disable-cache" -}}
{{- end -}}
{{- if not .Values.hoverfly.tlsVerification -}}
{{- $args = append $args "-tls-verification=false" -}}
{{- end -}}
{{- if .Values.hoverfly.cors -}}
{{- $args = append $args "-cors" -}}
{{- end -}}
{{- with .Values.hoverfly.upstreamProxy -}}
{{- $args = append $args (printf "-upstream-proxy=%s" .) -}}
{{- end -}}
{{- with .Values.hoverfly.middleware -}}
{{- $args = append $args (printf "-middleware=%s" .) -}}
{{- end -}}
{{- with .Values.hoverfly.destination -}}
{{- $args = append $args (printf "-destination=%s" .) -}}
{{- end -}}
{{- $mount := trimSuffix "/" .Values.simulations.mountPath -}}
{{- range $name, $_ := .Values.simulations.inline -}}
{{- $args = append $args (printf "-import=%s/%s" $mount $name) -}}
{{- end -}}
{{- range .Values.simulations.existingConfigMapFiles -}}
{{- $args = append $args (printf "-import=%s/%s" $mount .) -}}
{{- end -}}
{{- range .Values.simulations.extraImports -}}
{{- $args = append $args (printf "-import=%s" .) -}}
{{- end -}}
{{- range .Values.hoverfly.extraArgs -}}
{{- $args = append $args . -}}
{{- end -}}
{{- toYaml $args -}}
{{- end }}

{{/*
Shell functions shared by the entrypoint wrapper, the preStop hook and the
snapshot sidecar. Everything variable is read from the environment, so no
user-supplied value is ever interpolated into shell source.
*/}}
{{- define "hoverfly.script.lib" -}}
hf_token() {
  [ "${HOVERFLY_AUTH_ENABLED:-false}" = "true" ] || return 0
  _u=$(printf '%s' "${HOVERFLY_ADMIN_USERNAME:-}" | sed 's/[\\"]/\\&/g')
  _p=$(printf '%s' "${HOVERFLY_ADMIN_PASSWORD:-}" | sed 's/[\\"]/\\&/g')
  wget -q -O - --header='Content-Type: application/json' \
    --post-data="{\"username\":\"${_u}\",\"password\":\"${_p}\"}" \
    "${HOVERFLY_ADMIN_URL}/api/token-auth" 2>/dev/null |
    sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}
hf_snapshot() {
  [ -n "${HOVERFLY_STATE_FILE:-}" ] || return 1
  _tmp="${HOVERFLY_STATE_TMP:-${HOVERFLY_STATE_FILE}.tmp}"
  _tok=$(hf_token || true)
  if [ -n "${_tok}" ]; then
    wget -q -O "${_tmp}" --header="Authorization: Bearer ${_tok}" \
      "${HOVERFLY_ADMIN_URL}/api/v2/simulation" || { rm -f "${_tmp}"; return 1; }
  else
    wget -q -O "${_tmp}" "${HOVERFLY_ADMIN_URL}/api/v2/simulation" || { rm -f "${_tmp}"; return 1; }
  fi
  if [ -s "${_tmp}" ]; then
    mv -f "${_tmp}" "${HOVERFLY_STATE_FILE}"
  else
    rm -f "${_tmp}"
    return 1
  fi
}
{{- end }}

{{/*
Container entrypoint. Real flags arrive via `args` and are only ever forwarded
as "$@"; the snapshot path and credentials arrive via the environment.
*/}}
{{- define "hoverfly.script.entrypoint" -}}
set -eu
if [ -n "${HOVERFLY_STATE_FILE:-}" ] && [ -s "${HOVERFLY_STATE_FILE}" ]; then
  set -- "$@" -import "${HOVERFLY_STATE_FILE}"
fi
if [ "${HOVERFLY_AUTH_ENABLED:-false}" = "true" ]; then
  set -- "$@" -auth -username "${HOVERFLY_ADMIN_USERNAME}" -password "${HOVERFLY_ADMIN_PASSWORD}"
fi
exec /bin/hoverfly "$@"
{{- end }}

{{/*
preStop hook: dump the in-memory simulation onto the volume before shutdown.
*/}}
{{- define "hoverfly.script.preStop" -}}
{{ include "hoverfly.script.lib" . }}
hf_snapshot || true
{{- end }}

{{/*
Snapshot sidecar: periodic dump, so an OOMKill (where preStop never runs)
loses at most one interval of recorded traffic.
*/}}
{{- define "hoverfly.script.snapshotLoop" -}}
{{ include "hoverfly.script.lib" . }}
trap 'hf_snapshot || true; exit 0' TERM INT
while true; do
  sleep "${HOVERFLY_SNAPSHOT_INTERVAL}" &
  wait $!
  hf_snapshot || true
done
{{- end }}

{{/*
Environment shared by the hoverfly container and the snapshot sidecar.
*/}}
{{- define "hoverfly.runtimeEnv" -}}
- name: HOVERFLY_ADMIN_URL
  value: {{ include "hoverfly.localAdminUrl" . | quote }}
{{- if .Values.persistence.enabled }}
- name: HOVERFLY_STATE_FILE
  value: {{ include "hoverfly.stateFile" . | quote }}
{{- end }}
{{- if .Values.auth.enabled }}
- name: HOVERFLY_AUTH_ENABLED
  value: "true"
- name: HOVERFLY_ADMIN_USERNAME
  valueFrom:
    secretKeyRef:
      name: {{ include "hoverfly.auth.secretName" . }}
      key: {{ .Values.auth.usernameKey }}
- name: HOVERFLY_ADMIN_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "hoverfly.auth.secretName" . }}
      key: {{ .Values.auth.passwordKey }}
{{- end }}
{{- end }}

{{/*
Fail early, with an actionable message, on value combinations that would
otherwise surface as a stuck Pod or a confusing API error.
*/}}
{{- define "hoverfly.validateValues" -}}
{{- $errors := list -}}
{{- if and .Values.hoverfly.webserver (ne .Values.hoverfly.mode "simulate") -}}
{{- $errors = append $errors (printf "  - hoverfly.mode=%q is ignored while hoverfly.webserver=true.\n    Hoverfly resolves the startup mode with `if webserver { return simulate }` before it looks at any\n    mode flag, so it neither warns nor fails -- it just runs in simulate mode.\n    Set hoverfly.webserver=false to use this mode." .Values.hoverfly.mode) -}}
{{- end -}}
{{- if and (has .Values.hoverfly.mode (list "synthesize" "modify")) (not .Values.hoverfly.middleware) -}}
{{- $errors = append $errors (printf "  - hoverfly.mode=%q requires hoverfly.middleware to be set; Hoverfly exits at startup otherwise,\n    which turns into a CrashLoopBackOff. On Kubernetes prefer remote middleware -- an http:// URL\n    pointing at a separate Deployment -- because the hoverfly image ships no script runtime." .Values.hoverfly.mode) -}}
{{- end -}}
{{- if and .Values.hoverfly.captureOnMiss (ne .Values.hoverfly.mode "spy") -}}
{{- $errors = append $errors "  - hoverfly.captureOnMiss=true requires hoverfly.mode=spy. Hoverfly exits with\n    \"-capture-on-miss can only be used with -spy mode\" for any other mode." -}}
{{- end -}}
{{- $modeFlagNames := list "capture" "spy" "diff" "synthesize" "modify" "webserver" -}}
{{- range .Values.hoverfly.extraArgs -}}
{{- $flag := . | trimPrefix "-" | trimPrefix "-" | splitList "=" | first -}}
{{- if has $flag $modeFlagNames -}}
{{- $errors = append $errors (printf "  - hoverfly.extraArgs contains %q, which selects a startup mode. Use hoverfly.mode and\n    hoverfly.webserver instead: Hoverfly exits with \"Two or more modes supplied\" when it sees\n    more than one mode flag, and a mode set this way is invisible to the chart's validation." .) -}}
{{- end -}}
{{- end -}}
{{- if and .Values.persistence.enabled (gt (int .Values.replicaCount) 1) -}}
{{- if not (has "ReadWriteMany" .Values.persistence.accessModes) -}}
{{- $errors = append $errors "  - persistence.enabled=true with replicaCount>1 requires persistence.accessModes to contain ReadWriteMany.\n    With ReadWriteOnce only one Pod can attach the volume and the others stay Pending forever.\n    Either set replicaCount=1, or use a ReadWriteMany StorageClass." -}}
{{- end -}}
{{- end -}}
{{- if and .Values.persistence.enabled .Values.snapshot.enabled .Values.snapshot.nativeSidecar -}}
{{- if not (semverCompare ">=1.29.0-0" .Capabilities.KubeVersion.Version) -}}
{{- $errors = append $errors (printf "  - snapshot.nativeSidecar=true needs Kubernetes 1.29 or newer; this cluster reports %s.\n    A native sidecar is an initContainer carrying `restartPolicy: Always`, and an older kubelet simply\n    ignores that field: the snapshot loop would run as an ordinary init container, never exit, and the\n    Pod would never reach the main container.\n    Set snapshot.nativeSidecar=false to get a plain sidecar container instead." .Capabilities.KubeVersion.Version) -}}
{{- end -}}
{{- end -}}
{{- if and .Values.auth.enabled (not .Values.auth.existingSecret) (not .Values.auth.password) -}}
{{- $errors = append $errors "  - auth.enabled=true requires either auth.password or auth.existingSecret to be set." -}}
{{- end -}}
{{- if and .Values.simulations.inline .Values.simulations.existingConfigMap -}}
{{- $errors = append $errors "  - simulations.inline and simulations.existingConfigMap are mutually exclusive; both mount at simulations.mountPath. Pick one." -}}
{{- end -}}
{{- if and .Values.simulations.existingConfigMapFiles (not .Values.simulations.existingConfigMap) -}}
{{- $errors = append $errors "  - simulations.existingConfigMapFiles is set but simulations.existingConfigMap is empty." -}}
{{- end -}}
{{- if and .Values.ingress.enabled (not .Values.ingress.hosts) -}}
{{- $errors = append $errors "  - ingress.enabled=true requires at least one entry in ingress.hosts." -}}
{{- end -}}
{{- if and .Values.persistence.enabled .Values.persistence.existingClaim .Values.persistence.retain -}}
{{- $errors = append $errors "  - persistence.retain has no effect with persistence.existingClaim: the chart does not own that PVC. Remove persistence.retain." -}}
{{- end -}}
{{- if $errors -}}
{{- fail (printf "\n\nVALUES VALIDATION FAILED for chart %q:\n\n%s\n" .Chart.Name (join "\n" $errors)) -}}
{{- end -}}
{{- end }}

{{/*
The snapshot sidecar container spec, shared by the native-sidecar and the plain
sidecar rendering paths.
*/}}
{{- define "hoverfly.snapshotContainer" -}}
name: snapshotter
image: {{ include "hoverfly.snapshot.image" . | quote }}
imagePullPolicy: {{ include "hoverfly.snapshot.imagePullPolicy" . }}
{{- if .Values.snapshot.nativeSidecar }}
restartPolicy: Always
{{- end }}
command:
  - /bin/sh
  - -c
  - |
    {{- include "hoverfly.script.snapshotLoop" . | nindent 4 }}
env:
  - name: HOVERFLY_SNAPSHOT_INTERVAL
    value: {{ .Values.snapshot.intervalSeconds | quote }}
  - name: HOVERFLY_STATE_TMP
    value: {{ printf "%s.snapshot.tmp" (include "hoverfly.stateFile" .) | quote }}
  {{- include "hoverfly.runtimeEnv" . | nindent 2 }}
{{- with .Values.snapshot.securityContext }}
securityContext:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.snapshot.resources }}
resources:
  {{- toYaml . | nindent 2 }}
{{- end }}
volumeMounts:
  - name: data
    mountPath: {{ .Values.persistence.mountPath }}
  {{- if (.Values.snapshot.securityContext).readOnlyRootFilesystem }}
  - name: tmp
    mountPath: /tmp
  {{- end }}
{{- end }}
