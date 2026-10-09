# aws-api-dynamodb

OCaml client for the [Amazon DynamoDB HTTP API][api] (JSON 1.0 protocol).

Request encoding, response decoding, error parsing. Items carry every DynamoDB attribute type; numbers are exact decimals.
Each operation performs the effect `Aws_api_dynamodb.Effects.Call`; `Aws_api_dynamodb.Http.run` handles it by signing with [sigv4](../sigv4) and performing `Aws_api.Http.call`.

Supported: `PutItem`, `GetItem`, `DeleteItem`, `UpdateItem` (`ReturnValues = ALL_NEW`), `Query` (all pages without `limit`, one page with `limit`), `Scan` (all pages), `TransactWriteItems` (`Put` / `Delete`).
Not supported: `BatchGetItem`, `BatchWriteItem`, `IndexName`, `ConsistentRead`, `ProjectionExpression`, other `ReturnValues`, and `Update` / `ConditionCheck` transact items.

[api]: https://docs.aws.amazon.com/amazondynamodb/latest/APIReference/Welcome.html

## Usage

```ocaml
open Ppx_yojson_conv_lib.Yojson_conv.Primitives

type user = { pk : string; name : string } [@@deriving yojson]

let () =
  Eio_main.run @@ fun env ->
  let client = Cohttp_eio.Client.make ~https:None env#net in
  let now () = Eio.Time.now env#clock in
  let config = Aws_api_dynamodb.Config.local () in
  Aws_api_cohttp_eio.run ~client @@ fun () ->
  Aws_api_dynamodb.Http.run ~now ~config @@ fun () ->
  let db = Aws_api_dynamodb.Client.make ~table:"users" in
  let item = yojson_of_user { pk = "alice"; name = "Alice" } |> Aws_api_dynamodb.Projection.item_of_yojson_exn in
  match Aws_api_dynamodb.Client.put db ~item with
  | Error e -> prerr_endline (Aws_api_dynamodb.Error.to_string e)
  | Ok () -> (
    match Aws_api_dynamodb.Client.get db ~key:(Aws_api_dynamodb.Item.singleton "pk" (Aws_api_dynamodb.Value.String "alice")) with
    | Ok (Some item) -> print_endline (Aws_api_dynamodb.Projection.yojson_of_item_exn item |> user_of_yojson).name
    | Ok None -> print_endline "not found"
    | Error e -> prerr_endline (Aws_api_dynamodb.Error.to_string e))
```

Runnable version against DynamoDB Local: [`examples/dynamodb_crud.ml`](../examples/dynamodb_crud.ml).

- `Config.local ()` targets `http://127.0.0.1:8000`; `Config.aws ~region` targets the regional endpoint over HTTPS, which needs an `~https` TLS wrapper on the cohttp-eio client.
- Credentials come from `Sigv4.Provider.default` (env, `~/.aws` profile, ECS container endpoint, EC2 IMDS; see [sigv4](../sigv4)), with its HTTP fetches going through the same `Aws_api.Http` handler. Pass `~provider` to `Aws_api_dynamodb.Http.run` to use another chain, e.g. `Sigv4.Provider.Static` in tests. The provider holds the credential cache, so call `Http.run` once around the program (or build `Http.default_provider ~now ()` once and pass it), not once per request.
- `query` without `limit` and `scan` read every page into memory; cap them with `?max_pages`, which yields `Error.too_many_pages` when exceeded.
- Authentication errors (`AccessDeniedException`, `ExpiredTokenException`, ...) carry their text in `Message`; `Error.message` reads both spellings.
- Every `Client` function returns `(_, Aws_api_dynamodb.Error.t) result`. `Error.is_conditional_check_failed` recognizes failed conditions, including cancelled transactions.
- Expressions (`condition_expression`, `key_condition_expression`, ...) are raw strings. Pass values through `expression_attribute_values`, never by string concatenation.
- `Aws_api_dynamodb.Action.<Name>.(make ... |> perform)` is the layer under `Client`.
  `Aws_api_dynamodb.Transaction.write` takes items built with `Transaction.put` / `Transaction.delete`.

Handling the effect yourself, e.g. in tests:

```ocaml
let with_stub ~respond k =
  try k ()
  with effect Aws_api_dynamodb.Effects.Call { action; body }, k ->
    Effect.Deep.continue k (respond ~action ~body)
```

`respond` returns `Ok json` for a 2xx body or `Error body` for a 4xx body.

## Values and JSON

`Item.t` maps names to `Value.t`: `String`, `Number`, `Binary` (raw bytes), `Bool`, `Null`, `List`, `Map`, `String_set`, `Number_set`, `Binary_set`. Reading an item and writing it back preserves attribute types and decimal digits.

`Number.t` is an exact decimal: 38 significant digits, adjusted exponent -130 to 125. `Number.of_string`, `of_float` and `to_int` return `result`; `to_float` may round. Set constructors reject empty sets and duplicates (`1` and `1.0` are duplicates).

`Projection` converts to and from ordinary JSON, e.g. for `[@@deriving yojson]` records. `Projection.item_of_yojson` reads objects, arrays, strings and numbers as `Map`, `List`, `String` and `Number`. `Projection.yojson_of_item` takes a policy for each thing JSON cannot represent:

| Option | Default | Alternatives |
| --- | --- | --- |
| `numbers` | `Float`: fractions round to floats, integers stay `Int` / `Intlit` | `Exact`: reject fractions; `String`: decimal strings |
| `sets` | `Reject` | `Lists` |
| `binary` | `Reject` | `Base64` |

Errors carry a path such as `$["events"][0]`; `_exn` variants raise `Projection.Conversion_error`. Malformed wire values in a response raise `Ppx_yojson_conv_lib.Yojson_conv.Of_yojson_error` with the same kind of path.
