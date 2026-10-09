(** HTTP response from the Runtime API. *)

type t = { status : int; headers : (string * string) list; body : string }

val header : string -> t -> string option
(** Case-insensitive lookup. *)
