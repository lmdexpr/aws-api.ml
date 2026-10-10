(* Wire representations of Smithy simple shapes that Yojson has no direct type for. *)

(* Empty structure (and [smithy.api#Unit]): [{}] on the wire. *)
type empty = unit

let yojson_of_empty () : Yojson.Safe.t = `Assoc []
let empty_of_yojson (_ : Yojson.Safe.t) = ()

(* [smithy.api#Blob]: base64. *)
type blob = string

let yojson_of_blob s : Yojson.Safe.t = `String (Base64.encode_string s)

let blob_of_yojson : Yojson.Safe.t -> blob = function
  | `String s as json -> (
    match Base64.decode s with
    | Ok s -> s
    | Error (`Msg msg) -> Ppx_yojson_conv_lib.Yojson_conv.of_yojson_error msg json)
  | json -> Ppx_yojson_conv_lib.Yojson_conv.of_yojson_error "blob: string expected" json

(* [smithy.api#Timestamp]: epoch seconds, fractional. *)
type timestamp = float

let yojson_of_timestamp t : Yojson.Safe.t = `Float t

let timestamp_of_yojson : Yojson.Safe.t -> timestamp = function
  | `Float f -> f
  | `Int i -> float_of_int i
  | `Intlit s -> float_of_string s
  | json -> Ppx_yojson_conv_lib.Yojson_conv.of_yojson_error "timestamp: number expected" json

(* Smithy maps with string keys. *)
type 'a map = (string * 'a) list

let yojson_of_map f (m : _ map) : Yojson.Safe.t = `Assoc (List.map (fun (k, v) -> k, f v) m)

let map_of_yojson f : Yojson.Safe.t -> _ map = function
  | `Assoc kvs -> List.map (fun (k, v) -> k, f v) kvs
  | json -> Ppx_yojson_conv_lib.Yojson_conv.of_yojson_error "map: object expected" json

(* [smithy.api#Document]: passed through. *)
type document = Yojson.Safe.t

let yojson_of_document (d : document) = d
let document_of_yojson (d : Yojson.Safe.t) : document = d
