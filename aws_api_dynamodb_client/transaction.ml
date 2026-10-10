type item = Aws_api_dynamodb.transact_write_item

let values = Option.map Envelope.of_item

let put ?condition_expression ?expression_attribute_names ?expression_attribute_values ~table_name
  ~item () =
  Aws_api_dynamodb.transact_write_item
    ~put:
      (Aws_api_dynamodb.put ~table_name ~item:(Envelope.of_item item) ?condition_expression
         ?expression_attribute_names
         ?expression_attribute_values:(values expression_attribute_values)
         ())
    ()

let put_if_not_exists ~table_name ~item ~primary_key =
  put ~table_name ~item ~condition_expression:"attribute_not_exists(#pk)"
    ~expression_attribute_names:[ "#pk", primary_key ]
    ()

let delete ?condition_expression ?expression_attribute_names ?expression_attribute_values
  ~table_name ~key () =
  Aws_api_dynamodb.transact_write_item
    ~delete:
      (Aws_api_dynamodb.delete ~table_name ~key:(Envelope.of_item key) ?condition_expression
         ?expression_attribute_names
         ?expression_attribute_values:(values expression_attribute_values)
         ())
    ()

let write api transact_items =
  Aws_api_dynamodb.transact_write_items_input ~transact_items ()
  |> Aws_api_dynamodb.Transact_write_items.perform api
  |> Result.map ignore
