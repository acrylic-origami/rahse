{-# LANGUAGE NamedFieldPuns, LambdaCase, TupleSections, MultiWayIf, DeriveDataTypeable #-}
module Ra (
  pat_match,
  reduce_deep,
  reduce
) where

import GHC
import DataCon ( dataConName )
import TyCon ( tyConName )
import ConLike ( ConLike (..) )
import Name ( mkSystemName, nameOccName )
import OccName ( mkVarOcc, occNameString )
import Unique ( mkVarOccUnique )
import FastString ( mkFastString ) -- for WildPat synthesis
import SrcLoc ( noSrcSpan )
import Var ( mkLocalVar ) -- for WildPat synthesis
import IdInfo ( vanillaIdInfo, IdDetails(VanillaId) ) -- for WildPat synthesis

import Data.List ( elemIndex )
import Data.Bool ( bool )
import Data.Coerce ( coerce )
import Data.Char ( isLower )
import Data.Tuple ( swap )
import Data.Tuple.Extra ( first, second, (***), (&&&), both )
import Data.Function ( (&) )
import Data.Maybe ( catMaybes, fromMaybe, maybeToList, isNothing )
import Data.Data ( toConstr, Data(..), Typeable(..) )
import Data.Generics ( everywhereBut, mkQ, mkT, extQ )
import Data.Generics.Extra ( constr_ppr, everywhereWithContextBut, extQT, mkQT )
import Data.Semigroup ( (<>) )
import Data.Monoid ( mempty, mconcat )
import Control.Monad ( guard, foldM )
import Control.Applicative ( (<|>), liftA2 )
import Control.Exception ( assert )

import Data.Map.Strict ( Map(..), unionsWith, unions, unionWith, union, singleton, (!?), (!), foldlWithKey, foldrWithKey, keys, mapWithKey, assocs)
import qualified Data.Map.Strict as M ( null, member, empty, insert, map, elems )
import Data.Set ( Set(..), intersection, difference, (\\) )
import qualified Data.Set as S ( fromList, member, insert )
-- import qualified Data.Set as S ( insert )

import qualified Ra.Refs as Refs
import {-# SOURCE #-} Ra.GHC
import Ra.Lang
import Ra.Extra
import Ra.Lang.Extra
import Ra.Refs ( write_funs, read_funs )

pat_match_zip ::
  [Pat GhcTc]
  -> [[SymApp]]
  -> Maybe (Map Id [SymApp])
pat_match_zip pats args =
  foldM (
      curry $ uncurry fmap . (
          unionWith (++)
          *** uncurry ((mconcat.) . map . pat_match_one) -- Maybe (Map Id [SymApp]), with OR mechanics: if one arg alternative fails, the others will try to take its place
        )
    ) mempty $ zip pats args

pat_match_one ::
  Pat GhcTc
  -> SymApp
  -> Maybe (Map Id [SymApp])
pat_match_one pat sa =
  case pat of
    ---------------------------------
    -- *** UNWRAPPING PATTERNS *** --
    ---------------------------------
    WildPat ty -> Just mempty -- TODO check if this is the right [write, haha] behavior
      
    -- Wrappers --
    LazyPat _ (L _ pat) -> pat_match_one pat sa
    ParPat _ (L _ pat) -> pat_match_one pat sa
    BangPat _ (L _ pat) -> pat_match_one pat sa
    -- SigPatOut (L _ pat) _ -> pat_match_one pat sa
    
    -- Bases --
    VarPat _ (L _ v) -> Just $ singleton v [sa]
    LitPat _ _ -> Just mempty -- no new name bindings
    NPat _ _ _ _ -> Just mempty
    
    -- Containers --
    ListPat _ pats -> undefined -- need to use pat_match_zip
    -- ListPat _ pats -> unionsWith (++) $ map (\(L _ pat') -> pat_match_one pat' sa) pats -- encodes the logic that all elements of a list might be part of the pattern regardless of order
    AsPat _ (L _ bound) (L _ pat') -> -- error "At patterns (@) aren't yet supported."
      let matches = pat_match_one pat' sa
      in (unionWith (++) $ singleton bound [sa]) <$> matches -- note: `at` patterns can't be formally supported, because they might contain sub-patterns that need to hold. They also violate the invariant that "held" pattern targets have a read operation on their surface. However, since this only makes the test _less sensitive_, we'll try as hard as we can and just miss some things later.
        -- TODO test this: the outer binding and inner pattern are related: the inner pattern must succeed for the outer one to as well.
        
    -------------------------------
    -- *** MATCHING PATTERNS *** --
    -------------------------------
    TuplePat _ pats _ | TupleConstr _ <- sa_sym sa -> pat_match_zip (map unLoc pats) (sa_args sa)
                      | otherwise -> mempty -- error $ "Argument on explicit tuple. Perhaps a tuple section, which isn't supported yet. PPR:\n" ++ (ppr_sa ppr_unsafe sa)
                      
    ConPatOut{ pat_con = L _ (RealDataCon pat_con'), pat_args = d_pat_args } -> case d_pat_args of
      PrefixCon pats | (Sym sym) <- sa_sym sa
                     , (L _ (HsConLikeOut _ (RealDataCon con)), args'') <- deapp sym
                     , dataConName con == dataConName pat_con' -- TEMP disable name matching on constructor patterns, to allow symbols to always be bound to everything
                     -> let flat_args = ((map (\arg'' -> [sa {
                        sa_sym = Sym arg'',
                        sa_args = []
                      }]) args'') ++ sa_args sa) -- STACK good: this decomposition is not a function application so the stack stays the same
                          -- NOTE this is the distributivity of `consumers` onto subdata of a datatype, as well as the stack
                            in pat_match_zip (map unLoc pats) flat_args
                     | otherwise -> Nothing
    
      RecCon _ -> error "Record syntax yet to be implemented"
      
    _ -> error $ constr_ppr pat

newtype Q a b = Q (Maybe (a, b)) deriving (Data, Typeable)
unQ (Q z) = z

pat_match_many :: [Bind] -> Map Id [SymApp]
pat_match_many = unionsWith (++) . map (unionsWith (++)) . map (catMaybes . uncurry map . first pat_match_one)

pat_match :: [Bind] -> PatMatchSyms
pat_match binds = 
  let sub :: Map Id [SymApp] -> SymApp -> ReduceSyms
      sub t sa = -- assumes incoming term is a normal form
        let m_next_syms :: Maybe ReduceSyms
            m_next_syms = case sa_sym sa of
              Sym (L _ (HsVar _ (L _ v))) -> if not $ v `elem` (var_ref_tail $ sa_stack sa)
                then (
                      mconcat
                      -- . map (\rs' ->
                      --     let rss' = map (sub t) (rs_syms rs')
                      --     in map (uncurry (id )) (zip rss' (rs_syms rs')))
                      . map (\sa' ->
                          reduce_deep $ sa' {
                            sa_stack = mapSB ((VarRefFrame v):) (sa_stack sa'),
                            sa_args = (sa_args sa') <> (sa_args sa)
                          }
                        )
                    )
                  <$> (t !? v)
                else Nothing
              _ -> Nothing
        in fromMaybe mempty m_next_syms
      
      iterant :: PatMatchSyms -> (Bool, PatMatchSyms)
      iterant pms =
        -- BOOKMARK not working becuase of effed ordering of write substitution: should pass in PatMatchSyms and use the binds within the SymTable within that, so we can also substitute on writes
        let f0 :: Data b => b -> Q ReduceSyms b
            f0 b = Q $ Just (mempty, b)
            next_table = pat_match_many (stbl_binds $ pms_syms pms) -- even if all the matches failed, we might've made new writes which might make some matches succeed
            binder = everywhereWithContextBut (<>) (
                  unQ . (
                      f0
                        `mkQT` (Q . Just . (mconcat *** concat) . unzip . map ((fst &&& uncurry list_alt . (rs_syms *** pure)) . (sub next_table &&& id)) :: [SymApp] -> Q ReduceSyms [SymApp])
                        `extQT` (const (Q Nothing) :: Stack -> Q ReduceSyms Stack)
                    )
              ) mempty
            (next_rs, next_pms) = binder pms
        in (
            null $ rs_syms next_rs,
            next_pms {
              pms_writes = rs_writes next_rs <> pms_writes next_pms
            }
          )
      
      (rs0, binds0) = first mconcat $ unzip $ map ((\(pat, rs) -> (rs, (pat, rs_syms rs))) . second (mconcat . map reduce_deep)) binds -- [(Pat, ReduceSyms)] => [(ReduceSyms, (Pat, [SymApp]))] => ([ReduceSyms], [(Pat, SymApp)])
      (_, pmsn) = until fst (iterant . snd) (False, PatMatchSyms {
            pms_writes = rs_writes rs0,
            pms_syms = mempty {
              stbl_binds = binds0
            }
          })
    in pmsn {
      pms_syms = (pms_syms pmsn) {
        stbl_table = pat_match_many (stbl_binds $ pms_syms pmsn)
      }
    }

reduce :: ReduceSyms -> (Int, ReduceSyms)
reduce syms0 =
  let expand_reads :: Writes -> SymApp -> ReduceSyms
      expand_reads ws sa =
        let m_next_args = map (map (\sa' ->
                lift_rs_syms2 list_alt (expand_reads ws sa') (mempty { rs_syms = [sa'] })
              )) (sa_args sa)
            next_argd_sym -- | all null m_next_args = []
                          -- | otherwise =
                          = mempty { rs_syms = [sa {
                             sa_args = map (concatMap rs_syms) m_next_args
                           }] }
            expanded = mconcat $ case sa_sym sa of
              Sym (L _ (HsVar _ v)) -> case varString $ unLoc v of
                "newEmptyMVar" -> map (expand_reads ws) $ concatMap snd $ filter ((elem sa) . fst) ws -- by only taking `w_sym`, encode the law that write threads are not generally the threads that read (obvious saying it out loud, but it does _look_ like we're losing information here)
                "readMVar" | length m_next_args > 0 -> head m_next_args -- list of pipes from the first arg
                _ -> []
              _ -> []
        in (((mconcat $ mconcat m_next_args) { rs_syms = mempty })<>) 
          $ mconcat $ map reduce_deep 
          $ rs_syms $ lift_rs_syms2 list_alt expanded next_argd_sym -- a bunch of null handling that looks like a mess because it is
        -- STACK good: relies on the pipe stack being correct
          
      
      iterant :: ReduceSyms -> (Bool, ReduceSyms)
      iterant rs =
        let update_stack sa =
              let (next_pms', next_stack) = (mconcat *** SB) $ unzip $ map (\case
                      af@(AppFrame { af_syms }) ->
                        let (next_rs', next_binds) = (first mconcat) $ unzip $ map ((snd &&& second rs_syms) . second (mconcat . map (expand_reads (rs_writes rs)))) (stbl_binds af_syms)
                            next_pms'' = pat_match next_binds
                        in (next_pms'' {
                            pms_writes = pms_writes next_pms'' <> rs_writes next_rs'
                          }, af {
                            af_syms = pms_syms next_pms''
                          })
                      v -> (mempty, v)
                    ) (unSB $ sa_stack sa)
                  (next_args_pms, next_args) = unzip $ map (unzip . map update_stack) (sa_args sa)
              in (next_pms' <> (mconcat $ mconcat next_args_pms), sa {
                sa_stack = next_stack,
                sa_args = next_args
              })
              
            (next_pms, next_rs) = (mconcat *** mconcat) $ unzip $ map (second (expand_reads (rs_writes rs)) . update_stack) $ rs_syms rs
            next_writes = (rs_writes next_rs) <> (pms_writes next_pms)
        in (null next_writes, next_rs {
            rs_writes = next_writes
          })
        
      res = until (fst . snd) (((+1) *** iterant . snd)) (0, (False, syms0))
  in (fst res, snd $ snd res)

reduce_deep :: SymApp -> ReduceSyms
reduce_deep sa | let args = sa_args sa
                     sym = sa_sym sa
               , length args > 0 && is_zeroth_kind sym = error $ "Application on " ++ (show $ toConstr sym)
reduce_deep sa@(SA consumers stack m_sym args thread) =
  -------------------
  -- SYM BASE CASE --
  -------------------
  let terminal = mempty { rs_syms = [sa] }
      
      unravel1 :: LHsExpr GhcTc -> [[LHsExpr GhcTc]] -> ReduceSyms -- peeling back wrappings; consider refactor to evaluate most convenient type to put here
      unravel1 target new_args =
        let nf_new_args_syms = map (map (\arg -> reduce_deep $ sa {
                sa_sym = Sym arg,
                sa_args = []
              })) new_args
        in (mconcat $ mconcat nf_new_args_syms) {
          rs_syms = mempty
        } <> reduce_deep sa {
          -- STACK good: inherit from ambient application; if this ends up being an application, reduce_deep will update the stack accordingly
          -- CONSUMERS good: consumed law that distributes over unwrapping
          sa_sym = Sym target,
          sa_args = map (concatMap rs_syms) nf_new_args_syms
          -- CONSUMERS good: `consumers` property at least distributes over App; if the leftmost var is of type `Consumer`, then it might make some args `consumed` as well.
        }
      
      fail = error $ "FAIL" ++ (constr_ppr $ m_sym)
  in case m_sym of
    Sym sym -> case unLoc sym of
      HsLamCase _ mg -> unravel1 (HsLam NoExt mg <$ sym) []
      
      HsLam _ mg | let loc = getLoc $ mg_alts mg -- <- NB this is why the locations of MatchGroups don't matter
                 , not $ is_visited stack sa -> -- beware about `noLoc`s showing up here: maybe instead break out the pattern matching code
                  if matchGroupArity mg > length args
                    then terminal
                    else
                      let next_binds :: [Bind]
                          next_binds = concatMap ( -- over function body alternatives
                              flip zip (sa_args sa) . map unLoc . m_pats . unLoc -- `args` FINALLY USED HERE -- [[SymApp]] vs. [Pat]
                            ) (unLoc $ mg_alts mg)
                          next_pat_matches :: Map Id [SymApp]
                          next_pat_matches = pat_match_many next_binds -- NOTE no recursive pattern matching needed here because argument patterns are purely deconstructive and can't refer to the new bindings the others make
                          
                          bind_pms@(PatMatchSyms {
                              pms_syms = next_explicit_binds,
                              pms_writes = bind_writes
                            }) = pat_match $ grhs_binds mg -- STACK questionable: do we need the new symbol here? Shouldn't it be  -- localize binds correctly via pushing next stack location
                          next_exprs = grhs_exprs $ map (grhssGRHSs . m_grhss . unLoc) $ unLoc $ mg_alts mg
                          next_frame = AppFrame sa (SymTable {
                              stbl_table = next_pat_matches,
                              stbl_binds = next_binds
                            } <> next_explicit_binds)
                          next_stack = mapSB (next_frame:) stack
                          next_args = drop (matchGroupArity mg) args
                      in mempty {
                        rs_writes = pms_writes bind_pms
                      }
                        <> (mconcat $ map (\next_expr ->
                            reduce_deep sa {
                              sa_stack = next_stack,
                              sa_sym = Sym next_expr,
                              sa_args = next_args
                            }
                          ) next_exprs) -- TODO check if the sym record update + args are correct for this stage
                 | otherwise -> mempty
            
      HsVar _ (L loc v) ->
        let args' | arg1:rest <- args
                  , Just "Consumer" <- varTyConName v
                    = (map (\b -> b { sa_consumers = make_stack_key sa : (sa_consumers b) }) arg1) : rest -- identify as consumer-consumed values
                     -- TODO refactor with lenses
                  | otherwise = args
            terminal' = mempty { rs_syms = [sa { sa_args = args' }] }
        in (\rs@(ReduceSyms { rs_syms }) -> -- enforce nesting rule: all invokations on consumed values are consumed
            rs {
                rs_syms = map (\sa' -> sa' { sa_consumers = sa_consumers sa' ++ consumers }) rs_syms -- TODO <- starting to question if this is doubling work
              }
          ) $
          if | v `elem` (var_ref_tail stack) ->
                -- anti-cycle var resolution
                mempty
             | varString v == "debug#" ->
                -- DEBUG SYMBOL
                mempty
             | Just left_syms <- stack_var_lookup True v stack -> -- this absolutely sucks, we have to use the "soft" search because instance name Uniques are totally unusable. Can't even use `Name`, unless I convert to string every time... which I might need to do in the future for performance reasons if I can't come up with a solution for this. 
              mconcat $ map (\sa' ->
                  reduce_deep sa' { -- TODO: check if `reduce_deep` is actually necessary here; might not be because we expect the symbols in the stack to be resolved
                    sa_args = sa_args sa' ++ args', -- ARGS good: elements in the stack are already processed, so if their args are okay these ones are okay
                    sa_stack = mapSB ((VarRefFrame v):) (sa_stack sa')
                  }
                ) left_syms
             | otherwise -> case varString v of
              ------------------------------------
              -- *** SPECIAL CASE FUNCTIONS *** --
              ------------------------------------
              
              -- "newEmptyMVar" -> -- return as terminal and identify above
              -- "newMVar" -> -- find this in post-processing and do it
              -- "takeMVar" -> if length args >= 1 -- no need, do this in post-processing
              --   then 
              --   else terminal
              
              -- MAGIC MONADS (fallthrough)
              "return" | vs:args'' <- args' ->
                mconcat $ map (\sa' -> reduce_deep $ sa' { sa_args = ((sa_args sa') <> args'') }) vs
              -- NB about `[]` on the rightmost side of the pattern match on `args'`: it's never typesafe to apply to a monad (except `Arrow`), so if we see arguments, we have to freak out and not move forward with that.
                
              ">>" | i:o:[] <- args'
                   , let i' = map reduce_deep i
                         o' = map reduce_deep o -> -- magical monad `*>` == `>>`: take right-hand syms, merge writes
                    mconcat [i'' { rs_syms = mempty } <> o'' | i'' <- i', o'' <- o'] -- combinatorial EXPLOSION! BOOM PEW PEW
              ">>=" | i:o:[] <- args' -> -- magical monad `>>=`: shove the return value from the last stage into the next, merge writes
                    -- grabbing the writes is as easy as just adding `i` to the arguments; the argument resolution in `terminal` will take care of it
                    -- under the assumption that it's valid to assume IO is a pure wrapper, this actually just reduces to plain application of a lambda
                      mconcat $ map (\fun -> reduce_deep fun {
                            sa_args = sa_args fun ++ [i]
                          }
                        ) o
                
              "forkIO" | to_fork:[] <- args' ->
                  let this_thread = (getLoc sym, stack)
                      result = mconcat $ map (everywhereBut (False `mkQ` (const True :: Stack -> Bool)) (mkT $ \sa' -> sa' { sa_thread = this_thread }) . reduce_deep) to_fork
                  in result {
                      rs_syms = [error "Using the ThreadID from forkIO is not yet supported."]
                    }
                    
              "putMVar" -> if length args' >= 2
                then
                  let (pipes:vals:_) = args'
                      next_writes = [(pipes, vals)]
                  in append_rs_writes next_writes terminal'
                else terminal'
                
              _ -> terminal'
        
      HsApp _ _ _ -> -- this should only come up from the GHC AST, not from our own reduce-unwrap-wrap
        let (fun, next_args) = deapp sym
        in unravel1 fun (map pure next_args) -- I still don't remember why we special-cased HsConLikeOut to let it be `terminal` without evaluating the args, besides premature optimization  (i.e. saving the var lookup and one round of re-reducing the arguments)
        
      OpApp _ l_l l_op l_r -> unravel1 l_op [[l_l], [l_r]]
      
      -- Wrappings
      HsWrap _ _ v -> unravel1 (const v <$> sym) [] -- why is HsWrap wrapping a bare HsExpr?! No loc? Inferred from surroundings I guess (like this)
      NegApp _ v _ -> unravel1 v []
      HsPar _ v -> unravel1 v []
      SectionL _ v m_op -> unravel1 m_op [[v]]
      SectionR _ m_op v | length args > 0 -> -- need to check fo arguments because that's the only way we're going to enforce the flipping
                          let L _ (HsVar _ op) = unHsWrap m_op
                              nf_arg1_syms = reduce_deep sa { sa_sym = Sym v, sa_args = [] }
                              arg0:args_rest = args
                          in case stack_var_lookup True (unLoc op) stack of
                            Just stack_exprs ->
                              mappend nf_arg1_syms { rs_syms = [] } $ mconcat $ map (\sa' ->
                                reduce_deep $ sa' {
                                  sa_args = (sa_args sa') ++ (arg0 : (rs_syms nf_arg1_syms) : args_rest) -- TODO also do the operator constructor case
                                }
                              ) stack_exprs
                            Nothing -> terminal
                        | otherwise -> error "Unsaturated (i.e. partial) SectionR is not yet supported."
          
      HsCase _ x mg -> unravel1 (noLoc $ HsApp NoExt (HsLam NoExt mg <$ mg_alts mg) x) [] -- refactor as HsLam so we can just use that pat match code
      HsIf _ _ if_ then_ else_ -> unravel1 then_ [] <> unravel1 else_ []
      HsMultiIf ty rhss ->
        let PatMatchSyms {
                pms_syms = next_explicit_binds,
                pms_writes = bind_writes
              } = pat_match $ grhs_binds rhss
            next_exprs = grhs_exprs rhss
        in mempty { rs_writes = bind_writes }
          <> (mconcat $ map (\next_expr ->
              reduce_deep sa {
                sa_sym = Sym next_expr,
                sa_stack = mapSB ((AppFrame sa next_explicit_binds):) stack
              }) next_exprs) -- TODO check that record update with sym (and its location) is the right move here
        
      HsLet _ _ expr -> unravel1 expr [] -- assume local bindings already caught by surrounding function body (HsLam case)
      HsDo _ _ (L _ stmts) -> foldl (\syms (L _ stmt) ->
          case stmt of
            LastStmt _ expr _ _ -> syms { rs_syms = mempty } <> unravel1 expr [] -- kill the results from all previous stmts because of the semantics of `>>`
            -- ApplicativeStmt _ _ _ -> undefined -- TODO yet to appear in the wild and be implemented
            BindStmt pat expr _ _ ty -> syms -- covered by binds; can't be the last statement anyways -- <- scratch that -- TODO implement this to unbox the monad (requires fake IO structure2) -- <- scratch THAT, we're not going to do anything because the binds are covered in grhs_binds; we're letting IO and other magic monads be unravelled into their values contained within to simplify analysis
            LetStmt _ _ -> syms -- same story as BindStmt
            BodyStmt _ expr _ _ -> syms { rs_syms = mempty } <> unravel1 expr []
            ParStmt _ _ _ _ -> undefined -- not analyzed for now, because the list comp is too niche (only used for parallel monad comprehensions; see <https://gitlab.haskell.org/ghc/ghc/wikis/monad-comprehensions>)
            _ -> fail
            -- fun fact: I thought ParStmt was for "parenthesized", but it's "parallel"
        ) mempty stmts -- push all the work to another round of `reduce_deep`.
      
      -- SymAppinal forms
      
      HsConLikeOut _ _ -> terminal -- if length args == 0 then terminal else error "Only bare ConLike should make it to `reduce_deep`" -- still don't remember why I special-cased HsConLikeOut in HsApp
      HsOverLit _ _ -> terminal
      HsLit _ _ -> terminal
      ExplicitTuple _ args _ ->
        let (next_rs, args') = first mconcat $ unzip $ map (\case
                L _ (Present _ s) -> (id &&& rs_syms) $ reduce_deep $ sa {
                    sa_sym = Sym s,
                    sa_args = []
                  }
                _ -> error "Tuple sections not yet supported"
              ) args
        in next_rs { rs_syms = mempty } <> (reduce_deep $ sa {
          sa_sym = TupleConstr (getLoc sym),
          sa_args = args'
        })
      ExplicitSum _ _ _ _ -> terminal
      ExplicitList _ _ args ->
        let (next_rs, args') = first mconcat $ unzip $ map (\s ->
                (id &&& rs_syms) $ reduce_deep $ sa {
                  sa_sym = Sym s,
                  sa_args = []
                }
              ) args
        in next_rs { rs_syms = mempty } <> (reduce_deep $ sa {
          sa_sym = ListConstr (getLoc sym),
          sa_args = args'
        })
      ExplicitList _ (Just _) _ -> error "List comprehensions not yet supported"
      -- ExplicitPArr _ _ -> terminal
      _ -> error ("Incomplete coverage of HsExpr rules: encountered " ++ (show $ toConstr $ unLoc sym))
    _ -> terminal