# sigv4

An OCaml implementation of [AWS Signature Version 4][sigv4-spec] (header-based signing).

The library is I/O-agnostic: it performs no HTTP requests, no credential fetching, and no clock reads.
The caller injects time, credentials, and the request to be signed.

[sigv4-spec]: https://docs.aws.amazon.com/general/latest/gr/sigv4_signing.html

## Status

Conforms to the [AWS SigV4 v4 test suite][awssuite] (header signing). All 38 fixtures pass.

[awssuite]: https://github.com/awslabs/aws-c-auth/tree/main/tests/aws-signing-test-suite/v4

## Usage

```ocaml
let signed =
  (* Install a credentials provider for the dynamic extent of the continuation.
     [Provider.Static] is the simplest one; see "Credentials" below for the environment-variable,
     ECS and chain providers. *)
  Sigv4.with_provider
    (Sigv4.Provider.Static.make
       ~access_key:"AKIDEXAMPLE"
       ~secret_key:"wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
       ())
  @@ fun () ->
  let credentials = Sigv4.Credentials.fetch () in
  Sigv4.sign
    ~now:Unix.time (* [now : unit -> float]; pass any UTC-epoch thunk *)
    ~credentials
    ~region:"us-east-1"
    ~service:"dynamodb"
    ~http_method:"POST"
    ~payload:body
    ~uri:(Uri.of_string "https://dynamodb.us-east-1.amazonaws.com/")
    [ "Host", "dynamodb.us-east-1.amazonaws.com";
      "Content-Type", "application/x-amz-json-1.0";
      "X-Amz-Target", "DynamoDB_20120810.PutItem" ]

(* [signed] is the list of headers to ADD to the request:
   - "Authorization": "AWS4-HMAC-SHA256 Credential=... Signature=..."
   - "X-Amz-Date": "20260101T000000Z"
   - "X-Amz-Security-Token": ... (only when session_token is present)
   - "X-Amz-Content-Sha256": ... (only when ~signed_body_header:true) *)
```

Runnable version: [`examples/sigv4_sign.ml`](../examples/sigv4_sign.ml).

## Credentials

Credentials are resolved through a small **provider** abstraction.
A `Sigv4.Provider.t` either yields credentials or *declines* with a reason; `Sigv4.Provider.chain` tries providers left to right and the first that resolves wins.
`Sigv4.with_provider` installs a provider for the dynamic extent of a continuation, where `Sigv4.Credentials.fetch ()` produces the resolved (abstract) credentials.
If every provider in the chain declines, `Sigv4.No_credentials` is raised at the `fetch` site, with each provider's decline reason aggregated in the message.

| Provider | Notes |
|---|---|
| `Sigv4.Provider.Static.make ~access_key ~secret_key ?session_token ()` | Fixed credentials; ideal for tests and local development. |
| `Sigv4.Provider.Env.make ?getenv ()` | Reads `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` (+ optional `AWS_SESSION_TOKEN`). |
| `Sigv4.Provider.Profile.make ?getenv ~read_file ()` | Static keys from `~/.aws/credentials` then `~/.aws/config` for `AWS_PROFILE` (default `default`). `role_arn`, `sso_*` and `credential_process` are not followed. |
| `Sigv4.Provider.Ecs.make ?getenv ?read_file ~now ~http ()` | AWS container credentials endpoint (ECS / Fargate / EKS Pod Identity). `AWS_CONTAINER_CREDENTIALS_FULL_URI` must be `https`, or `http` to loopback / `169.254.170.2` / `169.254.170.23` / `fd00:ec2::23`, as in the AWS SDKs. Sends the `AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE` contents (or else `AWS_CONTAINER_AUTHORIZATION_TOKEN`) as `Authorization`. |
| `Sigv4.Provider.Imds.make ?getenv ~now ~http ()` | EC2 instance metadata (IMDSv2). Declines when `AWS_EC2_METADATA_DISABLED=true` or unreachable. |
| `Sigv4.Provider.default ?getenv ?read_file ~now ~http ()` | The chain above in SDK order: env, profile, ECS, IMDS. |

The library performs no I/O itself: `?getenv` defaults to `Sys.getenv_opt`, `?read_file` to the file system, and `~http : Provider.Http.request -> Provider.Http.response` is yours to supply (a transport exception becomes a decline).
`Aws_api_dynamodb.Http.run` builds the default chain with `~http` backed by `Aws_api.Http.call`; with your own HTTP client, supply it directly:

