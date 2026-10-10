(** Items for [TransactWriteItems] and the call itself. [Update] and [ConditionCheck] items can be
    built with [Aws_api_dynamodb.transact_write_item] directly. *)

type item = Aws_api_dynamodb.transact_write_item

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

val write : Aws_api_dynamodb.t -> item list -> (unit, Error.t) result
(** The first argument is [Aws_api_dynamodb.t]. *)
