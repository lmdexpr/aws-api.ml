# aws-api-dynamodb

OCaml client for the [Amazon DynamoDB API][api], generated from the Smithy model by
[`smithy/smithy_gen.exe`](../smithy). Every operation is a module `Aws_api_dynamodb.<Operation>`
with `request`, `response` and `perform`; attribute values are the raw envelope
(`Aws_api_dynamodb.attribute_value`, a record with one field per tag).

For typed attribute values, exact decimal numbers, a table client and single-table helpers, see
[aws-api-dynamodb-client](../aws_api_dynamodb_client), which is built on this package.

```ocaml
Aws_api_cohttp_eio.run ~client @@ fun () ->
let api = Aws_api_dynamodb.make ~region:"ap-northeast-1" ~now () in
Aws_api_dynamodb.(Get_item.perform api
  (get_item_input ~table_name:"users" ~key:[ "pk", attribute_value ~s:"alice" () ] ()))
```

See [aws-api-ssm](../aws_api_ssm) for `make`, errors and the shape shared by every generated package.

[api]: https://docs.aws.amazon.com/amazondynamodb/latest/APIReference/Welcome.html
