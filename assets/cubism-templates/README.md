# Built-in Cubism templates

Release builds require exactly these internally authored runtime templates:

- `cat-v1`
- `dog-long-snout-v1`
- `dog-short-snout-v1`

Each directory must contain a valid `quadruped-v2` `realpet-template.json`,
`realpet-provenance.json`, `.model3.json`, `.moc3`, texture, and every file
referenced by the model. The provenance record must point to an original `.cmo3`
source project inside this repository and match its SHA-256.

After an internal Editor export, promote it atomically with:

```bash
./scripts/promote_cubism_template.py \
  --profile dog-long-snout-v1 \
  --export-dir /path/to/cubism-export \
  --descriptor artifacts/original-live2d/pomeranian-086ec6ba/realpet-template-authoring.json \
  --source-cmo3 artifacts/original-live2d/pomeranian-086ec6ba/pomeranian-editor-autosave.cmo3 \
  --model-relative pet.model3.json \
  --texture-relative pet.2048/texture_00.png
```

Do not place third-party sample models in these directories. A generated atlas
or static layered `.cmo3` is not a valid template; every required parameter must
have authored mesh/deformer keyforms and the exported package must pass the
runtime validator.
