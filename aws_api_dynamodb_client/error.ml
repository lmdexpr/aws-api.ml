include Aws_api_dynamodb.Error

(* [TransactionCanceledException] lists one reason per transact item. *)
let cancellation_reasons { body; _ } =
  let open Yojson.Safe.Util in
  match Yojson.Safe.from_string body |> member "CancellationReasons" |> to_list with
  | reasons -> List.filter_map (fun r -> member "Code" r |> to_string_option) reasons
  | exception (Yojson.Json_error _ | Type_error _) -> []

let too_many_pages_code = "TooManyPages"

let too_many_pages ~max_pages =
  {
    code = too_many_pages_code;
    message = Some (Printf.sprintf "stopped after %d pages" max_pages);
    body = "";
  }

let is_too_many_pages { code; _ } = String.equal code too_many_pages_code

let is_conditional_check_failed ({ code; _ } as e) =
  String.equal code "ConditionalCheckFailedException"
  || String.equal code "TransactionCanceledException"
     && List.exists (String.equal "ConditionalCheckFailed") (cancellation_reasons e)
