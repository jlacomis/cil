(* cabsvisit.ml *)
(* tree visitor and rewriter for cabs *)

open Cabs
open Trace
open Pretty
module E = Errormsg

(* basic interface for a visitor object *)

(* Different visiting actions. 'a will be instantiated with exp, instr, etc. *)
type 'a visitAction = 
    SkipChildren                        (* Do not visit the children. Return 
                                         * the node as it is *)
  | ChangeTo of 'a                      (* Replace the expression with the 
                                         * given one *)
  | DoChildren                          (* Continue with the children of this 
                                         * node. Rebuild the node on return 
                                         * if any of the children changes 
                                         * (use == test) *)
  | ChangeDoChildrenPost of 'a * ('a -> 'a) (* First consider that the entire 
                                          * exp is replaced by the first 
                                          * paramenter. Then continue with 
                                          * the children. On return rebuild 
                                          * the node if any of the children 
                                          * has changed and then apply the 
                                          * function on the node *)

type nameKind = 
    NVar                                (* Variable or function name *)
  | NField                              (* The name of a field *)
  | NType                               (* The name of a type *)

(* All visit methods are called in preorder! (but you can use 
 * ChangeDoChildrenPost to change the order) *)
class type cabsVisitor = object
  method vexpr: expression -> expression visitAction   (* expressions *)
  method vinitexpr: init_expression -> init_expression visitAction   
  method vstmt: statement -> statement list visitAction
  method vblock: block -> block visitAction
  method vvar: string -> string                  (* use of a variable 
                                                        * names *)
  method vdef: definition -> definition list visitAction
  method vtypespec: typeSpecifier -> typeSpecifier visitAction
  method vdecltype: decl_type -> decl_type visitAction

      (* For each declaration we call vname *)
  method vname: nameKind -> specifier -> name -> name visitAction
  method vspec: specifier -> specifier visitAction     (* specifier *)
  method vattr: attribute -> attribute list visitAction

  method vEnterScope: unit -> unit
  method vExitScope: unit -> unit
end
        
        (* a default visitor which does nothing to the tree *)
class nopCabsVisitor : cabsVisitor = object
  method vexpr (e:expression) = DoChildren
  method vinitexpr (e:init_expression) = DoChildren
  method vstmt (s: statement) = DoChildren
  method vblock (b: block) = DoChildren
  method vvar (s: string) = s
  method vdef (d: definition) = DoChildren
  method vtypespec (ts: typeSpecifier) = DoChildren
  method vdecltype (dt: decl_type) = DoChildren
  method vname k (s:specifier) (n: name) = DoChildren
  method vspec (s:specifier) = DoChildren
  method vattr (a: attribute) = DoChildren
      
  method vEnterScope () = ()
  method vExitScope () = ()
end
        
        (* Map but try not to copy the list unless necessary *)
let rec mapNoCopy (f: 'a -> 'a) = function
    [] -> []
  | (i :: resti) as li -> 
      let i' = f i in
      let resti' = mapNoCopy f resti in
      if i' != i || resti' != resti then i' :: resti' else li 
        
