(** One set of single-table conventions: [pk] / [sk] attributes, [#]-separated key segments, a
    [META] sort key for an entity's own row. Optional; for tables laid out this way. *)

module Pk : sig
  val label : string
end

module Sk : sig
  val label : string
  val meta : string
end

val key : ?sk:string -> string -> Item.t
(** The key item for [pk] and [sk] ([META] by default). *)

module Map : sig
  include Map.S with type key = string

  val ( .?[] ) : 'a t -> string -> 'a option

  val ( .*[] ) : 'a t -> string -> 'a t
  (** Entries whose key starts with the given segment. *)
end

module Pk_row (M : sig
  type t [@@deriving yojson]
  type key

  val key : string
  val get_key : t -> key
  val get_pk : key -> string
end) : sig
  val key : string
  val pk : M.key -> string
  val sk : string
  val to_item : M.t -> Item.t

  val of_item :
    ?numbers:Projection.numbers ->
    ?sets:Projection.sets ->
    ?binary:Projection.binary ->
    Item.t ->
    M.t
  (** Raises [Projection.Conversion_error] or the record decoder's exception. *)
end

module Sk_row (M : sig
  type t [@@deriving yojson]
  type key

  val pk : t -> string
  val key : string
  val get_key : t -> key
  val get_sk : key -> string
end) : sig
  val key : string
  val sk : M.key -> string
  val to_item : M.t -> Item.t

  val of_item :
    ?numbers:Projection.numbers ->
    ?sets:Projection.sets ->
    ?binary:Projection.binary ->
    Item.t ->
    M.t
  (** Raises [Projection.Conversion_error] or the record decoder's exception. *)
end

val put_if_not_exists : Client.t -> item:Item.t -> (unit, Error.t) result
val query : db:Client.t -> string -> (Item.t Map.t, Error.t) result
