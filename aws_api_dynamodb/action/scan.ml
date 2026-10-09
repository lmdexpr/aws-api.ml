open Ppx_yojson_conv_lib.Yojson_conv.Primitives

module Def = struct
  let action = "Scan"

  type request = {
    table_name : string; [@key "TableName"]
    exclusive_start_key : Wire.item option; [@key "ExclusiveStartKey"] [@yojson.option]
  }
  [@@deriving yojson_of]

  type response = {
    items : Wire.item list; [@key "Items"] [@default []]
    last_evaluated_key : Wire.item option; [@key "LastEvaluatedKey"] [@yojson.option]
  }
  [@@deriving of_yojson] [@@yojson.allow_extra_fields]

  let make ?exclusive_start_key ~table_name () = { table_name; exclusive_start_key }
end

include Def
include Spec.Make (Def)
