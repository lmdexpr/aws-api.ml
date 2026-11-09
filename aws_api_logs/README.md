# aws-api-logs

OCaml client for [Amazon CloudWatch Logs][api], generated from the Smithy model by
[`smithy/smithy_gen.exe`](../smithy). Every operation is a module
`Aws_api_logs.<Operation>` with `request`, `response` and `perform`; records follow the model
(`logGroupName` becomes `log_group_name`, optional members are `option`). `perform` signs with
[sigv4](../sigv4) and performs `Aws_api.Http.call`, so the only handler needed is the transport's.

```ocaml
let () =
  Eio_main.run @@ fun env ->
  let client = Cohttp_eio.Client.make ~https:(Some tls) env#net in
  Aws_api_cohttp_eio.run ~client @@ fun () ->
  let logs = Aws_api_logs.make ~region:"ap-northeast-1" ~now:(fun () -> Eio.Time.now env#clock) () in
  let now_ms = int_of_float (Eio.Time.now env#clock *. 1000.) in
  match
    Aws_api_logs.Put_log_events.perform logs
      (Aws_api_logs.put_log_events_request ~log_group_name:"/app" ~log_stream_name:"web-1"
         ~log_events:[ Aws_api_logs.input_log_event ~timestamp:now_ms ~message:"started" ]
         ())
  with
  | Ok { rejected_log_events_info = None; _ } -> ()
  | Ok _ -> prerr_endline "some events were rejected"
  | Error e -> prerr_endline (Aws_api_logs.Error.to_string e)
```

- Timestamps in this API (`timestamp`, `startTime`, `ingestionTime`, ...) are milliseconds since
  the epoch as `int`, as the model declares them `Long`.
- `GetLogObject` and `StartLiveTail` are not generated: their responses are event streams, which
  the transport (one request, one whole body) cannot read. `FilterLogEvents` / `GetLogEvents`
  with `nextToken` poll instead.
- `make` takes `?endpoint` (default `https://logs.<region>.amazonaws.com/`) and `?provider`
  (default `Sigv4.Provider.default`: env, profile, ECS, IMDS, fetched through the same HTTP
  effect). The provider caches credentials, so build the value once.
- Every `perform` returns `(response, Error.t) result`: 4xx carries the parsed `__type` /
  `message`; any other non-2xx status is `Error.http_status`; a 2xx body the types cannot read is
  `Error.deserialization`.
- `make` raises `Invalid_argument` if `region` is not `[a-z0-9-]+`, since it becomes part of the
  host name. `?endpoint` is taken as given, including its scheme.
- Enums are polymorphic variants with `` `Unknown_value of string `` for values newer than the
  model; see [`smithy/`](../smithy) for what is and is not generated.

[api]: https://docs.aws.amazon.com/AmazonCloudWatchLogs/latest/APIReference/Welcome.html