let rec mapNoCopyList (f: 'a -> 'a list) = function
    [] -> []
  | (i :: resti) as li -> 
      let il' = f i in
      let resti' = mapNoCopyList f resti in
      match il' with
        [i'] when i' == i && resti' == resti -> li
      | _ -> il' @ resti'
                     
let doVisit (vis: cabsVisitor)
    (startvisit: 'a -> 'a visitAction) 
    (children: cabsVisitor -> 'a -> 'a) 
    (node: 'a) : 'a = 
  let action = startvisit node in
  match action with
    SkipChildren -> node
  | ChangeTo node' -> node'
  | _ ->  
      let nodepre = match action with
        ChangeDoChildrenPost (node', _) -> node'
      | _ -> node
      in
      let nodepost = children vis nodepre in
      match action with
        ChangeDoChildrenPost (_, f) -> f nodepost
      | _ -> nodepost
            
(* A visitor for lists *)
let doVisitList (vis: cabsVisitor)
                (startvisit: 'a -> 'a list visitAction)
                (children: cabsVisitor -> 'a -> 'a)
                (node: 'a) : 'a list = 
  let action = startvisit node in
  match action with
    SkipChildren -> [node]
  | ChangeTo nodes' -> nodes'
  | _ -> 
      let nodespre = match action with
        ChangeDoChildrenPost (nodespre, _) -> nodespre
      | _ -> [node]
      in
      let nodespost = mapNoCopy (children vis) nodespre in
      match action with
        ChangeDoChildrenPost (_, f) -> f nodespost
      | _ -> nodespost

            
let rec visitCabsTypeSpecifier (vis: cabsVisitor) (ts: typeSpecifier) = 
  doVisit vis vis#vtypespec childrenTypeSpecifier ts
    
and childrenTypeSpecifier vis ts = 
  let childrenFieldGroup ((s, nel) as input) = 
    let s' = visitCabsSpecifier vis s in
    let doOneField ((n, eo) as input) = 
      let n' = visitCabsName vis NField s' n in
      let eo' = 
        match eo with
          None -> None
        | Some e -> let e' = visitCabsExpression vis e in
          if e' != e then Some e' else eo
      in
      if n' != n || eo' != eo then (n', eo') else input
    in
    let nel' = mapNoCopy doOneField nel in
    if s' != s || nel' != nel then (s', nel) else input
  in
  match ts with
    Tstruct (n, Some fg) -> 
      let fg' = mapNoCopy childrenFieldGroup fg in
      if fg' != fg then Tstruct( n, Some fg') else ts
  | Tunion (n, Some fg) -> 
      let fg' = mapNoCopy childrenFieldGroup fg in
      if fg' != fg then Tunion( n, Some fg') else ts
  | Tenum (n, Some ei) -> 
      let doOneEnumItem ((s, e) as ei) = 
        let e' = visitCabsExpression vis e in
        if e' != e then (s, e') else ei
      in
      vis#vEnterScope ();
      let ei' = mapNoCopy doOneEnumItem ei in
      vis#vExitScope();
      if ei' != ei then Tenum( n, Some ei') else ts
  | TtypeofE e -> 
      let e' = visitCabsExpression vis e in   
      if e' != e then TtypeofE e' else ts
  | TtypeofT (s, dt) -> 
      let s' = visitCabsSpecifier vis s in
      let dt' = visitCabsDeclType vis dt in
      if s != s' || dt != dt' then TtypeofT (s', dt') else ts
  | ts -> ts
        
and childrenSpecElem (vis: cabsVisitor) (se: spec_elem) : spec_elem = 
  match se with
    SpecTypedef | SpecInline | SpecStorage _ | SpecPattern _ -> se
  | SpecAttr a -> begin
      let al' = visitCabsAttribute vis a in
      match al' with
        [a''] when a'' == a -> se
      | [a''] -> SpecAttr a''
      | _ -> E.s (E.unimp "childrenSpecElem: visitCabsAttribute returned a list")
  end
  | SpecType ts -> 
      let ts' = visitCabsTypeSpecifier vis ts in
      if ts' != ts then SpecType ts' else se
        
and visitCabsSpecifier (vis: cabsVisitor) (s: specifier) : specifier = 
  doVisit vis vis#vspec childrenSpec s
and childrenSpec vis s = mapNoCopy (childrenSpecElem vis) s 
    

and visitCabsDeclType vis (dt: decl_type) : decl_type = 
  doVisit vis vis#vdecltype childrenDeclType dt
and childrenDeclType vis dt = 
  match dt with
    JUSTBASE -> dt
  | PARENTYPE (prea, dt1, posta) -> 
      let prea' = mapNoCopyList (visitCabsAttribute vis)  prea in
      let dt1' = visitCabsDeclType vis dt1 in
      let posta'= mapNoCopyList (visitCabsAttribute vis)  posta in
      if prea' != prea || dt1' != dt1 || posta' != posta then 
        PARENTYPE (prea', dt1', posta') else dt
  | ARRAY (dt1, e) -> 
      let dt1' = visitCabsDeclType vis dt1 in
      let e'= visitCabsExpression vis e in
      if dt1' != dt1 || e' != e then ARRAY(dt1', e') else dt
  | PTR (al, dt1) -> 
      let al' = mapNoCopy (childrenAttribute vis) al in
      let dt1' = visitCabsDeclType vis dt1 in
      if al' != al || dt1' != dt1 then PTR(al', dt1') else dt
  | PROTO (dt1, snl, b) -> 
      let dt1' = visitCabsDeclType vis dt1 in
      let _ = vis#vEnterScope () in
      let snl' = mapNoCopy (childrenSingleName vis) snl in
      let _ = vis#vExitScope () in
      if dt1' != dt1 || snl' != snl then PROTO(dt1', snl', b) else dt
         

and childrenNameGroup vis (kind: nameKind) ((s, nl) as input) = 
  let s' = visitCabsSpecifier vis s in
  let nl' = mapNoCopy (visitCabsName vis kind s') nl in
  if s' != s || nl' != nl then (s', nl') else input

    
and childrenInitNameGroup vis ((s, inl) as input) = 
  let s' = visitCabsSpecifier vis s in
  let inl' = mapNoCopy (childrenInitName vis s') inl in
  if s' != s || inl' != inl then (s', inl') else input
    
