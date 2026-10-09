(* Signs one request with fixed credentials and prints the headers to add. No I/O: time and
   credentials are injected. *)

let () =
  let body = {|{"TableName":"users","Key":{"pk":{"S":"alice"}}}|} in
  let signed =
    Sigv4.with_provider
      (Sigv4.Provider.Static.make ~access_key:"AKIDEXAMPLE"
         ~secret_key:"wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY" ())
    @@ fun () ->
    let credentials = Sigv4.Credentials.fetch () in
    Sigv4.sign
      ~now:(fun () -> 1_767_225_600. (* 2026-01-01T00:00:00Z *))
      ~credentials ~region:"us-east-1" ~service:"dynamodb" ~http_method:"POST" ~payload:body
      ~uri:(Uri.of_string "https://dynamodb.us-east-1.amazonaws.com/")
      [
        "Host", "dynamodb.us-east-1.amazonaws.com";
        "Content-Type", "application/x-amz-json-1.0";
        "X-Amz-Target", "DynamoDB_20120810.GetItem";
      ]
  in
  List.iter (fun (name, value) -> Printf.printf "%s: %s\n" name value) signed
