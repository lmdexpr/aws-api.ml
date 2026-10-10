# aws-api-dynamodb

OCaml client for the [Amazon DynamoDB HTTP API][api] (JSON 1.0 protocol).

Request encoding, response decoding, error parsing. Items carry every DynamoDB attribute type; numbers are exact decimals.
`Aws_api_dynamodb.make ~region ~now ()` builds the transport value; every operation takes it, signs with [sigv4](../sigv4) and performs `Aws_api.Http.call`.

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
  Aws_api_cohttp_eio.run ~client @@ fun () ->
  let api = Aws_api_dynamodb.local ~now () in
  let db = Aws_api_dynamodb.Client.make api ~table:"users" in
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

- `local ~now ()` targets `http://127.0.0.1:8000` with static credentials; `make ~region ~now ()` targets the regional endpoint over HTTPS, which needs an `~https` TLS wrapper on the cohttp-eio client. `make` rejects a `region` outside `[a-z0-9-]`.
- Credentials come from `Sigv4.Provider.default` (env, `~/.aws` profile, ECS container endpoint, EC2 IMDS; see [sigv4](../sigv4)), with its HTTP fetches going through the same `Aws_api.Http` handler. Pass `~provider` to `make` to use another chain, e.g. `Sigv4.Provider.Static` in tests. The provider holds the credential cache, so build the value once, not once per request.
- `query` without `limit` and `scan` read every page into memory; cap them with `?max_pages`, which yields `Error.too_many_pages` when exceeded.
- Authentication errors (`AccessDeniedException`, `ExpiredTokenException`, ...) carry their text in `Message`; `Error.message` reads both spellings.
- Every `Client` function returns `(_, Aws_api_dynamodb.Error.t) result`: a parsed 4xx, `Error.http_status` for any other non-2xx status, or `Error.deserialization` for a 2xx body the types cannot read. `Error.is_conditional_check_failed` recognizes failed conditions, including cancelled transactions.
- Expressions (`condition_expression`, `key_condition_expression`, ...) are raw strings. Pass values through `expression_attribute_values`, never by string concatenation.
- `Aws_api_dynamodb.Action.<Name>.(make ... |> perform api)` is the layer under `Client`.
  `Aws_api_dynamodb.Transaction.write api` takes items built with `Transaction.put` / `Transaction.delete`.

In tests, handle `Aws_api.Http.Call` yourself and pass a `Sigv4.Provider.Static` to `make`; the
action name is in the `X-Amz-Target` header and the JSON body in `request.body`.

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
