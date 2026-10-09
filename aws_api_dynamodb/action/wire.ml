(* Typed attribute-value envelope. JSON projections never run at this boundary. *)
let rec yojson_of_value : Value.t -> Yojson.Safe.t = function
  | String s -> `Assoc [ "S", `String s ]
  | Number n -> `Assoc [ "N", `String (Number.to_string n) ]
  | Binary s -> `Assoc [ "B", `String (Base64.encode_string s) ]
  | Bool b -> `Assoc [ "BOOL", `Bool b ]
  | Null -> `Assoc [ "NULL", `Bool true ]
  | List values -> `Assoc [ "L", `List (List.map yojson_of_value values) ]
  | Map m ->
    `Assoc
      [ "M", `Assoc (List.map (fun (k, v) -> k, yojson_of_value v) (Value.String_map.bindings m)) ]
  | String_set s ->
    `Assoc [ "SS", `List (List.map (fun s -> `String s) (Value.String_set.to_list s)) ]
  | Number_set s ->
    `Assoc
      [
        "NS", `List (List.map (fun n -> `String (Number.to_string n)) (Value.Number_set.to_list s));
      ]
  | Binary_set s ->
    `Assoc
      [
        ( "BS",
          `List (List.map (fun s -> `String (Base64.encode_string s)) (Value.Binary_set.to_list s))
        );
      ]

let fail path msg json =
  raise
    (Ppx_yojson_conv_lib.Yojson_conv.Of_yojson_error (Failure ("Wire " ^ path ^ ": " ^ msg), json))

let get path json = function Ok x -> x | Error msg -> fail path msg json
let field path k = path ^ Printf.sprintf "[%S]" k
let at path i = path ^ Printf.sprintf "[%d]" i
let string path = function `String s -> s | json -> fail path "string expected" json

let binary path json =
  match Base64.decode (string path json) with Ok s -> s | Error (`Msg msg) -> fail path msg json

let rec value_of_yojson path json : Value.t =
  let members xs decode = List.mapi (fun i x -> decode (at path i) x) xs in
  match json with
  | `Assoc [ ("S", `String s) ] -> String s
  | `Assoc [ ("N", `String n) ] -> Number (get path json (Number.of_string n))
  | `Assoc [ ("B", b) ] -> Binary (binary path b)
  | `Assoc [ ("BOOL", `Bool b) ] -> Bool b
  | `Assoc [ ("NULL", `Bool true) ] -> Null
  | `Assoc [ ("L", `List xs) ] -> List (members xs value_of_yojson)
  | `Assoc [ ("M", `Assoc xs) ] -> Map (map_of_yojson path xs)
  | `Assoc [ ("SS", `List xs) ] ->
    String_set (get path json (Value.String_set.of_list (members xs string)))
  | `Assoc [ ("NS", `List xs) ] ->
    let ns = members xs (fun path x -> get path x (Number.of_string (string path x))) in
    Number_set (get path json (Value.Number_set.of_list ns))
  | `Assoc [ ("BS", `List xs) ] ->
    Binary_set (get path json (Value.Binary_set.of_list (members xs binary)))
  | _ -> fail path "invalid attribute value" json

and map_of_yojson path xs =
  List.fold_left
    (fun acc (k, v) ->
      let path = field path k in
      if Value.String_map.mem k acc then fail path "duplicate attribute name" v;
      Value.String_map.add k (value_of_yojson path v) acc)
    Value.String_map.empty xs

type item = Item.t

let yojson_of_item item = `Assoc (Item.to_list item |> List.map (fun (k, v) -> k, yojson_of_value v))

let item_of_yojson = function
  | `Assoc pairs -> map_of_yojson "$" pairs |> Value.String_map.bindings |> Item.of_list
  | json -> fail "$" "object expected for item" json

type names = (string * string) list

let yojson_of_names (pairs : names) : Yojson.Safe.t =
  `Assoc (List.map (fun (k, v) -> k, `String v) pairs)
