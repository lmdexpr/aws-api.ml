type error = { path : string; message : string }

exception Conversion_error of error

let error_to_string { path; message } = path ^ ": " ^ message
let fail path message = raise (Conversion_error { path; message })
let field path name = path ^ Printf.sprintf "[%S]" name
let index path i = path ^ Printf.sprintf "[%d]" i
let get path = function Ok x -> x | Error message -> fail path message
let protect f = try Ok (f ()) with Conversion_error e -> Error e

type numbers = [ `Exact | `Float | `String ]
type sets = [ `Reject | `Lists ]
type binary = [ `Reject | `Base64 ]

let rec import path : Yojson.Safe.t -> Value.t = function
  | `String s -> String s
  | `Int i -> Value.int i
  | `Intlit s -> Number (get path (Number.of_string s))
  | `Float f -> Number (get path (Number.of_float f))
  | `Bool b -> Bool b
  | `Null -> Null
  | `List xs -> List (List.mapi (fun i x -> import (index path i) x) xs)
  | `Assoc xs ->
    Map
      (List.fold_left
         (fun acc (k, v) ->
           let path = field path k in
           if Value.String_map.mem k acc then fail path "duplicate attribute name";
           Value.String_map.add k (import path v) acc)
         Value.String_map.empty xs)

let value_of_yojson_exn json = import "$" json
let value_of_yojson json = protect (fun () -> value_of_yojson_exn json)

let item_of_yojson_exn json =
  match value_of_yojson_exn json with
  | Value.Map m -> Item.of_list (Value.String_map.bindings m)
  | _ -> fail "$" "object expected for item"

let item_of_yojson json = protect (fun () -> item_of_yojson_exn json)

let yojson_of_value_exn ?(numbers = `Float) ?(sets = `Reject) ?(binary = `Reject) value =
  let number path n : Yojson.Safe.t =
    if numbers = `String then
      `String (Number.to_string n)
    else
      match
        Number.to_integer_string n
      with
      | Ok s -> ( match int_of_string_opt s with Some i -> `Int i | None -> `Intlit s)
      | Error _ ->
        if numbers = `Float then
          `Float (Number.to_float n)
        else
          fail path "fractional number requires an explicit Float or String projection"
  in
  let rec export path : Value.t -> Yojson.Safe.t = function
    | String s -> `String s
    | Number n -> number path n
    | Binary s ->
      if binary = `Base64 then
        `String (Base64.encode_string s)
      else
        fail path "binary requires an explicit Base64 projection"
    | Bool b -> `Bool b
    | Null -> `Null
    | List xs -> `List (List.mapi (fun i x -> export (index path i) x) xs)
    | Map m ->
      `Assoc (List.map (fun (k, v) -> k, export (field path k) v) (Value.String_map.bindings m))
    | String_set s -> set path (List.map (fun x -> Value.String x) (Value.String_set.to_list s))
    | Number_set s -> set path (List.map (fun x -> Value.Number x) (Value.Number_set.to_list s))
    | Binary_set s -> set path (List.map (fun x -> Value.Binary x) (Value.Binary_set.to_list s))
  and set path xs =
    if sets = `Lists then
      export path (Value.List xs)
    else
      fail path "set requires an explicit Lists projection"
  in
  export "$" value

let yojson_of_value ?numbers ?sets ?binary value =
  protect (fun () -> yojson_of_value_exn ?numbers ?sets ?binary value)

let yojson_of_item_exn ?numbers ?sets ?binary item =
  yojson_of_value_exn ?numbers ?sets ?binary
    (Value.Map (Value.String_map.of_list (Item.to_list item)))

let yojson_of_item ?numbers ?sets ?binary item =
  protect (fun () -> yojson_of_item_exn ?numbers ?sets ?binary item)
