open Result.Syntax

type t = { api : Aws_json_transport.t; table : string }

let make api ~table = { api; table }
let table { table; _ } = table

let put ?condition_expression ?expression_attribute_names ?expression_attribute_values
  { api; table } ~item =
  Action.Put_item.make ?condition_expression ?expression_attribute_names
    ?expression_attribute_values ~table_name:table ~item ()
  |> Action.Put_item.perform api

let put_if_not_exists t ~item ~primary_key =
  put t ~item ~condition_expression:"attribute_not_exists(#pk)"
    ~expression_attribute_names:[ "#pk", primary_key ]

let compare_and_swap t ~item ~attribute ~expected =
  put t ~item ~condition_expression:"#attr = :expected"
    ~expression_attribute_names:[ "#attr", attribute ]
    ~expression_attribute_values:(Item.singleton ":expected" expected)

let delete ?condition_expression ?expression_attribute_names ?expression_attribute_values
  { api; table } ~key =
  Action.Delete_item.make ?condition_expression ?expression_attribute_names
    ?expression_attribute_values ~table_name:table ~key ()
  |> Action.Delete_item.perform api

let compare_and_delete t ~key ~attribute ~expected =
  delete t ~key ~condition_expression:"#attr = :expected"
    ~expression_attribute_names:[ "#attr", attribute ]
    ~expression_attribute_values:(Item.singleton ":expected" expected)

let update { api; table } ~key ~update_expression ~expression_attribute_values =
  let* Action.Update_item.{ attributes } =
    Action.Update_item.make ~table_name:table ~key ~update_expression ~expression_attribute_values
    |> Action.Update_item.perform api
  in
  Ok attributes

let get { api; table } ~key =
  let* Action.Get_item.{ item } =
    Action.Get_item.make ~table_name:table ~key |> Action.Get_item.perform api
  in
  Ok item

(* Follows [LastEvaluatedKey] until the table is exhausted or [max_pages] pages have been read. *)
let all_pages ?max_pages fetch =
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
    let* Action.Query.{ items; last_evaluated_key } =
      Action.Query.make ?filter_expression ?expression_attribute_names ?limit ?scan_index_forward
        ?exclusive_start_key ~table_name:table ~key_condition_expression
        ~expression_attribute_values ()
      |> Action.Query.perform api
    in
    Ok (items, last_evaluated_key)
  in
  match limit with Some _ -> Result.map fst (page None) | None -> all_pages ?max_pages page

let scan ?max_pages { api; table } =
  all_pages ?max_pages @@ fun exclusive_start_key ->
  let* Action.Scan.{ items; last_evaluated_key } =
    Action.Scan.make ?exclusive_start_key ~table_name:table () |> Action.Scan.perform api
  in
  Ok (items, last_evaluated_key)
