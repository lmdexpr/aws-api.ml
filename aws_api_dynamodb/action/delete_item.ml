open Ppx_yojson_conv_lib.Yojson_conv.Primitives

module Def = struct
  let action = "DeleteItem"

  type request = {
    table_name : string; [@key "TableName"]
    key : Wire.item; [@key "Key"]
    condition_expression : string option; [@key "ConditionExpression"] [@yojson.option]
    expression_attribute_names : Wire.names option;
       [@key "ExpressionAttributeNames"] [@yojson.option]
    expression_attribute_values : Wire.item option;
       [@key "ExpressionAttributeValues"] [@yojson.option]
  }
  [@@deriving yojson_of]

  let make ?condition_expression ?expression_attribute_names ?expression_attribute_values
    ~table_name ~key () =
    {
      table_name;
      key;
      condition_expression;
      expression_attribute_names;
      expression_attribute_values;
    }
end

include Def
include Spec.Make_write (Def)
