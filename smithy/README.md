# smithy

`smithy_gen.exe` turns an AWS [Smithy][smithy] JSON AST model into one OCaml module for a
service that speaks AWS JSON 1.0 or 1.1. The generated file is committed; regenerate it when the
model or the generator changes:

```sh
dune exec smithy/smithy_gen.exe -- smithy/models/ssm.json > aws_api_ssm/aws_api_ssm.ml
```

Models come from [aws/api-models-aws][models] (`models/<service>/service/<version>/*.json`) and
are vendored under `models/`.

What is generated, and what is deliberately not:

- Every non-error `structure` and `union` becomes a record in one recursive type group. Required
  members are plain fields; the rest are `option` with `[@yojson.option]`. Unions are records of
  options. Empty structures and `smithy.api#Unit` are `Aws_api_json.Json.empty`.
- Serialization is `[@@deriving yojson]`, not generated code. Timestamps, blobs, maps and documents
  map to the types in `runtime/wire.ml`.
- Enums are `string`. Error shapes are skipped: every operation fails with `Aws_api_json.Error.t`.
- One module per operation with `request`, `response` and `perform`, built by
  `runtime/transport.ml`. No pagination, retries, or documentation.

`runtime/` (transport: endpoint, sigv4 signing, status mapping; error body; wire types) is not a
package. Each generated package copies it in with `(copy_files# ../smithy/runtime/*.ml)`, so the
generated module exposes it as `Aws_api_<svc>.Transport` / `Error` / `Wire`.

Supported protocols: `aws.protocols#awsJson1_0`, `aws.protocols#awsJson1_1`. REST-XML (S3) and
REST-JSON are out of scope.

[smithy]: https://smithy.io/
[models]: https://github.com/aws/api-models-aws
