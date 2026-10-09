open Aws_api_dynamodb
open Ppx_yojson_conv_lib.Yojson_conv.Primitives

let json = Alcotest.testable Yojson.Safe.pp Yojson.Safe.equal
let ok = function Ok x -> x | Error message -> Alcotest.fail message
let number = Number.of_string_exn

let encode item =
  Action.Put_item.(make ~table_name:"example-table" ~item () |> yojson_of_request)
  |> Yojson.Safe.Util.member "Item"

let decode wire =
  let Action.Get_item.{ item } = Action.Get_item.response_of_yojson (`Assoc [ "Item", wire ]) in
  Option.get item

let expect_error label = function
  | Error _ -> ()
  | Ok _ -> Alcotest.fail (label ^ ": expected error")

let test_numbers () =
  List.iter
    (fun (input, expected) ->
      Alcotest.(check string) input expected (Number.to_string (number input)))
    [
      "-0.000", "0";
      "+001.2300e2", "123";
      "1e-130", "1e-130";
      "1e125", "1e125";
      "10e124", "1e125";
      ".5", "0.5";
      "99999999999999999999999999999999999999e88", "99999999999999999999999999999999999999e88";
    ];
  List.iter
    (fun s -> expect_error s (Number.of_string s))
    [
      "";
      " ";
      ".";
      "1e";
      "1e+";
      "1e-";
      "--1";
      "1.2.3";
      "1_000";
      "0x10";
      "nan";
      "inf";
      "1e126";
      "1e-131";
      "123456789012345678901234567890123456789";
      "0.123456789012345678901234567890123456789";
      "1e99999999999999999999999999999999999999";
    ];
  List.iter
    (fun i -> Alcotest.(check int) "integer round-trip" i (ok (Number.to_int (Number.of_int i))))
    [ min_int; max_int; 0; -1; 1000 ];
  expect_error "fraction to int" (Number.to_int (number "1.5"));
  expect_error "overflow to int" (Number.to_int (number "1e125"));
  Alcotest.(check int) "integral exponent" 1000 (ok (Number.to_int (number "1e3")));
  List.iter
    (fun f -> expect_error "invalid float" (Number.of_float f))
    [ Float.nan; Float.infinity; Float.neg_infinity; 1e126; 1e-131 ];
  let state = Random.State.make [| 42 |] in
  for _ = 1 to 1000 do
    let f =
      (Random.State.float state 2. -. 1.) *. (10. ** float_of_int (Random.State.int state 240 - 120))
    in
    let n = ok (Number.of_float f) in
    Alcotest.(check bool) "float round-trip" true (Float.equal f (Number.to_float n));
    Alcotest.(check bool)
      "canonical decimal round-trip" true
      (Number.equal n (number (Number.to_string n)))
  done

let test_sets () =
  let ordered =
    List.map number
      [ "-1e125"; "-10"; "-1.01"; "-1"; "-1e-130"; "0"; "1e-130"; "1"; "1.01"; "10"; "1e125" ]
  in
  List.iteri
    (fun i a ->
      List.iteri
        (fun j b ->
          Alcotest.(check int)
            "exact numeric ordering" (Int.compare i j)
            (Int.compare (Number.compare a b) 0))
        ordered)
    ordered;
  expect_error "empty string set" (Value.String_set.of_list []);
  expect_error "empty number set" (Value.Number_set.of_list []);
  expect_error "empty binary set" (Value.Binary_set.of_list []);
  expect_error "duplicate string" (Value.String_set.of_list [ "a"; "a" ]);
  expect_error "duplicate bytes" (Value.Binary_set.of_list [ "\000"; "\000" ]);
  expect_error "equal decimals" (Value.Number_set.of_list [ number "1.0"; number "1e0" ]);
  expect_error "signed zero" (Value.Number_set.of_list [ number "0"; number "-0" ]);
  let set xs = Value.String_set (ok (Value.String_set.of_list xs)) in
  Alcotest.(check bool) "set order ignored" true (Value.equal (set [ "a"; "b" ]) (set [ "b"; "a" ]));
  Alcotest.(check bool)
    "list order retained" false
    (Value.equal
       (Value.List [ Value.int 1; Value.int 2 ])
       (Value.List [ Value.int 2; Value.int 1 ]))

let test_wire_round_trip () =
  (* Canonical, synthetic wire data, independent of the encoder. Includes a
     decimal that cannot survive conversion to a float. *)
  let wire =
    Yojson.Safe.from_string
      {|{"b":{"B":"AP8="},"bool":{"BOOL":false},"bs":{"BS":["","AP8="]},
       "list":{"L":[{"NULL":true},{"M":{"inner":{"NS":["1","1.2345678901234567890123456789012345678"]}}}]},
       "n":{"N":"1.2345678901234567890123456789012345678"},
       "ns":{"NS":["1","2.5"]},"s":{"S":""},"ss":{"SS":["a","b"]}}|}
  in
  let item = decode wire in
  Alcotest.check json "read then write preserves types and decimal precision" wire (encode item);
  (match Item.find_opt "b" item with
  | Some (Value.Binary bytes) -> Alcotest.(check string) "raw bytes" "\000\255" bytes
  | _ -> Alcotest.fail "binary tag lost");
  let received = ref None in
  let run f =
    try f ()
    with effect Effects.Call { action; body }, k ->
      let response =
        if action = "GetItem" then
          `Assoc [ "Item", wire ]
        else (
          received := Some (Yojson.Safe.from_string body |> Yojson.Safe.Util.member "Item");
          `Assoc [])
      in
      Effect.Deep.continue k (Ok response)
  in
  run (fun () ->
    let db = Client.make ~table:"example-table" in
    match Client.get db ~key:(Item.singleton "pk" (Value.String "a")) with
    | Ok (Some item) -> (
      match Client.put db ~item with Ok () -> () | _ -> Alcotest.fail "put failed")
    | _ -> Alcotest.fail "get failed");
  Alcotest.(check (option json))
    "client read/write retains unknown attributes" (Some wire) !received

let test_bad_wire () =
  List.iter
    (fun attribute ->
      let wire = `Assoc [ "outer", `Assoc [ "L", `List [ attribute ] ] ] in
      match decode wire with
      | _ -> Alcotest.fail "invalid wire accepted"
      | exception Ppx_yojson_conv_lib.Yojson_conv.Of_yojson_error (Failure message, _) ->
        Alcotest.(check bool)
          "nested path" true
          (String.starts_with ~prefix:"Wire $[\"outer\"][0]" message))
    [
      `Assoc [ "N", `String "nan" ];
      `Assoc [ "B", `String "!!!" ];
      `Assoc [ "SS", `List [] ];
      `Assoc [ "SS", `List [ `Int 1 ] ];
      `Assoc [ "NS", `List [ `String "1"; `String "1.0" ] ];
      `Assoc [ "NULL", `Bool false ];
      `Assoc [ "S", `String "x"; "N", `String "1" ];
    ];
  match decode (`Assoc [ "x", `Assoc [ "S", `String "a" ]; "x", `Assoc [ "S", `String "b" ] ]) with
  | _ -> Alcotest.fail "duplicate wire attribute accepted"
  | exception Ppx_yojson_conv_lib.Yojson_conv.Of_yojson_error _ -> ()

let test_json_policies () =
  let n = number "1.2345678901234567890123456789012345678" in
  let item = Item.singleton "outer" (Value.List [ Value.Number n ]) in
  (match Projection.yojson_of_item ~numbers:`Exact item with
  | Error { path; _ } -> Alcotest.(check string) "number path" "$[\"outer\"][0]" path
  | Ok _ -> Alcotest.fail "Exact accepted a fraction");
  Alcotest.check json "default rounds to float"
    (`Assoc [ "outer", `List [ `Float (Number.to_float n) ] ])
    (Projection.yojson_of_item_exn item);
  Alcotest.check json "explicit exact decimal strings"
    (`Assoc [ "outer", `List [ `String (Number.to_string n) ] ])
    (Projection.yojson_of_item_exn ~numbers:`String item);
  Alcotest.check json "explicit float"
    (`Assoc [ "outer", `List [ `Float (Number.to_float n) ] ])
    (Projection.yojson_of_item_exn ~numbers:`Float item);
  let set = Value.Binary_set (ok (Value.Binary_set.of_list [ "\000\255" ])) in
  expect_error "default rejects sets" (Projection.yojson_of_value set);
  expect_error "Lists alone does not allow binary" (Projection.yojson_of_value ~sets:`Lists set);
  Alcotest.check json "explicit binary set projection"
    (`List [ `String "AP8=" ])
    (Projection.yojson_of_value_exn ~sets:`Lists ~binary:`Base64 set);
  let ordinary = `Assoc [ "N", `String "1.23"; "SS", `List [ `String "a" ] ] in
  Alcotest.check json "JSON envelopes are ordinary maps" ordinary
    (Projection.value_of_yojson_exn ordinary |> Projection.yojson_of_value_exn);
  expect_error "nonfinite JSON" (Projection.value_of_yojson (`Float Float.nan));
  expect_error "duplicate JSON names"
    (Projection.item_of_yojson (`Assoc [ "a", `Null; "a", `Null ]));
  let large = "12345678901234567890123456789012345678" in
  Alcotest.check json "exact large integer" (`Intlit large)
    (Projection.yojson_of_value_exn (Value.Number (number large)))

type record = { id : string; timestamp : float; count : int; labels : string list }
[@@deriving yojson]

module Row = Single_table.Pk_row (struct
  type t = record [@@deriving yojson]
  type key = string

  let key = "RECORD"
  let get_key r = r.id
  let get_pk k = k
end)

let test_record_codec () =
  (* Public codec with PPX-generated record conversions, including epoch
     seconds, integer-valued floats and old decimal encodings. *)
  List.iter
    (fun timestamp ->
      let r = { id = "example"; timestamp; count = 4; labels = [ "x"; "y" ] } in
      let item = Row.to_item r |> encode |> decode in
      Alcotest.(check bool) "derived record read/write" true (r = Row.of_item item))
    [ 1700000000.; 1700000000.123456; 1. /. 3. ];
  let old =
    Yojson.Safe.from_string
      {|{"count":{"N":"4"},"id":{"S":"example"},"labels":{"L":[]},"timestamp":{"N":"1700000000.125"}}|}
  in
  let r = decode old |> Projection.yojson_of_item_exn |> record_of_yojson in
  Alcotest.(check (float 0.)) "existing decimal timestamp" 1700000000.125 r.timestamp;
  let stripped = Row.to_item r |> Single_table.strip_key in
  Alcotest.(check bool)
    "strip only removes keys" false
    (Item.mem "pk" stripped || Item.mem "sk" stripped)

let () =
  Alcotest.run "typed values"
    [
      "number", [ Alcotest.test_case "bounds, validation and conversions" `Quick test_numbers ];
      "value", [ Alcotest.test_case "set invariants" `Quick test_sets ];
      ( "wire",
        [
          Alcotest.test_case "all types survive read/write" `Quick test_wire_round_trip;
          Alcotest.test_case "invalid values report paths" `Quick test_bad_wire;
        ] );
      ( "json",
        [
          Alcotest.test_case "explicit projection policies" `Quick test_json_policies;
          Alcotest.test_case "derived record compatibility" `Quick test_record_codec;
        ] );
    ]
