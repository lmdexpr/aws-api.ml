(** [TransactWriteItems] *)

type item = Put of Put_item.request | Delete of Delete_item.request
type request

val make : item list -> request

include Intf.S with type request := request and type response := unit
