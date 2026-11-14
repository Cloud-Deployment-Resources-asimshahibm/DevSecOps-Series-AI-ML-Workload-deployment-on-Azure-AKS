{{- define "sp.registry" -}}
{{ required "registry (ACR login server) is required" .Values.registry }}
{{- end -}}

{{- define "sp.mlMatch" -}}
match:
  any:
    - resources:
        kinds: [Pod]
        namespaces:
          {{- toYaml .Values.mlNamespaces | nindent 10 }}
{{- end -}}
