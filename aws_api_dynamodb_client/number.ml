type t = { negative : bool; digits : string; exponent : int }

let zero = { negative = false; digits = "0"; exponent = 0 }
let is_digit c = c >= '0' && c <= '9'
let all_digits s = String.for_all is_digit s

(* Split [s] into sign, integer digits, fraction digits and exponent text. *)
let split s =
  let negative, s =
    match s with
    | "" -> false, s
    | _ when s.[0] = '-' -> true, String.drop_first 1 s
    | _ when s.[0] = '+' -> false, String.drop_first 1 s
    | _ -> false, s
  in
  let mantissa, exponent =
    match String.split_first ~sep:"e" s, String.split_first ~sep:"E" s with
    | Some (m, e), None | None, Some (m, e) -> m, Some e
    | None, None -> s, None
    | Some _, Some _ -> s, Some ""
  in
  let whole, fraction =
    match String.split_first ~sep:"." mantissa with
    | Some (whole, fraction) -> whole, fraction
    | None -> mantissa, ""
  in
  negative, whole, fraction, exponent

let exponent_of_string = function
  | None -> Some 0
  | Some e ->
    let digits =
      if String.starts_with ~prefix:"+" e || String.starts_with ~prefix:"-" e then
        String.drop_first 1 e
      else
        e
    in
    (* Leading zeros do not count against the 6-digit bound. *)
    let significant = String.drop_first_while (( = ) '0') digits in
    if digits = "" || String.length significant > 6 || not (all_digits digits) then
      None
    else
      int_of_string_opt e

let trim_zeros digits =
  let is_zero = ( = ) '0' in
  let trimmed = digits |> String.drop_first_while is_zero |> String.drop_last_while is_zero in
  if trimmed = "" then
    None
  else
    Some (String.length (String.take_first_while is_zero digits), trimmed)

let of_string s =
  let negative, whole, fraction, exponent = split s in
  match exponent_of_string exponent with
  | None -> Error "invalid DynamoDB decimal"
  | Some _ when (whole = "" && fraction = "") || not (all_digits whole && all_digits fraction) ->
    Error "invalid DynamoDB decimal"
  | Some e -> (
    match trim_zeros (whole ^ fraction) with
    | None -> Ok zero
    | Some (first, digits) ->
      let precision = String.length digits in
      (* Position of the last kept digit relative to the decimal point. *)
      let exponent = e + String.length whole - (first + precision) in
      let adjusted = exponent + precision - 1 in
      if precision > 38 || adjusted < -130 || adjusted > 125 then
        Error "number exceeds DynamoDB precision or range"
      else
        Ok { negative; digits; exponent })

let of_string_exn s = match of_string s with Ok n -> n | Error e -> invalid_arg e

let to_string { negative; digits; exponent } =
  let point = String.length digits + exponent in
  let magnitude =
    if exponent >= 0 && point <= 38 then
      digits ^ String.make exponent '0'
    else if exponent < 0 && point > 0 then
      let whole, fraction = String.cut_first point digits in
      whole ^ "." ^ fraction
    else if point <= 0 && point >= -5 then
      "0." ^ String.make (-point) '0' ^ digits
    else
      digits ^ "e" ^ string_of_int exponent
  in
  (if negative then "-" else "") ^ magnitude

let of_int i = of_string_exn (string_of_int i)

let to_integer_string { negative; digits; exponent } =
  if exponent < 0 then
    Error "number is not an integer"
  else
    Ok ((if negative then "-" else "") ^ digits ^ String.make exponent '0')

let to_int n =
  Result.bind (to_integer_string n) @@ fun s ->
  Option.to_result ~none:"integer out of range" (int_of_string_opt s)

let of_float f =
  if not (Float.is_finite f) then
    Error "non-finite float"
  else
    let short = Printf.sprintf "%.15g" f in
    of_string (if Float.equal (float_of_string short) f then short else Printf.sprintf "%.17g" f)

let to_float n = float_of_string (to_string n)

let compare a b =
  match a.digits = "0", b.digits = "0" with
  | true, true -> 0
  | true, false -> if b.negative then 1 else -1
  | false, true -> if a.negative then -1 else 1
  | false, false when a.negative <> b.negative -> if a.negative then -1 else 1
  | false, false ->
    let point n = String.length n.digits + n.exponent in
    let magnitude =
      match Int.compare (point a) (point b) with
      | 0 ->
        let width = max (String.length a.digits) (String.length b.digits) in
        let pad s = s ^ String.make (width - String.length s) '0' in
        String.compare (pad a.digits) (pad b.digits)
      | c -> c
    in
    if a.negative then -magnitude else magnitude

let equal a b = compare a b = 0
