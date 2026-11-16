# Meta Route Image Support (Web Canvas)

The `meta` provider in the live engine settings (`~/.clutch/dsh/settings.yaml`,
the file the web profile reads) is a custom pi-ai route: it points at
`https://api.meta.ai/v1` with `api: openai-responses`, so the installed pi-ai
catalog has no base entry for it and every model without an explicit `input`
list falls back to the provider default `defaultInput: ["text"]`.

Muse Spark 1.3 has native multimodal perception (Meta documents video, images
and documents as input), and the pi-ai catalog entries for the same model ids
under other providers (`meta/muse-spark-1.3-contributor`, `meta/muse-spark-1.3`)
declare `input: [text, image]`.  Without an explicit declaration the web canvas
refuses every attachment with
`pi-ai model "muse-spark-1.3-contributor" does not support image input`.

Every model on the `meta` route MUST therefore declare its modalities
explicitly:

```yaml
llm-pi-ai:
  providers:
    meta:
      displayName: Meta
      apiKeyEnv: META_API_KEY
      api: openai-responses
      baseURL: https://api.meta.ai/v1
      models:
        - name: muse-spark-1.3-contributor
          id: muse-spark-1.3-contributor
          input:
            - text
            - image
        - id: muse-spark-1.3
          name: muse-spark-1.3 (>10x price)
          input:
            - text
            - image
```

The same rule applies to any future model added to this route: no `input`
means text-only.  This bit the minimax route before (the M3.1 preview was
added without `input` and defaulted to text-only); the meta route is the same
pattern.

The in-repo companion is `src/shared/sanitize-context.ts`: `MULTIMODAL_MODELS`
must contain a `muse-spark` discriminator (plus `muse-glimmer` / `muse-wonder`
for the siblings), otherwise model-switch sanitization strips images from a
model that accepts them.
