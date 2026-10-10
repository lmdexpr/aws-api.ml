type t = { api : Aws_api_dynamodb.t; table : string }

let make api ~table = { api; table }
let table { table; _ } = table
let unit r = Result.map ignore r
let values = Option.map Envelope.of_item

let put ?condition_expression ?expression_attribute_names ?expression_attribute_values
  { api; table } ~item =
  Aws_api_dynamodb.put_item_input ~table_name:table ~item:(Envelope.of_item item)
    ?condition_expression ?expression_attribute_names
    ?expression_attribute_values:(values expression_attribute_values)
    ()
  |> Aws_api_dynamodb.Put_item.perform api
  |> unit

let put_if_not_exists t ~item ~primary_key =
  put t ~item ~condition_expression:"attribute_not_exists(#pk)"
    ~expression_attribute_names:[ "#pk", primary_key ]

let compare_and_swap t ~item ~attribute ~expected =
  put t ~item ~condition_expression:"#attr = :expected"
    ~expression_attribute_names:[ "#attr", attribute ]
    ~expression_attribute_values:(Item.singleton ":expected" expected)

let delete ?condition_expression ?expression_attribute_names ?expression_attribute_values
  { api; table } ~key =
  Aws_api_dynamodb.delete_item_input ~table_name:table ~key:(Envelope.of_item key)
    ?condition_expression ?expression_attribute_names
    ?expression_attribute_values:(values expression_attribute_values)
    ()
  |> Aws_api_dynamodb.Delete_item.perform api
  |> unit

let update { api; table } ~key ~update_expression ~expression_attribute_values =
  Aws_api_dynamodb.update_item_input ~table_name:table ~key:(Envelope.of_item key)
    ~update_expression
    ~expression_attribute_values:(Envelope.of_item expression_attribute_values)
    ~return_values:`ALL_NEW ()
  |> Aws_api_dynamodb.Update_item.perform api
  |> Result.map (fun (o : Aws_api_dynamodb.update_item_output) ->
    Option.map Envelope.to_item o.attributes)

let get { api; table } ~key =
  Aws_api_dynamodb.get_item_input ~table_name:table ~key:(Envelope.of_item key) ()
  |> Aws_api_dynamodb.Get_item.perform api
  |> Result.map (fun (o : Aws_api_dynamodb.get_item_output) -> Option.map Envelope.to_item o.item)

(* Follows [LastEvaluatedKey] until the table is exhausted or [max_pages] pages have been read. *)
let all_pages ?max_pages fetch =
  let open Result.Syntax in
  let rec go acc pages exclusive_start_key =
    match max_pages with
    | Some max when pages >= max -> Error (Error.too_many_pages ~max_pages:max)
    | _ -> (
      let* items, last_evaluated_key = fetch exclusive_start_key in
      let acc = List.rev_append items acc in
      match last_evaluated_key with
      | None -> Ok (List.rev acc)
      | Some key -> go acc (pages + 1) (Some key))
  in
  go [] 0 None

let query ?filter_expression ?expression_attribute_names ?limit ?max_pages ?scan_index_forward
  { api; table } ~key_condition_expression ~expression_attribute_values =
  let page exclusive_start_key =
    Aws_api_dynamodb.query_input ~table_name:table ~key_condition_expression
      ~expression_attribute_values:(Envelope.of_item expression_attribute_values)
      ?filter_expression ?expression_attribute_names ?limit ?scan_index_forward
      ?exclusive_start_key:(values exclusive_start_key) ()
    |> Aws_api_dynamodb.Query.perform api
    |> Result.map (fun (o : Aws_api_dynamodb.query_output) ->
      Envelope.items o.items, Option.map Envelope.to_item o.last_evaluated_key)
  in
  match limit with Some _ -> Result.map fst (page None) | None -> all_pages ?max_pages page

let scan ?max_pages { api; table } =
  all_pages ?max_pages @@ fun exclusive_start_key ->
  Aws_api_dynamodb.scan_input ~table_name:table ?exclusive_start_key:(values exclusive_start_key) ()
  |> Aws_api_dynamodb.Scan.perform api
  |> Result.map (fun (o : Aws_api_dynamodb.scan_output) ->
    Envelope.items o.items, Option.map Envelope.to_item o.last_evaluated_key)
