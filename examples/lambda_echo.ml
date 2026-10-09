(* A custom runtime that echoes the event. Deploy as the `bootstrap` binary of a provided.al2023
   function; the Runtime API endpoint comes from AWS_LAMBDA_RUNTIME_API. *)

let () =
  Eio_main.run @@ fun env ->
  let client = Cohttp_eio.Client.make ~https:None env#net in
  let endpoint = Option.get (Aws_api_lambda.Http.endpoint_from_env ()) in
  let fatal =
    Aws_api_cohttp_eio.run ~client @@ fun () ->
    Aws_api_lambda.Http.run ~propagate:Aws_api_cohttp_eio.is_cancelled ~endpoint
    @@ fun invocation -> Ok (Printf.sprintf {|{"echo":%s}|} invocation.payload)
  in
  prerr_endline (Aws_api_lambda.fatal_to_string fatal);
  exit 1
