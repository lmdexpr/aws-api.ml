(** [Query], one page. Continue with [exclusive_start_key = last_evaluated_key]. [limit] caps
    evaluated items; [scan_index_forward = false] descends. *)

type request

val make :
  ?filter_expression:string ->
  ?expression_attribute_names:(string * string) list ->
  ?limit:int ->
  ?scan_index_forward:bool ->
  ?exclusive_start_key:Item.t ->
  table_name:string ->
  key_condition_expression:string ->
  expression_attribute_values:Item.t ->
  unit ->
  request

type response = { items : Item.t list; last_evaluated_key : Item.t option }

include Intf.S with type request := request and type response := response
