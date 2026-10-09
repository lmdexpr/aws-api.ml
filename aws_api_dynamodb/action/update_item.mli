(** [UpdateItem] with [ReturnValues = ALL_NEW]. *)

type request

val make :
  table_name:string ->
  key:Item.t ->
  update_expression:string ->
  expression_attribute_values:Item.t ->
  request

type response = { attributes : Item.t option }

include Intf.S with type request := request and type response := response