and visitCabsName vis (k: nameKind) (s: specifier) (n: name) : name = 
  doVisit vis (vis#vname k s) (childrenName s) n
and childrenName (s: specifier) vis (n: name) : name = 
  let (sn, dt, al) = n in
  let dt' = visitCabsDeclType vis dt in
  let al' = mapNoCopy (childrenAttribute vis) al in
  if dt' != dt || al' != al then (sn, dt', al') else n
    
and childrenInitName vis (s: specifier) (inn: init_name) : init_name = 
  let (n, ie) = inn in
  let n' = visitCabsName vis NVar s n in
  let ie' = visitCabsInitExpression vis ie in
  if n' != n || ie' != ie then (n', ie') else inn
    
and childrenSingleName vis (sn: single_name) : single_name =
  let s, n = sn in
  let s' = visitCabsSpecifier vis s in
  let n' = visitCabsName vis NVar s' n in
  if s' != s || n' != n then (s', n') else sn
    
    
and visitCabsDefinition vis (d: definition) : definition list = 
  doVisitList vis vis#vdef childrenDefinition d
and childrenDefinition vis d = 
  match d with 
    FUNDEF (sn, b, l) -> 
      let sn' = childrenSingleName vis sn in
      let b' = visitCabsBlock vis b in
      if sn' != sn || b' != b then FUNDEF (sn', b', l) else d
  | DECDEF ((s, inl), l) -> 
      let s' = visitCabsSpecifier vis s in
      let inl' = mapNoCopy (childrenInitName vis s') inl in
      if s' != s || inl' != inl then DECDEF ((s', inl'), l) else d
  | TYPEDEF (ng, l) -> 
      let ng' = childrenNameGroup vis NType ng in
      if ng' != ng then TYPEDEF (ng', l) else d
  | ONLYTYPEDEF (s, l) -> 
      let s' = visitCabsSpecifier vis s in
      if s' != s then ONLYTYPEDEF (s', l) else d
  | GLOBASM _ -> d
  | PRAGMA (e, l) -> 
      let e' = visitCabsExpression vis e in
      if e' != e then PRAGMA (e', l) else d
  | TRANSFORMER _ -> d
  | EXPRTRANSFORMER _ -> d
        
and visitCabsBlock vis (b: block) : block = 
  doVisit vis vis#vblock childrenBlock b

