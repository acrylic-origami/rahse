{-# LANGUAGE LambdaCase, NamedFieldPuns #-}
module Main where
  import System.Environment ( getArgs )
  -- import System.Console.GetOpt ( getOpt )
  
  import GHC
  import GHC.Paths ( libdir )
  import Var ( Var, varUnique )
  import Unique ( getUnique )
  import Bag ( bagToList )
  import qualified Data.Map.Strict as M
  import Data.Map.Strict ( Map(..), unionsWith, keys, toList, insert, insertWith )
  import Data.Generics ( cast, mkT, mkQ, extQ, everything, everywhere, everywhereBut, toConstr, Data(..) )
  import Data.Generics.Extra ( constr_ppr, shallowest, everything_ppr )
  import qualified Data.Map.Strict as M ( empty, elems )
  import Data.Tuple.Extra ( first, (&&&), (***) )
  import Data.List ( intersperse )
  import Data.Maybe ( fromMaybe, catMaybes )
  import Control.Monad ( mzero )
  
  import Ra ( pat_match, reduce, reduce_deep )
  import Ra.GHC ( bind_to_table, grhs_binds, varString )
  import Ra.Lang -- ( SymTable, Sym(..), SymApp(..), Stack(..), unSB, Stack(..), ReduceSyms(..), PatMatchSyms(..), Write(..) )
  import Ra.Lang.Extra

  import Outputable ( Outputable, interppSP, showSDocUnsafe, showPpr )

  main :: IO ()
  main = do
    mod_str:_ <- getArgs
    (putStrLn=<<) $ runGhc (Just libdir) $ do
      dflags <- getSessionDynFlags
      setSessionDynFlags dflags
      target <- guessTarget ("target/" ++ mod_str ++ ".hs") Nothing
      setTargets [target] 
      load LoadAllTargets

      -- deps <- depanal [] False
      -- return $ show $ foldr ((:) . moduleNameString . moduleName . ms_mod) [] deps
      
      modSum <- getModSummary $ mkModuleName mod_str
      p <- parseModule modSum
      t <- typecheckModule p
      
      let st0 = SB []
          initial_pms = pat_match $ grhs_binds (typecheckedSource t)
          syms0 = pms2rs initial_pms -- (\s -> s { sa_stack = append_frame (AppFrame s (pms_syms initial_pms)) (sa_stack s) }) $ head $ (!!0) $ M.elems $ 
          -- syms1 = everywhere (mkT (\sa -> sa {
          --     sa_stack = mapSB ((AppFrame (sa_from_sym EntryPoint) (pms_syms initial_pms)): ) (sa_stack sa)
          --   })) syms0 -- this makes it work, but feels verrrrry sketchy modifying stacks like that; it's almost like duplicating and tacking onto this "layer"
          rsn = reduce syms0
          ppr_final_writes :: Map StackKey [SymApp] -> String
          ppr_final_writes = concat . intersperse "\n===\n" . map ((
              uncurry ((++) . (++" -> "))
              . (
                  showPpr dflags
                  *** concat . intersperse "\n" . map (ppr_sa (showPpr dflags))
              )
            )) . M.assocs
          
          final_writes :: Map StackKey [SymApp]
          final_writes = foldr (flip (foldr ($))
            . uncurry (flip (map . ($))) -- [Map StackKey [SymApp] -> Map StackKey [SymApp]]
            . (
              map (\sa -> case sa_sym sa of
                  Sym (L _ (HsVar _ v)) | (varString $ unLoc v) == "newEmptyMVar" -> Just $ make_stack_key sa
                  _ -> Nothing
                ) -- [StackKey]
              *** (\v m_k -> case m_k of
                  Just k -> insertWith (++) k v
                  Nothing -> id
                ) -- [StackKey -> Map StackKey [SymApp] -> Map StackKey [SymApp]]
              -- map (((fromMaybe id).) . fmap . flip insert) -- sometimes pointfree isn't worth it
            )) mempty (concatMap rs_writes rsn)
      
      return $ ppr_final_writes final_writes
      -- return $ show $ length $ mconcat $ map rs_writes rsn
      -- return $ uncurry (++) . (show *** ppr_rs (showPpr dflags)) $ reduce $ (!!1) $ catMaybes $ map (\b -> case unLoc b of { AbsBinds {} -> Just $ snd $ head $ bind_to_table st0 (unLoc b); _ -> Nothing }) $ bagToList (typecheckedSource t)
      -- return $ ppr_rs (showPpr dflags) syms0
      
      -- return $ concatMap ((++"\n") . uncurry ((++) . (++" -> ")) . (showPpr dflags *** concatMap (ppr_stack (showPpr dflags) . sa_stack))) $ M.assocs $ stbl_table (pms_syms initial_pms)
      -- return $ ppr_pms (showPpr dflags) initial_pms
      -- return $ concatMap (uncurry (++) . ((showPpr dflags) *** (concatMap (ppr_sa (showPpr dflags))))) $ grhs_binds (typecheckedSource t)
      -- return $ constr_ppr $ typecheckedSource t
