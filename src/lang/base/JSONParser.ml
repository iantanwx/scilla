(*
  This file is part of scilla.

  Copyright (c) 2018 - present Zilliqa Research Pvt. Ltd.
  
  scilla is free software: you can redistribute it and/or modify it under the
  terms of the GNU General Public License as published by the Free Software
  Foundation, either version 3 of the License, or (at your option) any later
  version.
 
  scilla is distributed in the hope that it will be useful, but WITHOUT ANY
  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
  A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
 
  You should have received a copy of the GNU General Public License along with
  scilla.  If not, see <http://www.gnu.org/licenses/>.
*)

(* A fast JSON parser for states that performs no validations. *)


open Yojson
open Syntax
open ErrorUtils
open ParserUtil
open Core
open PrimTypes
open TypeUtil
open Datatypes
open Utils

module JSONTypeUtilities = TypeUtilities (ParserRep) (ParserRep)
open JSONTypeUtilities

(*************************************)
(***** Exception and wrappers ********)
(*************************************)

let member_exn m j =
  let open Basic.Util in
  let v = member m j in
  match v with
  | `Null -> raise (mk_invalid_json ("Member '" ^ m ^ "' not found in json"))
  | j -> j

let constr_pattern_arg_types_exn dt cname =
  match constr_pattern_arg_types dt cname with
  | Error emsg -> raise (Invalid_json (emsg))
  | Ok s -> s

let lookup_adt_name_exn name =
  match DataTypeDictionary.lookup_name name with
  | Error emsg -> raise (Invalid_json emsg)
  | Ok s -> s

(*************************************)
(******** Parser Generator ***********)
(*************************************)

(* Generate a parser. *)
let gen_parser (t' : typ) : (Basic.json -> literal) =
  let open Basic in
    let rec recurser t adt_parsers =
    match t with
    | PrimType _ ->
      (match t with
      | x when x = string_typ -> (fun j -> StringLit (Util.to_string j))
      | x when x = bnum_typ -> (fun j -> BNum (Util.to_string j))
      | x when x = bystr_typ -> (fun j -> ByStr (String.lowercase (Util.to_string j)))
      | x when is_bystrx_type x ->
        let w = bystrx_width x in
        (match w with
        | None -> raise (mk_invalid_json "Invalid ByStrX type")
        | Some w' -> (fun j -> ByStrX (w', String.lowercase (Util.to_string j)))
        )
      | x when x = int32_typ -> (fun j -> IntLit(Int32L (Int32.of_string (Util.to_string j))))
      | x when x = int64_typ -> (fun j -> IntLit(Int64L (Int64.of_string (Util.to_string j))))
      | x when x = int128_typ -> (fun j -> IntLit(Int128L (Stdint.Int128.of_string (Util.to_string j))))
      | x when x = int256_typ -> (fun j -> IntLit(Int256L (Integer256.Int256.of_string (Util.to_string j))))
      | x when x = uint32_typ -> (fun j -> UintLit(Uint32L (Stdint.Uint32.of_string (Util.to_string j))))
      | x when x = uint64_typ -> (fun j -> UintLit(Uint64L (Stdint.Uint64.of_string (Util.to_string j))))
      | x when x = uint128_typ -> (fun j -> UintLit(Uint128L (Stdint.Uint128.of_string (Util.to_string j))))
      | x when x = uint256_typ -> (fun j -> UintLit(Uint256L (Integer256.Uint256.of_string (Util.to_string j))))
      | _ -> raise (mk_invalid_json "Invalid primitive type")
      )
    | MapType (kt, vt) ->
      let kp = recurser kt adt_parsers in
      let vp = recurser vt adt_parsers in
      (fun j ->
        match j with
        | `List jlist ->
          let m = Caml.Hashtbl.create (List.length jlist) in
          List.iter jlist ~f:(fun first ->
            let kjson = member_exn "key" first in
            let keylit = kp kjson in
            let vjson = member_exn "val" first in
            let vallit = vp vjson in
            Caml.Hashtbl.replace m keylit vallit
          );
          Map ((kt, vt), m)
        | _ -> raise (mk_invalid_json "Invalid map in JSON")
      )
    | ADT (name, tlist) ->
      let a = lookup_adt_name_exn name in
      (* Build a parser for each constructor of this ADT. *)
      (* TODO: Use an efficient dictionary. Custom ADTs _can_ have many constructors. *)
      let cn_parsers adt_parsers =
        List.fold a.tconstr ~init:(AssocDictionary.make_dict()) ~f:(fun maps cn ->
          let tmap = constr_pattern_arg_types_exn t cn.cname in
          let arg_parsers = List.map tmap ~f:(fun t ->
            (match AssocDictionary.lookup (pp_typ t) adt_parsers with
            | Some arg_parser -> arg_parser
            | None -> recurser t adt_parsers
            )
          ) in
          let parser j =
            match j with
            | `Assoc _ ->
              let arguments = member_exn "arguments" j |> Util.to_list in
              if List.length tmap <> List.length arguments
              then raise (mk_invalid_json "Invalid arguments to ADT in JSON") else
              let arg_lits = List.map2_exn arg_parsers arguments ~f:(fun p a -> p a) in
              ADTValue(cn.cname, tlist, arg_lits)
            | `List vli ->
              (* We make an exception for Lists, allowing them to be stored flatly. *)
              if name <> "List" then
                raise (mk_invalid_json "ADT value is a JSON array, but type is not List")
              else
                let eparser = List.nth_exn arg_parsers 0 in
                let etyp = List.nth_exn tmap 0 in
                List.fold_right vli
                  ~f:(fun vl acc -> (ADTValue("Cons", [etyp], [(eparser vl);acc])))
                  ~init:(ADTValue("Nil", [etyp], []))
            | _ -> raise (mk_invalid_json "Invalid ADT in JSON")
          in
          AssocDictionary.insert cn.cname parser maps
        ) in
      let adt_parser cn_parsers j =
        let cn = match j with
          | `Assoc _ ->
              (member_exn "constructor" j |> Util.to_string)
          | `List _ -> "Cons" (* for efficiency, Lists can be stored flatly. *)
          | _ -> raise (mk_invalid_json "Invalid construct in ADT JSON")
        in
        match AssocDictionary.lookup cn cn_parsers with
        | Some parser -> parser j
        | None -> raise (mk_invalid_json ("Unknown constructor " ^ cn ^ " in ADT JSON"))
      in
      let rec adt_parser_fix j =
        let adt_parsers' = (AssocDictionary.update (pp_typ t) adt_parser_fix adt_parsers) in
        let cn_parsers' = cn_parsers adt_parsers' in
        adt_parser cn_parsers' j
      in
      adt_parser_fix
    | _ -> raise (mk_invalid_json "Invalid type")
  in
  recurser t' (AssocDictionary.make_dict())

let parse_json t j =
  (gen_parser t) j
