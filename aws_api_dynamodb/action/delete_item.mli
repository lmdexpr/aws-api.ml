(** [DeleteItem] *)

type request

val make :
  ?condition_expression:string ->
  ?expression_attribute_names:(string * string) list ->
  ?expression_attribute_values:Item.t ->
  table_name:string ->
  key:Item.t ->
  unit ->
  request

include Intf.S with type request := request and type response := unit
