(** [Scan], one page. Continue with [exclusive_start_key = last_evaluated_key]. *)

type request

val make : ?exclusive_start_key:Item.t -> table_name:string -> unit -> request

type response = { items : Item.t list; last_evaluated_key : Item.t option }

include Intf.S with type request := request and type response := response
