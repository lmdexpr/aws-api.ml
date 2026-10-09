# aws-api-lambda

OCaml library for AWS Lambda custom runtimes: the [Runtime API][runtime-api] (2018-06-01) loop.

HTTP is an OCaml 5 effect (`Aws_api_lambda.Transport.Call`); the library depends on [aws-api](../aws_api), `uri` and `unix` only.
`Aws_api_lambda.Http` performs the effect through `Aws_api.Http.call`, so any `Aws_api` handler (e.g. `Aws_api_cohttp_eio.run`) serves as the transport.

[runtime-api]: https://docs.aws.amazon.com/lambda/latest/dg/runtimes-api.html

## Usage

```ocaml
let () =
  Eio_main.run @@ fun env ->
  let client = Cohttp_eio.Client.make ~https:None env#net in
  let endpoint = Option.get (Aws_api_lambda.Http.endpoint_from_env ()) in
  let fatal =
    Aws_api_cohttp_eio.run ~client @@ fun () ->
    Aws_api_lambda.Http.run ~propagate:Aws_api_cohttp_eio.is_cancelled ~endpoint @@ fun invocation ->
    Ok (Printf.sprintf {|{"echo":%s}|} invocation.payload)
  in
  prerr_endline (Aws_api_lambda.fatal_to_string fatal);
  exit 1
```

Runnable version: [`examples/lambda_echo.ml`](../examples/lambda_echo.ml).

A handler returns `Ok payload` or `Error (Aws_api_lambda.Error.v ~error_type msg)`; exceptions are reported as errors.
`~propagate` names the handler exceptions that must unwind the loop instead: under eio, pass `Aws_api_cohttp_eio.is_cancelled` so fiber cancellation is not posted as a function error.
`run` returns a `fatal` when the Runtime API says the loop cannot continue; when the Runtime API cannot be reached at all (connection refused, cancellation during a call) it raises.
`Aws_api_lambda.Http.run` sets `_X_AMZN_TRACE_ID` before each invocation.
`Aws_api_lambda.Context.of_env Sys.getenv_opt` reads the function configuration; `Aws_api_lambda.report_init_error` reports start-up failures.

With another HTTP client, handle the effect yourself:

```ocaml
try Aws_api_lambda.run handler
with effect Aws_api_lambda.Transport.Call request, k ->
  Effect.Deep.continue k (send request)
```

Ship the binary as `bootstrap` (zip, `provided.al2023`) or as a container image.
