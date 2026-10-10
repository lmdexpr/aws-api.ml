module M = Value.String_map

type t = Value.t M.t

let empty = M.empty
let singleton = M.singleton
let add = M.add
let remove = M.remove
let find_opt = M.find_opt
let mem = M.mem
let is_empty = M.is_empty
let equal = M.equal Value.equal
let to_list = M.to_list
let of_list = M.of_list
