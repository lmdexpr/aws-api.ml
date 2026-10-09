(** Items for [TransactWriteItems] and the call itself; see {!Action.Transact_write_items}. *)

type item = Action.Transact_write_items.item =
  | Put of Action.Put_item.request
  | Delete of Action.Delete_item.request

val put :
  ?condition_expression:string ->
  ?expression_attribute_names:(string * string) list ->
  ?expression_attribute_values:Item.t ->
  table_name:string ->
  item:Item.t ->
  unit ->
  item

val put_if_not_exists : table_name:string -> item:Item.t -> primary_key:string -> item
(** Condition [attribute_not_exists(#pk)] with [#pk] bound to [primary_key]. *)

val delete :
  ?condition_expression:string ->
  ?expression_attribute_names:(string * string) list ->
  ?expression_attribute_values:Item.t ->
  table_name:string ->
  key:Item.t ->
  unit ->
  item

val write : item list -> (unit, Error.t) result