```ocaml
let http ({ meth; url; headers } : Sigv4.Provider.Http.request) : Sigv4.Provider.Http.response =
  let status, body = my_http_client ~meth ~headers url in
  { status; body }

let provider = Sigv4.Provider.default ~now ~http () in
Sigv4.with_provider provider @@ fun () ->
  let credentials = Sigv4.Credentials.fetch () in
  Sigv4.sign ~now ~credentials (* ... *)
```

Build providers once and reuse them: the ECS and IMDS caches live in the provider value.
Fetched credentials are reused until 5 minutes before their `Expiration` (15 minutes when none is reported); if a refresh fails, the previous credentials are served until they actually expire.
A fetch that fails, redirects, or returns a malformed document is a decline, never an exception, and decline reasons never contain the document or the URL's query string.
A custom chain is just `Sigv4.Provider.chain [ ... ]`:

```ocaml
(* env first, then explicit static credentials as a fallback *)
let provider =
  Sigv4.Provider.chain
    [ Sigv4.Provider.Env.make ();
      Sigv4.Provider.Static.make ~access_key:"AKIDEXAMPLE" ~secret_key:"..." () ]
```

Not in the chain yet: web identity (STS, used by EKS IRSA), SSO and `credential_process`.

### Service-specific knobs

```ocaml
(* S3 needs the body-hash header to be signed and disables path normalization. *)
Sigv4.sign
  ~signed_body_header:true
  ~normalize_path:false
  ...
```

| Option | Default | When to enable |
|---|---|---|
| `?signed_body_header:bool` | `false` | S3 (required), Glacier |
| `?normalize_path:bool` | `true` | Set to `false` for S3 |
| `?omit_session_token:bool` | `false` | Some STS-like flows where the token is sent but not signed |
| `?payload:string` | `""` | Request body bytes (used to compute the SHA256) |

## What's not (yet) supported

This library covers header-based SigV4 signing for the common cases (DynamoDB, Lambda, API Gateway, EC2, SQS, SNS, ...).
The following are intentionally out of scope for now:

- **`UNSIGNED-PAYLOAD` and `STREAMING-AWS4-HMAC-SHA256-PAYLOAD`**.
  S3 streaming uploads and large file uploads where the body hash is computed separately or omitted from the signature. Today `?payload` only accepts the raw body bytes; the literal payload-hash modes will be added later as a variant.
- **Pre-signed URL (query-string signing)**.
  Generating `?X-Amz-Algorithm=...&X-Amz-Signature=...` URLs (typically used for S3 GET/PUT URLs shared with browsers). A separate `Sigv4.presign` entry point will be added when there's demand.
- **SigV4a (asymmetric / multi-region)**.
  Used by S3 Multi-Region Access Points and a few other newer services.

## Dependencies

Runtime: [`uri`](https://github.com/mirage/ocaml-uri), [`digestif`](https://github.com/mirage/digestif),
[`yojson`](https://github.com/ocaml-community/yojson) (for the ECS and IMDS credential documents).
Test-only: `alcotest`.

The library uses no `Unix`, `Str`, or other platform-specific modules, so it works on bytecode, native, MirageOS, and js_of_ocaml targets.
`sign` is pure. The only ambient process state read by default is the environment (`Sys.getenv_opt`) and, for `Provider.default`, the profile files; both are injectable (`?getenv`, `?read_file`), and HTTP is always injected (`~http`).

## Testing

The test suite uses fixtures vendored from [awslabs/aws-c-auth][aws-c-auth] (Apache-2.0) via a git submodule. To run:

```sh
git submodule update --init sigv4/aws-c-auth
dune runtest
```

If the submodule is not initialized, the test runner prints a notice and exits 0 (so `opam install --with-test` works in environments without the fixtures).

[aws-c-auth]: https://github.com/awslabs/aws-c-auth

## Acknowledgements

The AWS SigV4 test-suite fixtures under `sigv4/aws-c-auth/` are sourced from [`awslabs/aws-c-auth`](https://github.com/awslabs/aws-c-auth),
licensed under the Apache License 2.0. See that repository for the original attribution and license text.
