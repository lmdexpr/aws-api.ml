open Ppx_yojson_conv_lib.Yojson_conv.Primitives

module Def = struct
  let action = "PutItem"

  type request = {
    table_name : string; [@key "TableName"]
    item : Wire.item; [@key "Item"]
    condition_expression : string option; [@key "ConditionExpression"] [@yojson.option]
    expression_attribute_names : Wire.names option;
       [@key "ExpressionAttributeNames"] [@yojson.option]
    expression_attribute_values : Wire.item option;
       [@key "ExpressionAttributeValues"] [@yojson.option]
  }
  [@@deriving yojson_of]

  let make ?condition_expression ?expression_attribute_names ?expression_attribute_values
    ~table_name ~item () =
    {
      table_name;
      item;
      condition_expression;
      expression_attribute_names;
      expression_attribute_values;
    }
end

include Def
include Spec.Make_write (Def)
