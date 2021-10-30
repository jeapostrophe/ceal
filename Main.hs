#!/usr/bin/env stack
{- stack script
 --optimize
 --ghc-options -Wall
 --resolver lts-17.8
 --package bytestring
 --package containers
 --package mtl
 --package msgpack
 -}
{-# LANGUAGE RecordWildCards, LambdaCase, FlexibleInstances, DeriveAnyClass,
   DeriveGeneric, NumericUnderscores #-}

import Control.Monad.Reader
import qualified Data.ByteString as B
import qualified Data.Map.Strict as M
import Data.Maybe
import Data.Semigroup
import Data.MessagePack

-- AST

data CProg = CProg
  { cp_heap :: B.ByteString
  , cp_cs :: M.Map Var CConst
  , cp_fs :: [(Var, CFun)]
  , cp_main :: CTail
  }

type Var = Int

data CConst
  = CC_Int Int

data CFun = CFun
  { cf_params :: [Var]
  , cf_ret :: Var
  , cf_body :: CTail
  }

data CTail
  = CT_Expr CExpr
  | CT_Let Var CExpr CTail
  | CT_Do CExpr CTail
  | CT_If Var CTail CTail
  | CT_Switch Var (M.Map Int CTail) CTail
  | CT_For
    { ctf_var :: Var
    , ctf_break :: Var
    , ctf_continue :: Var
    , ctf_max :: Int -- This could be a `Var` and restricted to one of the constants
    , ctf_body :: CTail
    , ctf_k :: CTail
    }

data CExpr
  = CE_Var Var
  | CE_Prim CPrim [Var]
  | CE_Call Var [Var]

data CPrim
  = CP_ADD -- binary
  | CP_SHA256 -- unary
  | CP_ASSERT -- unary
  | CP_MEMREF -- unary
  | CP_MEMSET -- unary

-- WCET

type Cost = Int

add1 :: Cost -> Cost
add1 = (+) 1

type WApp = ReaderT WEnv IO
type WEnv = M.Map Var Cost

class WCET a where
  wcet :: a -> WApp Cost

instance WCET a => WCET [a] where
  wcet c = (getMax . mconcat) <$> mapM (\e -> Max <$> wcet e) c

instance WCET CPrim where
  wcet = \case
    CP_SHA256 -> return 35_000_000
    _ -> return 1

instance WCET CExpr where
  wcet = \case
    CE_Var {} -> return 1
    CE_Prim p _ -> wcet p
    CE_Call c _ -> add1 <$> (fromMaybe (error "undefined var") <$> asks (M.lookup c))

instance WCET CFun where
  wcet (CFun {..}) = wcet cf_body

instance WCET CTail where
  wcet = \case
    CT_Expr e -> wcet e
    CT_Let _ e t -> (+) <$> wcet e <*> wcet t
    CT_Do e t -> (+) <$> wcet e <*> wcet t
    CT_If _ t f -> add1 <$> wcet [t, f]
    CT_Switch _ m d -> add1 <$> wcet (d : M.elems m)
    CT_For {..} -> do
      bc <- local (M.insert ctf_break 1 . M.insert ctf_continue 1) $
        wcet ctf_body
      kc <- wcet ctf_k
      return $ 1 + ctf_max * bc + kc

instance WCET CProg where
  wcet (CProg _ _ fs mt) = h (wcet mt) fs
    where
      h m = \case
        [] -> m
        (v, f) : fs' -> do
          fc <- wcet f
          local (M.insert v fc) $ h m fs'

-- Main

main :: IO ()
main = return ()
