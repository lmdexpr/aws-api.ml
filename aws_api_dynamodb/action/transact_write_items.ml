open Ppx_yojson_conv_lib.Yojson_conv.Primitives

module Def = struct
  let action = "TransactWriteItems"

  type item = Put of Put_item.request | Delete of Delete_item.request

  let yojson_of_item = function
    | Put put -> `Assoc [ "Put", Put_item.yojson_of_request put ]
    | Delete delete -> `Assoc [ "Delete", Delete_item.yojson_of_request delete ]

  type request = { transact_items : item list [@key "TransactItems"] } [@@deriving yojson_of]

  let make transact_items = { transact_items }
end

include Def
include Spec.Make_write (Def)
