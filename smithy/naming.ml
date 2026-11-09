let keywords =
  [
    "and";
    "as";
    "assert";
    "asr";
    "begin";
    "class";
    "constraint";
    "do";
    "done";
    "downto";
    "effect";
    "else";
    "end";
    "exception";
    "external";
    "false";
    "for";
    "fun";
    "function";
    "functor";
    "if";
    "in";
    "include";
    "inherit";
    "initializer";
    "land";
    "lazy";
    "let";
    "lor";
    "lsl";
    "lsr";
    "lxor";
    "match";
    "method";
    "mod";
    "module";
    "mutable";
    "new";
    "nonrec";
    "object";
    "of";
    "open";
    "or";
    "private";
    "rec";
    "sig";
    "struct";
    "then";
    "to";
    "true";
    "try";
    "type";
    "val";
    "virtual";
    "when";
    "while";
    "with";
  ]

let is_lower = function 'a' .. 'z' -> true | _ -> false
let is_upper = function 'A' .. 'Z' -> true | _ -> false
let is_digit = function '0' .. '9' -> true | _ -> false

(* Every character satisfies [ok], and the first is not a digit. *)
let identifier ok s = s <> "" && (not (is_digit s.[0])) && String.for_all ok s

module Ident = struct
  type t = string

  let snake ~context name =
    let n = String.length name in
    let upper i = Char.lowercase_ascii name.[i] <> name.[i] in
    let starts_word i =
      i > 0 && upper i
      && (((not (upper (i - 1))) && name.[i - 1] <> '_') || (i + 1 < n && not (upper (i + 1))))
    in
    let s = Buffer.create (n * 2) in
    String.iteri
      (fun i c ->
        if starts_word i then Buffer.add_char s '_';
        Buffer.add_char s (Char.lowercase_ascii c))
      name;
    let s = Buffer.contents s in
    let s = if List.mem s keywords then s ^ "_" else s in
    if not (identifier (fun c -> is_lower c || is_digit c || c = '_') s) then
      failwith @@ Printf.sprintf "%s: %S is not an OCaml identifier after snake_case" context name;
    s

  let module_name = String.capitalize_ascii
end

module Tag = struct
  type t = string

  let of_string ~context tag =
    if not (identifier (fun c -> is_lower c || is_upper c || is_digit c || c = '_') tag) then
      failwith @@ Printf.sprintf "%s: enum member %S is not a variant tag" context tag;
    if tag = "Unknown_value" then
      failwith @@ Printf.sprintf "%s: enum member %S collides with the generated one" context tag;
    tag
end

module Host_label = struct
  type t = string

  let of_string ~context s =
    if s = "" || not (String.for_all (fun c -> is_lower c || is_digit c || c = '-') s) then
      failwith @@ Printf.sprintf "%s: %S is not a host label" context s;
    s
end
