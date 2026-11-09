(** Reads a Smithy JSON AST model and prints one OCaml module for its service. Model reads, Plan
    decides what is generated, Emit prints; all I/O is here. *)

let () =
  let path = Sys.argv.(1) in
  Yojson.Safe.from_file path |> Model.of_json |> Plan.make
  |> Emit.run ~source:(Filename.basename path)
  |> print_string
