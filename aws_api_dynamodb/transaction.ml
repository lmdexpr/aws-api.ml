type item = Action.Transact_write_items.item =
  | Put of Action.Put_item.request
  | Delete of Action.Delete_item.request

let put ?condition_expression ?expression_attribute_names ?expression_attribute_values ~table_name
  ~item () =
  Put
    (Action.Put_item.make ?condition_expression ?expression_attribute_names
       ?expression_attribute_values ~table_name ~item ())

let put_if_not_exists ~table_name ~item ~primary_key =
  put ~table_name ~item ~condition_expression:"attribute_not_exists(#pk)"
    ~expression_attribute_names:[ "#pk", primary_key ]
    ()

let delete ?condition_expression ?expression_attribute_names ?expression_attribute_values
  ~table_name ~key () =
  Delete
    (Action.Delete_item.make ?condition_expression ?expression_attribute_names
       ?expression_attribute_values ~table_name ~key ())

let write items = Action.Transact_write_items.(make items |> perform)
