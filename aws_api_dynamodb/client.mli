(** Table-bound wrappers over {!Action}. *)

type t

val make : Aws_json_transport.t -> table:string -> t
(** The transport comes from [Aws_api_dynamodb.make] (or [local]). *)

val table : t -> string

val put :
  ?condition_expression:string ->
  ?expression_attribute_names:(string * string) list ->
  ?expression_attribute_values:Item.t ->
  t ->
  item:Item.t ->
  (unit, Error.t) result

val put_if_not_exists : t -> item:Item.t -> primary_key:string -> (unit, Error.t) result
(** Condition [attribute_not_exists(#pk)] with [#pk] bound to [primary_key]. *)

val compare_and_swap :
  t -> item:Item.t -> attribute:string -> expected:Value.t -> (unit, Error.t) result
(** Condition [#attr = :expected]. *)

val delete :
  ?condition_expression:string ->
  ?expression_attribute_names:(string * string) list ->
  ?expression_attribute_values:Item.t ->
  t ->
  key:Item.t ->
  (unit, Error.t) result

val compare_and_delete :
  t -> key:Item.t -> attribute:string -> expected:Value.t -> (unit, Error.t) result
(** Condition [#attr = :expected]. *)

val update :
  t ->
  key:Item.t ->
  update_expression:string ->
  expression_attribute_values:Item.t ->
  (Item.t option, Error.t) result
(** Returns the [ALL_NEW] attributes. *)

val get : t -> key:Item.t -> (Item.t option, Error.t) result

val query :
  ?filter_expression:string ->
  ?expression_attribute_names:(string * string) list ->
  ?limit:int ->
  ?max_pages:int ->
  ?scan_index_forward:bool ->
  t ->
  key_condition_expression:string ->
  expression_attribute_values:Item.t ->
  (Item.t list, Error.t) result
(** All pages when [limit] is absent, up to [max_pages] (unbounded by default): one more page than
    that yields [Error.too_many_pages], so [max_pages = 0] fails before any request. With [limit],
    returns only the first page; [limit] caps evaluated items per page, before filtering. Every page
    is held in memory. *)

val scan : ?max_pages:int -> t -> (Item.t list, Error.t) result
(** All pages, up to [max_pages] as in {!query}. *)
