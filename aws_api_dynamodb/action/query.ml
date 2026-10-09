open Ppx_yojson_conv_lib.Yojson_conv.Primitives

module Def = struct
  let action = "Query"

  type request = {
    table_name : string; [@key "TableName"]
    key_condition_expression : string; [@key "KeyConditionExpression"]
    expression_attribute_names : Wire.names option;
       [@key "ExpressionAttributeNames"] [@yojson.option]
    expression_attribute_values : Wire.item; [@key "ExpressionAttributeValues"]
    filter_expression : string option; [@key "FilterExpression"] [@yojson.option]
    limit : int option; [@key "Limit"] [@yojson.option]
    scan_index_forward : bool option; [@key "ScanIndexForward"] [@yojson.option]
    exclusive_start_key : Wire.item option; [@key "ExclusiveStartKey"] [@yojson.option]
  }
  [@@deriving yojson_of]

  type response = {
    items : Wire.item list; [@key "Items"] [@default []]
    last_evaluated_key : Wire.item option; [@key "LastEvaluatedKey"] [@yojson.option]
  }
  [@@deriving of_yojson] [@@yojson.allow_extra_fields]

  let make ?filter_expression ?expression_attribute_names ?limit ?scan_index_forward
    ?exclusive_start_key ~table_name ~key_condition_expression ~expression_attribute_values () =
    {
      table_name;
      key_condition_expression;
      expression_attribute_names;
      expression_attribute_values;
      filter_expression;
      limit;
      scan_index_forward;
      exclusive_start_key;
    }
end

include Def
include Spec.Make (Def)
