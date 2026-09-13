## 1. The refusal

- [x] 1.1 Replace the `helm unittest` case that asserts the special message with one asserting that
  the name is refused as any other unknown backend is; verify it fails against the unmodified chart
- [x] 1.2 Remove the special case from `_helpers.tpl`

## 2. Documentation

- [x] 2.1 Remove the third backend from `values.yaml` and say instead why there are two, in terms of
  what each asks of the image and of the init system; run `make docs`
- [x] 2.2 Remove it from the chart README and the project README, including the entry in
  *Known limitations*
- [x] 2.3 Verify no live file outside `docs/research/` and `openspec/changes/archive/` names it

## 3. Everything still holds

- [x] 3.1 Run `make all`; verify it is green
