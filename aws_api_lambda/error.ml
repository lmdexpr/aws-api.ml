type t = { error_type : string; error_message : string; stack_trace : string list }

(* [error_type] travels in the Lambda-Runtime-Function-Error-Type header: keep it to the
   <Category.Reason> token shape so no header can be injected through it. *)
let sanitize_error_type s =
  let s =
    String.map
      (fun c -> if Char.Ascii.is_alphanum c || c = '.' || c = '_' || c = '-' then c else '_')
      s
  in
  if s = "" then "Error" else s

let v ?(stack_trace = []) ~error_type error_message =
  { error_type = sanitize_error_type error_type; error_message; stack_trace }

let stack_trace_of_backtrace bt =
  Printexc.raw_backtrace_to_string bt
  |> String.split_on_char '\n'
  |> List.filter (fun line -> line <> "")

let of_exn ?backtrace exn =
  {
    error_type = sanitize_error_type (Printexc.exn_slot_name exn);
    error_message = Printexc.to_string exn;
    stack_trace = Option.fold ~none:[] ~some:stack_trace_of_backtrace backtrace;
  }

let json_string s =
  let b = Buffer.create (String.length s + 2) in
  Buffer.add_char b '"';
  String.iter
    (function
      | '"' -> Buffer.add_string b "\\\""
      | '\\' -> Buffer.add_string b "\\\\"
      | '\n' -> Buffer.add_string b "\\n"
      | '\r' -> Buffer.add_string b "\\r"
      | '\t' -> Buffer.add_string b "\\t"
      | c when Char.code c < 0x20 -> Buffer.add_string b (Printf.sprintf "\\u%04x" (Char.code c))
      | c -> Buffer.add_char b c)
    s;
  Buffer.add_char b '"';
  Buffer.contents b

let to_json { error_type; error_message; stack_trace } =
  Printf.sprintf {|{"errorMessage":%s,"errorType":%s,"stackTrace":[%s]}|}
    (json_string error_message) (json_string error_type)
    (String.concat "," (List.map json_string stack_trace))
