(** [GetItem] *)

type request

val make : table_name:string -> key:Item.t -> request

type response = { item : Item.t option }

include Intf.S with type request := request and type response := response
