let separator = "#"
let segment label value = label ^ separator ^ value
let compose parts = String.concat separator parts

module Pk = struct
  let label = "pk"
end

module Sk = struct
  let label = "sk"
  let meta = "META"
end

let ttl = "ttl"
let attach_ttl ~ttl:expires_at item = Item.add ttl (Value.int expires_at) item

module Map = struct
  include Map.Make (String)

  let ( .?[] ) m k = find_opt k m
  let ( .*[] ) m prefix = m |> filter (fun k _ -> String.starts_with ~prefix:(prefix ^ separator) k)
end

let attach_key ~pk ?(sk = Sk.meta) item =
  item |> Item.add Pk.label (Value.String pk) |> Item.add Sk.label (Value.String sk)

let key ?sk pk = attach_key ~pk ?sk Item.empty
let strip_key item = item |> Item.remove Pk.label |> Item.remove Sk.label

module Pk_row (M : sig
  type t [@@deriving yojson]
  type key

  val key : string
  val get_key : t -> key
  val get_pk : key -> string
end) =
struct
  let key = M.key
  let pk k = segment M.key @@ M.get_pk k
  let sk = Sk.meta

  let to_item m =
    m |> M.yojson_of_t |> Projection.item_of_yojson_exn |> attach_key ~pk:(m |> M.get_key |> pk)

  let of_item ?numbers ?sets ?binary item =
    item |> strip_key |> Projection.yojson_of_item_exn ?numbers ?sets ?binary |> M.t_of_yojson
end

module Sk_row (M : sig
  type t [@@deriving yojson]
  type key

  val pk : t -> string
  val key : string
  val get_key : t -> key
  val get_sk : key -> string
end) =
struct
  let key = M.key
  let sk k = segment M.key @@ M.get_sk k

  let to_item m =
    m |> M.yojson_of_t |> Projection.item_of_yojson_exn
    |> attach_key ~pk:(m |> M.pk) ~sk:(m |> M.get_key |> sk)

  let of_item ?numbers ?sets ?binary item =
    item |> strip_key |> Projection.yojson_of_item_exn ?numbers ?sets ?binary |> M.t_of_yojson
end

let sk_indexed items =
  items
  |> List.filter_map (fun item ->
    match Item.find_opt Sk.label item with Some (Value.String sk) -> Some (sk, item) | _ -> None)
  |> List.to_seq |> Map.of_seq

let put_if_not_exists = Client.put_if_not_exists ~primary_key:Pk.label

let query ~db pk =
  Client.query db ~key_condition_expression:"#pk = :pk"
    ~expression_attribute_names:[ "#pk", Pk.label ]
    ~expression_attribute_values:(Item.singleton ":pk" @@ Value.String pk)
  |> Result.map sk_indexed

let query_sk_prefix ~db pk sk_prefix =
  Client.query db ~key_condition_expression:"#pk = :pk AND begins_with(#sk, :sk)"
    ~expression_attribute_names:[ "#pk", Pk.label; "#sk", Sk.label ]
    ~expression_attribute_values:
      Item.(
        empty |> add ":pk" (Value.String pk) |> add ":sk" (Value.String (sk_prefix ^ separator)))

module Transact = struct
  let put_if_not_exists ~table_name ~item =
    Transaction.put_if_not_exists ~table_name ~item ~primary_key:Pk.label
end
