-----------------------------------------------------------------------------
--
-- Old-style Cmm data types
--
-- (c) The University of Glasgow 2004-2006
--
-----------------------------------------------------------------------------

module OldCmm (
        Cmm, RawCmm, CmmTop, RawCmmTop,
        ListGraph(..),
        CmmInfo(..), UpdateFrame(..),
        cmmMapGraph, cmmTopMapGraph,
        cmmMapGraphM, cmmTopMapGraphM,
        GenBasicBlock(..), CmmBasicBlock, blockId, blockStmts, mapBlockStmts,
        CmmStmt(..), CmmReturnInfo(..), CmmHinted(..),
        HintedCmmFormal, HintedCmmFormals, HintedCmmActual, HintedCmmActuals,
        CmmSafety(..), CmmCallTarget(..),
        module CmmDecl,
        module CmmExpr,
  ) where

#include "HsVersions.h"

import BlockId
import CmmDecl
import CmmExpr
import ForeignCall

import ClosureInfo
import Outputable
import FastString


-- A [[BlockId]] is a local label.
-- Local labels must be unique within an entire compilation unit, not
-- just a single top-level item, because local labels map one-to-one
-- with assembly-language labels.

-----------------------------------------------------------------------------
--     Info Tables
-----------------------------------------------------------------------------

data CmmInfo
  = CmmInfo
      (Maybe BlockId)     -- GC target. Nothing <=> CPS won't do stack check
                          -- JD: NOT USED BY NEW CODE GEN
      (Maybe UpdateFrame) -- Update frame
      CmmInfoTable        -- Info table

-- | A frame that is to be pushed before entry to the function.
-- Used to handle 'update' frames.
data UpdateFrame =
    UpdateFrame
      CmmExpr    -- Frame header.  Behaves like the target of a 'jump'.
      [CmmExpr]  -- Frame remainder.  Behaves like the arguments of a 'jump'.

-----------------------------------------------------------------------------
--  Cmm, CmmTop, CmmBasicBlock
-----------------------------------------------------------------------------

-- A file is a list of top-level chunks.  These may be arbitrarily
-- re-orderd during code generation.

-- | A control-flow graph represented as a list of extended basic blocks.
newtype ListGraph i = ListGraph [GenBasicBlock i]
   -- ^ Code, may be empty.  The first block is the entry point.  The
   -- order is otherwise initially unimportant, but at some point the
   -- code gen will fix the order.

   -- BlockIds must be unique across an entire compilation unit, since
   -- they are translated to assembly-language labels, which scope
   -- across a whole compilation unit.

-- | Cmm with the info table as a data type
type Cmm    = GenCmm    CmmStatic CmmInfo (ListGraph CmmStmt)
type CmmTop = GenCmmTop CmmStatic CmmInfo (ListGraph CmmStmt)

-- | Cmm with the info tables converted to a list of 'CmmStatic'
type RawCmm    = GenCmm    CmmStatic [CmmStatic] (ListGraph CmmStmt)
type RawCmmTop = GenCmmTop CmmStatic [CmmStatic] (ListGraph CmmStmt)


-- A basic block containing a single label, at the beginning.
-- The list of basic blocks in a top-level code block may be re-ordered.
-- Fall-through is not allowed: there must be an explicit jump at the
-- end of each basic block, but the code generator might rearrange basic
-- blocks in order to turn some jumps into fallthroughs.

data GenBasicBlock i = BasicBlock BlockId [i]
type CmmBasicBlock   = GenBasicBlock CmmStmt

instance UserOfLocalRegs i => UserOfLocalRegs (GenBasicBlock i) where
    foldRegsUsed f set (BasicBlock _ l) = foldRegsUsed f set l

blockId :: GenBasicBlock i -> BlockId
-- The branch block id is that of the first block in 
-- the branch, which is that branch's entry point
blockId (BasicBlock blk_id _ ) = blk_id

blockStmts :: GenBasicBlock i -> [i]
blockStmts (BasicBlock _ stmts) = stmts


