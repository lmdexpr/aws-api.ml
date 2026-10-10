(* Exercises every Client operation and Transaction against DynamoDB Local. *)

open Aws_api_dynamodb_client

let ok = function Ok x -> x | Error e -> failwith (Error.to_string e)
let value = function Ok v -> v | Error e -> failwith e
let check name b = Printf.printf "%s %s\n%!" (if b then "ok  " else "FAIL") name

let () =
  let endpoint = Uri.of_string Sys.argv.(1) and table = Sys.argv.(2) in
  Eio_main.run @@ fun env ->
  let client = Cohttp_eio.Client.make ~https:None env#net in
  let now () = Eio.Time.now env#clock in
  Aws_api_cohttp_eio.run ~client @@ fun () ->
  let api = local ~endpoint ~now () in
  let db = Client.make api ~table in
  let key = Item.singleton "pk" (Value.String "e2e") in
  let item =
    Item.of_list
      [
        "pk", Value.String "e2e";
        "n", Value.Number (Number.of_string_exn "1e125");
        "f", value (Value.float 0.1);
        "b", Value.Binary "\000\255";
        "bool", Value.Bool true;
        "null", Value.Null;
        "l", Value.List [ Value.int 1; Value.String "x" ];
        "m", Value.Map (Value.String_map.singleton "k" (Value.int 2));
        "ss", Value.String_set (value (Value.String_set.of_list [ "a"; "b" ]));
        ( "ns",
          Value.Number_set
            (value (Value.Number_set.of_list [ Number.of_int 1; Number.of_string_exn "2.5" ])) );
        "bs", Value.Binary_set (value (Value.Binary_set.of_list [ "\000"; "\255" ]));
        "version", Value.int 1;
      ]
  in
  ok (Client.delete db ~key);
  ok (Client.put db ~item);
  check "get returns the same typed item"
    (Client.get db ~key |> ok = Some item || Item.equal (Option.get (ok (Client.get db ~key))) item);
  (match Client.put_if_not_exists db ~item ~primary_key:"pk" with
  | Error e -> check "put_if_not_exists reports the condition" (Error.is_conditional_check_failed e)
  | Ok () -> check "put_if_not_exists reports the condition" false);
  ok
    (Client.compare_and_swap db
       ~item:(Item.add "version" (Value.int 2) item)
       ~attribute:"version" ~expected:(Value.int 1));
  (match Client.compare_and_swap db ~item ~attribute:"version" ~expected:(Value.int 1) with
  | Error e -> check "stale compare_and_swap fails" (Error.is_conditional_check_failed e)
  | Ok () -> check "stale compare_and_swap fails" false);
  let updated =
    ok
      (Client.update db ~key ~update_expression:"SET version = version + :one"
         ~expression_attribute_values:(Item.singleton ":one" (Value.int 1)))
  in
  check "update returns ALL_NEW" (Option.bind updated (Item.find_opt "version") = Some (Value.int 3));
  let scanned = ok (Client.scan db) in
  check "scan sees the item"
    (List.exists (fun i -> Item.find_opt "pk" i = Some (Value.String "e2e")) scanned);
  let other = Item.singleton "pk" (Value.String "e2e-2") in
  ok
    (Transaction.write api
       [
         Transaction.put_if_not_exists ~table_name:table ~item:other ~primary_key:"pk";
         Transaction.delete ~table_name:table ~key ();
       ]);
  check "transaction applied both writes"
    (ok (Client.get db ~key) = None && ok (Client.get db ~key:other) <> None);
  (match
     Transaction.write api
       [ Transaction.put_if_not_exists ~table_name:table ~item:other ~primary_key:"pk" ]
   with
  | Error e ->
    check "transaction condition failure is recognized" (Error.is_conditional_check_failed e)
  | Ok () -> check "transaction condition failure is recognized" false);
  ok (Client.delete db ~key:other);
  match Client.get (Client.make api ~table:"no-such-table") ~key with
  | Error e -> check "ResourceNotFoundException is parsed" (e.code = "ResourceNotFoundException")
  | Ok _ -> check "ResourceNotFoundException is parsed" false
