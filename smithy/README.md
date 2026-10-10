# smithy

`smithy_gen.exe` turns an AWS [Smithy][smithy] JSON AST model into one OCaml module for a
service that speaks AWS JSON 1.0 or 1.1. The generated file is committed; regenerate it when the
model or the generator changes:

```sh
dune exec smithy/smithy_gen.exe -- smithy/models/ssm.json > aws_api_ssm/aws_api_ssm.ml
dune exec smithy/smithy_gen.exe -- smithy/models/dynamodb.json > aws_api_dynamodb/aws_api_dynamodb.ml
```

Models come from [aws/api-models-aws][models] (`models/<service>/service/<version>/*.json`) and
are vendored under `models/`.

What is generated, and what is deliberately not:

- Every non-error `structure` and `union` becomes a record in one recursive type group. Required
  members are plain fields; the rest are `option` with `[@yojson.option]`. Unions are records of
  options. Empty structures and `smithy.api#Unit` are `Aws_json_wire.empty`.
- Serialization is `[@@deriving yojson]`, not generated code. Timestamps, blobs, maps and documents
  map to the types in `runtime/aws_json_wire.ml`.
- Enums are closed polymorphic variants tagged by member name, plus `` `Unknown_value of string ``
  for values the model does not know (Smithy enums are open; the caller decides whether that is an
  error). Error shapes are skipped: every operation fails with `Aws_json_error.t`.
- A constructor per record, `let get_item_input ~table_name ~key ?consistent_read ... ()`, with
  optional members as optional arguments.
- One module per operation with `request`, `response` and `perform`, built by
  `runtime/aws_json_transport.ml`. No pagination, retries, or documentation.

`runtime/` (transport: endpoint, sigv4 signing, status mapping; error body; wire types) is not a
package. Each generated package copies it in with `(copy_files# ../smithy/runtime/aws_json_*.ml)`,
and the generated module exposes it as `Aws_api_<svc>.Transport` / `Error` / `Wire`. Hand-written
layers go in their own package (`aws-api-dynamodb-client`) that depends on the generated one.

Supported protocols: `aws.protocols#awsJson1_0`, `aws.protocols#awsJson1_1`. REST-XML (S3) and
REST-JSON are out of scope.

[smithy]: https://smithy.io/
[models]: https://github.com/aws/api-models-aws