and childrenBlock vis (b: block) : block = 
  let _ = vis#vEnterScope () in
  let battrs' = mapNoCopyList (visitCabsAttribute vis) b.battrs in
  let bdefs' = mapNoCopyList (visitCabsDefinition vis) b.bdefs in
  let bstmts' = mapNoCopyList (visitCabsStatement vis) b.bstmts in
  let _ = vis#vExitScope () in
  if battrs' != b.battrs || bdefs' != b.bdefs || bstmts' != b.bstmts then 
    { blabels = b.blabels; battrs = battrs'; bdefs = bdefs'; bstmts = bstmts' }
  else
    b
    
and visitCabsStatement vis (s: statement) : statement list = 
  doVisitList vis vis#vstmt childrenStatement s
and childrenStatement vis s = 
  let ve e = visitCabsExpression vis e in
  let vs l s = 
    match visitCabsStatement vis s with
      [s'] -> s'
    | sl -> BLOCK ({blabels = []; battrs = []; bdefs = []; bstmts = sl }, l)
  in
  match s with
    NOP _ -> s
  | COMPUTATION (e, l) ->
      let e' = ve e in
      if e' != e then COMPUTATION (e', l) else s
  | BLOCK (b, l) -> 
      let b' = visitCabsBlock vis b in
      if b' != b then BLOCK (b', l) else s
  | SEQUENCE (s1, s2, l) -> 
      let s1' = vs l s1 in
      let s2' = vs l s2 in
      if s1' != s1 || s2' != s2 then SEQUENCE (s1', s2', l) else s
  | IF (e, s1, s2, l) -> 
      let e' = ve e in
      let s1' = vs l s1 in
      let s2' = vs l s2 in
      if e' != e || s1' != s1 || s2' != s2 then IF (e', s1', s2', l) else s
  | WHILE (e, s1, l) -> 
      let e' = ve e in
      let s1' = vs l s1 in
      if e' != e || s1' != s1 then WHILE (e', s1', l) else s
  | DOWHILE (e, s1, l) -> 
      let e' = ve e in
      let s1' = vs l s1 in
      if e' != e || s1' != s1 then DOWHILE (e', s1', l) else s
  | FOR (e1, e2, e3, s4, l) -> 
      let e1' = ve e1 in
      let e2' = ve e2 in
      let e3' = ve e3 in
      let s4' = vs l s4 in
      if e1' != e1 || e2' != e2 || e3' != e3 || s4' != s4 
      then FOR (e1', e2', e3', s4', l) else s
  | BREAK _ | CONTINUE _ | GOTO _ -> s
  | RETURN (e, l) ->
      let e' = ve e in
      if e' != e then RETURN (e', l) else s
  | SWITCH (e, s1, l) -> 
      let e' = ve e in
      let s1' = vs l s1 in
      if e' != e || s1' != s1 then SWITCH (e', s1', l) else s
  | CASE (e, s1, l) -> 
      let e' = ve e in
      let s1' = vs l s1 in
      if e' != e || s1' != s1 then CASE (e', s1', l) else s
  | CASERANGE (e1, e2, s3, l) -> 
      let e1' = ve e1 in
      let e2' = ve e2 in
      let s3' = vs l s3 in
      if e1' != e1 || e2' != e2 || s3' != s3 then 
        CASERANGE (e1', e2', s3', l) else s
  | DEFAULT (s1, l) ->
      let s1' = vs l s1 in
      if s1' != s1 then DEFAULT (s1', l) else s
  | LABEL (n, s1, l) ->
      let s1' = vs l s1 in
      if s1' != s1 then LABEL (n, s1', l) else s
  | COMPGOTO (e, l) -> 
      let e' = ve e in
      if e' != e then COMPGOTO (e', l) else s
  | ASM (sl, b, inl, outl, clobs, l) -> 
      let childrenStringExp ((s, e) as input) = 
        let e' = ve e in
        if e' != e then (s, e') else input
      in
      let inl' = mapNoCopy childrenStringExp inl in
      let outl' = mapNoCopy childrenStringExp outl in
      if inl' != inl || outl' != outl then 
        ASM (sl, b, inl', outl', clobs, l) else s
          
and visitCabsExpression vis (e: expression) : expression = 
  doVisit vis vis#vexpr childrenExpression e
