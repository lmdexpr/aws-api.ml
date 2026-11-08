(** Non-empty lists. *)

type 'a t = 'a * 'a list

let of_list = function [] -> None | x :: xs -> Some (x, xs)
let to_list (x, xs) = x :: xs
let map f (x, xs) = f x, List.map f xs
