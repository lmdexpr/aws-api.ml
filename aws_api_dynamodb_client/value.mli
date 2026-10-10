module String_map : Map.S with type key = string

module String_set : sig
  type t

  val of_list : string list -> (t, string) result
  (** Rejects empty sets and duplicates. *)

  val to_list : t -> string list
end

module Number_set : sig
  type t

  val of_list : Number.t list -> (t, string) result
  (** Rejects empty sets and numerically equal duplicates, e.g. [1] and [1.0]. *)

  val to_list : t -> Number.t list
end

module Binary_set : sig
  type t

  val of_list : string list -> (t, string) result
  val to_list : t -> string list
end

type t =
  | String of string
  | Number of Number.t
  | Binary of string  (** Raw bytes, not base64. *)
  | Bool of bool
  | Null
  | List of t list
  | Map of t String_map.t
  | String_set of String_set.t
  | Number_set of Number_set.t
  | Binary_set of Binary_set.t

val int : int -> t

val float : float -> (t, string) result
(** See {!Number.of_float}. *)

val equal : t -> t -> bool
(** Map and set ordering is insignificant; list ordering is significant. *)
