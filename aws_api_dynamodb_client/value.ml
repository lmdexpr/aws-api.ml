module String_map = Map.Make (String)

module Make_set (Ord : Set.OrderedType) = struct
  module S = Set.Make (Ord)

  type t = S.t

  let of_list xs =
    let s = S.of_list xs in
    if S.is_empty s then
      Error "DynamoDB sets must not be empty"
    else if S.cardinal s <> List.length xs then
      Error "duplicate set member"
    else
      Ok s

  let to_list = S.elements
  let equal = S.equal
end

module String_set = Make_set (String)
module Binary_set = Make_set (String)
module Number_set = Make_set (Number)

type t =
  | String of string
  | Number of Number.t
  | Binary of string
  | Bool of bool
  | Null
  | List of t list
  | Map of t String_map.t
  | String_set of String_set.t
  | Number_set of Number_set.t
  | Binary_set of Binary_set.t

let int i = Number (Number.of_int i)
let float f = Result.map (fun n -> Number n) (Number.of_float f)

let rec equal a b =
  match a, b with
  | String a, String b | Binary a, Binary b -> String.equal a b
  | Number a, Number b -> Number.equal a b
  | Bool a, Bool b -> Bool.equal a b
  | Null, Null -> true
  | List a, List b -> List.equal equal a b
  | Map a, Map b -> String_map.equal equal a b
  | String_set a, String_set b -> String_set.equal a b
  | Number_set a, Number_set b -> Number_set.equal a b
  | Binary_set a, Binary_set b -> Binary_set.equal a b
  | _ -> false
