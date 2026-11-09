open Naming

type ty = Scalar of Model.scalar | Named of Ident.t | List of ty | Map of ty
type field = { wire : string; name : Ident.t; ty : ty; required : bool }
type record = { name : Ident.t; fields : field list; constructor : bool }
type enum = { name : Ident.t; values : (Tag.t * string) Nel.t }
type operation = { name : Ident.t; action : string; input : ty; output : ty }

type service = {
  protocol : Model.protocol;
  target_prefix : string;
  signing_name : Host_label.t;
  endpoint_prefix : Host_label.t;
}

type t = {
  service : service;
  enums : enum list;
  records : record list;
  operations : operation list;
}

let shape_name (id : Model.id) = Ident.snake ~context:(id :> string) (Model.local id)

let rec ty shapes (id : Model.id) =
  match Model.find shapes id with
  | Scalar s -> Scalar s
  | Enum _ | Record _ -> Named (shape_name id)
  | List member -> List (ty shapes member)
  | Map { value; _ } -> Map (ty shapes value)
  | Error _ -> failwith @@ Printf.sprintf "%s: error shape used as a member type" (id :> string)
  | Other kind -> failwith @@ Printf.sprintf "%s: unsupported shape %s" (id :> string) kind

(** Defined by the generated module before the records. A constructor of the same name would
    silently shadow them; clashes between types, fields or modules the compiler rejects itself. *)
let reserved_values = [ "protocol"; "make" ]

let record shapes (id : Model.id) (r : Model.record) =
  let context = (id :> string) in
  let name = shape_name id in
  let field (m : Model.member) =
    {
      wire = m.name;
      name = Ident.snake ~context m.name;
      ty = ty shapes m.target;
      required = m.required;
    }
  in
  let with_constructor fields =
    if List.mem (name :> string) reserved_values then
      failwith
      @@ Printf.sprintf "%s: constructor %s would shadow the generated one" context (name :> string);
    { name; fields; constructor = true }
  in
  match r with
  | Structure [] -> { name; fields = []; constructor = false }
  | Structure members -> with_constructor (List.map field members)
  | Union members -> with_constructor (Nel.to_list (Nel.map field members))

let service ({ id; protocol; signing_name; endpoint_prefix; _ } : Model.service) =
  let context = (id :> string) in
  {
    protocol =
      (match protocol with
      | Some p -> p
      | None -> failwith @@ Printf.sprintf "%s: not an AWS JSON protocol service" context);
    target_prefix = Model.local id;
    signing_name = Host_label.of_string ~context signing_name;
    endpoint_prefix = Host_label.of_string ~context endpoint_prefix;
  }

let enum (id : Model.id) values =
  {
    name = shape_name id;
    values = (values |> Nel.map @@ fun (tag, v) -> Tag.of_string ~context:(id :> string) tag, v);
  }

let operation shapes (id, ({ input; output } : Model.operation)) =
  {
    name = shape_name id;
    action = Model.local id;
    input = ty shapes input;
    output = ty shapes output;
  }

let make (model : Model.t) =
  {
    service = service model.service;
    enums = model.enums |> List.map (fun (id, values) -> enum id values);
    records = model.records |> List.map (fun (id, r) -> record model.shapes id r);
    operations = model.service.operations |> List.map (operation model.shapes);
  }
