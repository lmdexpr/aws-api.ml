(** Single-table layout: [pk] / [sk] attributes, [#]-separated segments, [META] sort key. *)

val separator : string
val segment : string -> string -> string
val compose : string list -> string

module Pk : sig
  val label : string
end

module Sk : sig
  val label : string
  val meta : string
end

val ttl : string
val attach_ttl : ttl:int -> Item.t -> Item.t
val attach_key : pk:string -> ?sk:string -> Item.t -> Item.t
val key : ?sk:string -> string -> Item.t

val strip_key : Item.t -> Item.t
(** Removes [pk]/[sk] without projecting or discarding the types of other attributes. *)

module Map : sig
  include Map.S with type key = string

  val ( .?[] ) : 'a t -> string -> 'a option

  val ( .*[] ) : 'a t -> string -> 'a t
  (** Entries whose key starts with the given segment. *)
end

val sk_indexed : Item.t list -> Item.t Map.t

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
val query_sk_prefix : db:Client.t -> string -> string -> (Item.t list, Error.t) result

module Transact : sig
  val put_if_not_exists : table_name:string -> item:Item.t -> Transaction.item
end
