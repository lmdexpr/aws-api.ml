(** Typed DynamoDB attributes. JSON conversion is explicit in {!Projection}. *)

type t

val empty : t
val singleton : string -> Value.t -> t
val add : string -> Value.t -> t -> t
val remove : string -> t -> t
val find_opt : string -> t -> Value.t option
val mem : string -> t -> bool
val is_empty : t -> bool
val equal : t -> t -> bool
val to_list : t -> (string * Value.t) list

val of_list : (string * Value.t) list -> t
(** Duplicate names use the last value, as with [Map.of_list]. *)
