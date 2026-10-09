open Ppx_yojson_conv_lib.Yojson_conv.Primitives

module Def = struct
  let action = "GetItem"

  type request = { table_name : string; [@key "TableName"] key : Wire.item [@key "Key"] }
  [@@deriving yojson_of]

  type response = { item : Wire.item option [@key "Item"] [@yojson.option] }
  [@@deriving of_yojson] [@@yojson.allow_extra_fields]

  let make ~table_name ~key = { table_name; key }
end

include Def
include Spec.Make (Def)
