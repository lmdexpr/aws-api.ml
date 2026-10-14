# aws-api-kms

OCaml client for [AWS Key Management Service][api], generated from the Smithy model by
[`smithy/smithy_gen.exe`](../smithy). Every operation is a module
`Aws_api_kms.<Operation>` with `request`, `response` and `perform`; records follow the model
(`KeyId` becomes `key_id`, optional members are `option`). `perform` signs with [sigv4](../sigv4)
and performs `Aws_api.Http.call`, so the only handler needed is the transport's.

```ocaml
let () =
  Eio_main.run @@ fun env ->
  let client = Cohttp_eio.Client.make ~https:(Some tls) env#net in
  Aws_api_cohttp_eio.run ~client @@ fun () ->
  let kms = Aws_api_kms.make ~region:"ap-northeast-1" ~now:(fun () -> Eio.Time.now env#clock) () in
  let encrypted =
    Aws_api_kms.Encrypt.perform kms
      (Aws_api_kms.encrypt_request ~key_id:"alias/app" ~plaintext:"s3cret"
         ~encryption_context:[ "tenant", "t1" ] ())
  in
  match encrypted with
  | Ok { ciphertext_blob = Some blob; _ } -> (
    match
      Aws_api_kms.Decrypt.perform kms
        (Aws_api_kms.decrypt_request ~ciphertext_blob:blob ~encryption_context:[ "tenant", "t1" ] ())
    with
    | Ok { plaintext = Some p; _ } -> print_endline p
    | Ok _ -> print_endline "no plaintext"
    | Error e -> prerr_endline (Aws_api_kms.Error.to_string e))
  | Ok _ -> print_endline "no ciphertext"
  | Error e -> prerr_endline (Aws_api_kms.Error.to_string e)
```

- Blobs (`Plaintext`, `CiphertextBlob`, `PublicKey`, `Signature`, ...) are raw bytes as
  `string`; base64 on the wire is handled by the generated code.
- `make` takes `?endpoint` (default `https://kms.<region>.amazonaws.com/`) and `?provider`
  (default `Sigv4.Provider.default`: env, profile, ECS, IMDS, fetched through the same HTTP
  effect). The provider caches credentials, so build the value once.
- Every `perform` returns `(response, Error.t) result`: 4xx carries the parsed `__type` /
  `message`; any other non-2xx status is `Error.http_status`; a 2xx body the types cannot read is
  `Error.deserialization`, with the body dropped since `Decrypt` and `GenerateDataKey` responses
  carry plaintext.
- `make` raises `Invalid_argument` if `region` is not `[a-z0-9-]+`, since it becomes part of the
  host name. `?endpoint` is taken as given, including its scheme.
- Enums are polymorphic variants with `` `Unknown_value of string `` for values newer than the
  model; see [`smithy/`](../smithy) for what is and is not generated.

[api]: https://docs.aws.amazon.com/kms/latest/APIReference/Welcome.html
