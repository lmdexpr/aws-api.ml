(** The effect: send a request, get a response. Handled by the adapter. *)

type _ Effect.t += Call : Request.t -> Response.t Effect.t

val call : Request.t -> Response.t