and childrenExpression vis e = 
  let ve e = visitCabsExpression vis e in
  match e with 
    NOTHING | LABELADDR _ -> e
  | UNARY (uo, e1) -> 
      let e1' = ve e1 in
      if e1' != e1 then UNARY (uo, e1') else e
  | BINARY (bo, e1, e2) -> 
      let e1' = ve e1 in
      let e2' = ve e2 in
      if e1' != e1 || e2' != e2 then BINARY (bo, e1', e2') else e
  | QUESTION (e1, e2, e3) -> 
      let e1' = ve e1 in
      let e2' = ve e2 in
      let e3' = ve e3 in
      if e1' != e1 || e2' != e2 || e3' != e3 then 
        QUESTION (e1', e2', e3') else e
  | CAST ((s, dt), ie) -> 
      let s' = visitCabsSpecifier vis s in
      let dt' = visitCabsDeclType vis dt in
      let ie' = visitCabsInitExpression vis ie in
      if s' != s || dt' != dt || ie' != ie then CAST ((s', dt'), ie') else e
  | CALL (f, el) -> 
      let f' = ve f in
      let el' = mapNoCopy ve el in
      if f' != f || el' != el then CALL (f', el') else e
  | COMMA el -> 
      let el' = mapNoCopy ve el in
      if el' != el then COMMA (el') else e
  | CONSTANT _ -> e
  | VARIABLE s -> 
      let s' = vis#vvar s in
      if s' != s then VARIABLE s' else e
  | EXPR_SIZEOF (e1) -> 
      let e1' = ve e1 in
      if e1' != e1 then EXPR_SIZEOF (e1') else e
  | TYPE_SIZEOF (s, dt) -> 
      let s' = visitCabsSpecifier vis s in
      let dt' = visitCabsDeclType vis dt in
      if s' != s || dt' != dt then TYPE_SIZEOF (s' ,dt') else e
  | EXPR_ALIGNOF (e1) -> 
      let e1' = ve e1 in
      if e1' != e1 then EXPR_ALIGNOF (e1') else e
  | TYPE_ALIGNOF (s, dt) -> 
      let s' = visitCabsSpecifier vis s in
      let dt' = visitCabsDeclType vis dt in
      if s' != s || dt' != dt then TYPE_ALIGNOF (s' ,dt') else e
  | INDEX (e1, e2) -> 
      let e1' = ve e1 in
      let e2' = ve e2 in
      if e1' != e1 || e2' != e2 then INDEX (e1', e2') else e
  | MEMBEROF (e1, n) -> 
      let e1' = ve e1 in
      if e1' != e1 then MEMBEROF (e1', n) else e
  | MEMBEROFPTR (e1, n) -> 
      let e1' = ve e1 in
      if e1' != e1 then MEMBEROFPTR (e1', n) else e
  | GNU_BODY b -> 
      let b' = visitCabsBlock vis b in
      if b' != b then GNU_BODY b' else e
  | EXPR_PATTERN _ -> e
        
and visitCabsInitExpression vis (ie: init_expression) : init_expression = 
  doVisit vis vis#vinitexpr childrenInitExpression ie
and childrenInitExpression vis ie = 
  let rec childrenInitWhat iw = 
    match iw with
      NEXT_INIT -> iw
    | INFIELD_INIT (n, iw1) -> 
        let iw1' = childrenInitWhat iw1 in
        if iw1' != iw1 then INFIELD_INIT (n, iw1') else iw
    | ATINDEX_INIT (e, iw1) -> 
        let e' = visitCabsExpression vis e in
        let iw1' = childrenInitWhat iw1 in
        if e' != e || iw1' != iw1 then ATINDEX_INIT (e', iw1') else iw
    | ATINDEXRANGE_INIT (e1, e2) -> 
        let e1' = visitCabsExpression vis e1 in
        let e2' = visitCabsExpression vis e2 in
        if e1' != e1 || e2' != e2 then ATINDEXRANGE_INIT (e1, e2) else iw
  in
  match ie with 
    NO_INIT -> ie
  | SINGLE_INIT e -> 
      let e' = visitCabsExpression vis e in
      if e' != e then SINGLE_INIT e' else ie
  | COMPOUND_INIT il -> 
      let childrenOne ((iw, ie) as input) = 
        let iw' = childrenInitWhat iw in
        let ie' = visitCabsInitExpression vis ie in
        if iw' != iw || ie' != ie then (iw', ie') else input
      in
      let il' = mapNoCopy childrenOne il in
      if il' != il then COMPOUND_INIT il' else ie
        

and visitCabsAttribute vis (a: attribute) : attribute list = 
  doVisitList vis vis#vattr childrenAttribute a

and childrenAttribute vis ((n, el) as input) = 
  let el' = mapNoCopy (visitCabsExpression vis) el in
  if el' != el then (n, el') else input
    
and visitCabsAttributes vis (al: attribute list) : attribute list = 
  mapNoCopyList (visitCabsAttribute vis) al

let visitCabsFile (vis: cabsVisitor) (f: file) : file =  
  mapNoCopyList (visitCabsDefinition vis) f

    (* end of file *)
    
