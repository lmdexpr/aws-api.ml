# aws-api.ml

OCaml libraries for AWS. **Experimental**: the hand-written packages grew out of code that has run
in production, but they have since been reworked here, none of them covers its service's whole
API, and the public API may still change. Every package is I/O-agnostic: HTTP goes through one OCaml 5 effect,
`Aws_api.Http.Call`, and a single adapter handles it with [cohttp-eio][cohttp-eio].

| Package | Contents |
| --- | --- |
| `aws-api` | The HTTP effect, request and response types |
| `aws-api-cohttp-eio` | Handles the effect with cohttp-eio |
| [`sigv4`](sigv4/) | [AWS Signature Version 4][sigv4-spec] header signing and credential providers |
| [`aws-api-dynamodb`](aws_api_dynamodb/) | DynamoDB JSON 1.0 protocol: request encoding, response decoding, errors |
| [`aws-api-lambda`](aws_api_lambda/) | Lambda Runtime API loop for custom runtimes |
| [`aws-api-ssm`](aws_api_ssm/) | Systems Manager, generated from the Smithy model |

`sigv4`, `aws-api-dynamodb` and `aws-api-lambda` are written by hand. [`smithy/`](smithy/)
generates a package per JSON-protocol service from its Smithy model; `aws-api-ssm` is the first.
Its API shape (`make` + `perform`, no service-level effect) is the direction the hand-written
packages will move to.

Only `aws-api-cohttp-eio` depends on eio and cohttp. `sigv4` does not depend on `aws-api`; its
ECS and IMDS credential providers take an HTTP function instead. `aws-api-lambda` does not depend on
`sigv4`.

Each package lives in its own top-level directory with its README and its tests (`*_test.ml`).
Runnable examples are in [`examples/`](examples/); `dune build` compiles them, so they stay in step
with the libraries.

[sigv4-spec]: https://docs.aws.amazon.com/general/latest/gr/sigv4_signing.html
[cohttp-eio]: https://github.com/mirage/ocaml-cohttp

## Install

Not on the opam repository yet.

```sh
opam pin add aws-api https://github.com/lmdexpr/aws-api.ml.git
opam pin add aws-api-cohttp-eio https://github.com/lmdexpr/aws-api.ml.git
opam pin add sigv4 https://github.com/lmdexpr/aws-api.ml.git
opam pin add aws-api-dynamodb https://github.com/lmdexpr/aws-api.ml.git
opam pin add aws-api-lambda https://github.com/lmdexpr/aws-api.ml.git
opam pin add aws-api-ssm https://github.com/lmdexpr/aws-api.ml.git
```

## Usage

The transport handler (`Aws_api_cohttp_eio.run`) wraps your code. Inside it,
`Aws_api_dynamodb.make` / `Aws_api_ssm.make` return a value that each operation signs and sends
with; `Aws_api_lambda.Http.run` is the Runtime API loop. See each package's README.

With another HTTP client, handle `Aws_api.Http.Call` yourself instead of `Aws_api_cohttp_eio.run`:

```ocaml
try k ()
with effect Aws_api.Http.Call request, k -> Effect.Deep.continue k (send request)
```

## Development

```sh
git submodule update --init   # aws-c-auth fixtures for the sigv4 test suite
dune build
dune test
dune build @fmt
```

## License

[MIT](./LICENSE)
