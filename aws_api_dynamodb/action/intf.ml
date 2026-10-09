(** Shape of every action module. *)

module type S = sig
  val action : string

  type request
  type response

  val yojson_of_request : request -> Yojson.Safe.t
  val response_of_yojson : Yojson.Safe.t -> response
  val perform : request -> (response, Error.t) result
end
