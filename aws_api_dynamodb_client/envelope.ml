(* Typed attribute values <-> the generated [Aws_api_dynamodb.attribute_value] envelope. JSON never appears
   here; [Api] does that. Decoding failures raise [Of_yojson_error] with a path, which
   [Aws_json_transport] turns into [Error.deserialization]. *)

type attrs = Aws_api_dynamodb.attribute_value Aws_api_dynamodb.Wire.map

let rec of_value : Value.t -> Aws_api_dynamodb.attribute_value =
  let av = Aws_api_dynamodb.attribute_value in
  function
  | String s -> av ~s ()
  | Number n -> av ~n:(Number.to_string n) ()
  | Binary b -> av ~b ()
  | Bool bool -> av ~bool ()
  | Null -> av ~null:true ()
  | List values -> av ~l:(List.map of_value values) ()
  | Map m -> av ~m:(of_map m) ()
  | String_set s -> av ~ss:(Value.String_set.to_list s) ()
  | Number_set s -> av ~ns:(List.map Number.to_string (Value.Number_set.to_list s)) ()
  | Binary_set s -> av ~bs:(Value.Binary_set.to_list s) ()

and of_map m = List.map (fun (k, v) -> k, of_value v) (Value.String_map.bindings m)

let fail path msg =
  raise
    (Ppx_yojson_conv_lib.Yojson_conv.Of_yojson_error (Failure ("Wire " ^ path ^ ": " ^ msg), `Null))

let get path = function Ok x -> x | Error msg -> fail path msg
let field path k = path ^ Printf.sprintf "[%S]" k
let at path i = path ^ Printf.sprintf "[%d]" i

(* Exactly one tag per value; the generated record cannot say so by itself. *)
let tags { Aws_api_dynamodb.s; n; b; ss; ns; bs; m; l; null; bool } =
  List.length
    (List.filter Fun.id
       [
         Option.is_some s;
         Option.is_some n;
         Option.is_some b;
         Option.is_some ss;
         Option.is_some ns;
         Option.is_some bs;
         Option.is_some m;
         Option.is_some l;
         Option.is_some null;
         Option.is_some bool;
       ])

let rec to_value path (av : Aws_api_dynamodb.attribute_value) : Value.t =
  let number path n = get path (Number.of_string n) in
  if tags av <> 1 then fail path "invalid attribute value";
  match av with
  | { s = Some s; _ } -> String s
  | { n = Some n; _ } -> Number (number path n)
  | { b = Some b; _ } -> Binary b
  | { bool = Some b; _ } -> Bool b
  | { null = Some true; _ } -> Null
  | { l = Some xs; _ } -> List (List.mapi (fun i x -> to_value (at path i) x) xs)
  | { m = Some kvs; _ } -> Map (to_map path kvs)
  | { ss = Some xs; _ } -> String_set (get path (Value.String_set.of_list xs))
  | { ns = Some xs; _ } ->
    Number_set
      (get path (Value.Number_set.of_list (List.mapi (fun i n -> number (at path i) n) xs)))
  | { bs = Some xs; _ } -> Binary_set (get path (Value.Binary_set.of_list xs))
  | _ -> fail path "invalid attribute value"

and to_map path kvs =
  List.fold_left
    (fun acc (k, v) ->
      let path = field path k in
      if Value.String_map.mem k acc then fail path "duplicate attribute name";
      Value.String_map.add k (to_value path v) acc)
    Value.String_map.empty kvs

let of_item item : attrs = Item.to_list item |> List.map (fun (k, v) -> k, of_value v)
let to_item (attrs : attrs) = to_map "$" attrs |> Value.String_map.bindings |> Item.of_list
let items = function None -> [] | Some xs -> List.map to_item xs

(* The envelope as JSON, for tests and for reading items out of other services (Streams). *)
let yojson_of_attrs (attrs : attrs) =
  Aws_api_dynamodb.Wire.yojson_of_map Aws_api_dynamodb.yojson_of_attribute_value attrs

let attrs_of_yojson json : attrs =
  Aws_api_dynamodb.Wire.map_of_yojson Aws_api_dynamodb.attribute_value_of_yojson json