mapBlockStmts :: (i -> i') -> GenBasicBlock i -> GenBasicBlock i'
mapBlockStmts f (BasicBlock id bs) = BasicBlock id (map f bs)
----------------------------------------------------------------
--   graph maps
----------------------------------------------------------------

cmmMapGraph    :: (g -> g') -> GenCmm    d h g -> GenCmm    d h g'
cmmTopMapGraph :: (g -> g') -> GenCmmTop d h g -> GenCmmTop d h g'

cmmMapGraphM    :: Monad m => (String -> g -> m g') -> GenCmm    d h g -> m (GenCmm    d h g')
cmmTopMapGraphM :: Monad m => (String -> g -> m g') -> GenCmmTop d h g -> m (GenCmmTop d h g')

cmmMapGraph f (Cmm tops) = Cmm $ map (cmmTopMapGraph f) tops
cmmTopMapGraph f (CmmProc h l g) = CmmProc h l (f g)
cmmTopMapGraph _ (CmmData s ds)  = CmmData s ds

cmmMapGraphM f (Cmm tops) = mapM (cmmTopMapGraphM f) tops >>= return . Cmm
cmmTopMapGraphM f (CmmProc h l g) =
  f (showSDoc $ ppr l) g >>= return . CmmProc h l
cmmTopMapGraphM _ (CmmData s ds)  = return $ CmmData s ds


data CmmReturnInfo = CmmMayReturn
                   | CmmNeverReturns
    deriving ( Eq )

-----------------------------------------------------------------------------
--		CmmStmt
-- A "statement".  Note that all branches are explicit: there are no
-- control transfers to computed addresses, except when transfering
-- control to a new function.
-----------------------------------------------------------------------------

data CmmStmt	-- Old-style
  = CmmNop
  | CmmComment FastString

  | CmmAssign CmmReg CmmExpr	 -- Assign to register

  | CmmStore CmmExpr CmmExpr     -- Assign to memory location.  Size is
                                 -- given by cmmExprType of the rhs.

  | CmmCall	 		 -- A call (forign, native or primitive), with 
     CmmCallTarget
     HintedCmmFormals		 -- zero or more results
     HintedCmmActuals		 -- zero or more arguments
     CmmSafety			 -- whether to build a continuation
     CmmReturnInfo

  | CmmBranch BlockId             -- branch to another BB in this fn

  | CmmCondBranch CmmExpr BlockId -- conditional branch

  | CmmSwitch CmmExpr [Maybe BlockId]   -- Table branch
	-- The scrutinee is zero-based; 
	--	zero -> first block
	--	one  -> second block etc
	-- Undefined outside range, and when there's a Nothing

  | CmmJump CmmExpr      -- Jump to another C-- function,
      HintedCmmActuals         -- with these parameters.  (parameters never used)

  | CmmReturn            -- Return from a native C-- function,
      HintedCmmActuals         -- with these return values. (parameters never used)

data CmmHinted a = CmmHinted { hintlessCmm :: a, cmmHint :: ForeignHint }
	   	 deriving( Eq )

type HintedCmmActuals = [HintedCmmActual]
type HintedCmmFormals = [HintedCmmFormal]
type HintedCmmFormal  = CmmHinted CmmFormal
type HintedCmmActual  = CmmHinted CmmActual

data CmmSafety      = CmmUnsafe | CmmSafe C_SRT | CmmInterruptible

-- | enable us to fold used registers over 'CmmActuals' and 'CmmFormals'
instance UserOfLocalRegs CmmStmt where
  foldRegsUsed f (set::b) s = stmt s set
    where 
      stmt :: CmmStmt -> b -> b
      stmt (CmmNop)                  = id
      stmt (CmmComment {})           = id
      stmt (CmmAssign _ e)           = gen e
      stmt (CmmStore e1 e2)          = gen e1 . gen e2
      stmt (CmmCall target _ es _ _) = gen target . gen es
      stmt (CmmBranch _)             = id
      stmt (CmmCondBranch e _)       = gen e
      stmt (CmmSwitch e _)           = gen e
      stmt (CmmJump e es)            = gen e . gen es
      stmt (CmmReturn es)            = gen es

      gen :: UserOfLocalRegs a => a -> b -> b
      gen a set = foldRegsUsed f set a

instance UserOfLocalRegs CmmCallTarget where
    foldRegsUsed f set (CmmCallee e _) = foldRegsUsed f set e
    foldRegsUsed _ set (CmmPrim {})    = set

instance UserOfSlots CmmCallTarget where
    foldSlotsUsed f set (CmmCallee e _) = foldSlotsUsed f set e
    foldSlotsUsed _ set (CmmPrim {})    = set

instance UserOfLocalRegs a => UserOfLocalRegs (CmmHinted a) where
  foldRegsUsed f set a = foldRegsUsed f set (hintlessCmm a)

instance UserOfSlots a => UserOfSlots (CmmHinted a) where
  foldSlotsUsed f set a = foldSlotsUsed f set (hintlessCmm a)

instance DefinerOfLocalRegs a => DefinerOfLocalRegs (CmmHinted a) where
  foldRegsDefd f set a = foldRegsDefd f set (hintlessCmm a)

{-
Discussion
~~~~~~~~~~

One possible problem with the above type is that the only way to do a
non-local conditional jump is to encode it as a branch to a block that
contains a single jump.  This leads to inefficient code in the back end.

[N.B. This problem will go away when we make the transition to the
'zipper' form of control-flow graph, in which both targets of a
conditional jump are explicit. ---NR]

One possible way to fix this would be:

data CmmStat = 
  ...
  | CmmJump CmmBranchDest
  | CmmCondJump CmmExpr CmmBranchDest
  ...

data CmmBranchDest
  = Local BlockId
  | NonLocal CmmExpr [LocalReg]

In favour:

+ one fewer constructors in CmmStmt
+ allows both cond branch and switch to jump to non-local destinations

Against:

- not strictly necessary: can already encode as branch+jump
- not always possible to implement any better in the back end
- could do the optimisation in the back end (but then plat-specific?)
- C-- doesn't have it
- back-end optimisation might be more general (jump shortcutting)

So we'll stick with the way it is, and add the optimisation to the NCG.
-}

-----------------------------------------------------------------------------
--		CmmCallTarget
--
-- The target of a CmmCall.
-----------------------------------------------------------------------------

data CmmCallTarget
  = CmmCallee		-- Call a function (foreign or native)
	CmmExpr 		-- literal label <=> static call
				-- other expression <=> dynamic call
	CCallConv		-- The calling convention

  | CmmPrim		-- Call a "primitive" (eg. sin, cos)
	CallishMachOp		-- These might be implemented as inline
				-- code by the backend.
  deriving Eq
