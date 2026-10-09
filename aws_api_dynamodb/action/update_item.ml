open Ppx_yojson_conv_lib.Yojson_conv.Primitives

module Def = struct
  let action = "UpdateItem"

  type request = {
    table_name : string;
    key : Item.t;
    update_expression : string;
    expression_attribute_values : Item.t;
  }

  let yojson_of_request { table_name; key; update_expression; expression_attribute_values } =
    `Assoc
      [
        "TableName", `String table_name;
        "Key", Wire.yojson_of_item key;
        "UpdateExpression", `String update_expression;
        "ExpressionAttributeValues", Wire.yojson_of_item expression_attribute_values;
        "ReturnValues", `String "ALL_NEW";
      ]

  type response = { attributes : Wire.item option [@key "Attributes"] [@yojson.option] }
  [@@deriving of_yojson] [@@yojson.allow_extra_fields]

  let make ~table_name ~key ~update_expression ~expression_attribute_values =
    { table_name; key; update_expression; expression_attribute_values }
end

include Def
include Spec.Make (Def)
