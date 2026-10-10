# aws-api-ssm

OCaml client for [AWS Systems Manager][api], generated from the Smithy model by
[`smithy/smithy_gen.exe`](../smithy). Every operation is a module
`Aws_api_ssm.<Operation>` with `request`, `response` and `perform`; records follow the model
(`Name` becomes `name`, optional members are `option`). `perform` signs with [sigv4](../sigv4)
and performs `Aws_api.Http.call`, so the only handler needed is the transport's.

```ocaml
let () =
  Eio_main.run @@ fun env ->
  let client = Cohttp_eio.Client.make ~https:(Some tls) env#net in
  Aws_api_cohttp_eio.run ~client @@ fun () ->
  let ssm = Aws_api_ssm.make ~region:"ap-northeast-1" ~now:(fun () -> Eio.Time.now env#clock) () in
  match Aws_api_ssm.Get_parameter.perform ssm { name = "/app/db"; with_decryption = Some true } with
  | Ok { parameter = Some { value = Some v; _ } } -> print_endline v
  | Ok _ -> print_endline "no value"
  | Error e -> prerr_endline (Aws_api_ssm.Error.to_string e)
```

- `make` takes `?endpoint` (default `https://ssm.<region>.amazonaws.com/`) and `?provider`
  (default `Sigv4.Provider.default`: env, profile, ECS, IMDS, fetched through the same HTTP
  effect). The provider caches credentials, so build the value once.
- Every `perform` returns `(response, Error.t) result`: 4xx carries the parsed `__type` /
  `message`; any other non-2xx status is `Error.http_status`; a 2xx body the types cannot read is
  `Error.deserialization`, with the body dropped since responses may carry secrets.
- `make` raises `Invalid_argument` if `region` is not `[a-z0-9-]+`, since it becomes part of the
  host name. `?endpoint` is taken as given, including its scheme.
- Enums are strings; see [`smithy/`](../smithy) for what is and is not generated.

[api]: https://docs.aws.amazon.com/systems-manager/latest/APIReference/Welcome.html
