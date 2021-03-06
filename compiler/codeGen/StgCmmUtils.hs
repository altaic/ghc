-----------------------------------------------------------------------------
--
-- Code generator utilities; mostly monadic
--
-- (c) The University of Glasgow 2004-2006
--
-----------------------------------------------------------------------------

module StgCmmUtils (
	cgLit, mkSimpleLit,
	emitDataLits, mkDataLits,
        emitRODataLits, mkRODataLits,
	emitRtsCall, emitRtsCallWithVols, emitRtsCallWithResult,
	assignTemp, newTemp, withTemp,

	newUnboxedTupleRegs,

	mkMultiAssign, mkCmmSwitch, mkCmmLitSwitch,
	emitSwitch,

	tagToClosure, mkTaggedObjectLoad,

        callerSaves, callerSaveVolatileRegs, get_GlobalReg_addr,

	cmmAndWord, cmmOrWord, cmmNegate, cmmEqWord, cmmNeWord,
        cmmUGtWord,
	cmmOffsetExprW, cmmOffsetExprB,
	cmmRegOffW, cmmRegOffB,
	cmmLabelOffW, cmmLabelOffB,
	cmmOffsetW, cmmOffsetB,
	cmmOffsetLitW, cmmOffsetLitB,
	cmmLoadIndexW,
        cmmConstrTag, cmmConstrTag1,

        cmmUntag, cmmIsTagged, cmmGetTag,

	addToMem, addToMemE, addToMemLbl,
	mkWordCLit,
	mkStringCLit, mkByteStringCLit,
	packHalfWordsCLit,
	blankWord,

	getSRTInfo, clHasCafRefs, srt_escape
  ) where

#include "HsVersions.h"
#include "../includes/stg/MachRegs.h"

import StgCmmMonad
import StgCmmClosure
import BlockId
import CmmDecl
import CmmExpr hiding (regUsedIn)
import MkGraph
import CLabel
import CmmUtils

import ForeignCall
import IdInfo
import Type
import TyCon
import Constants
import SMRep
import StgSyn	( SRT(..) )
import Module
import Literal
import Digraph
import ListSetOps
import Util
import Unique
import DynFlags
import FastString
import Outputable

import Data.Char
import Data.Bits
import Data.Word
import Data.Maybe


-------------------------------------------------------------------------
--
--	Literals
--
-------------------------------------------------------------------------

cgLit :: Literal -> FCode CmmLit
cgLit (MachStr s) = mkByteStringCLit (bytesFS s)
 -- not unpackFS; we want the UTF-8 byte stream.
cgLit other_lit   = return (mkSimpleLit other_lit)

mkSimpleLit :: Literal -> CmmLit
mkSimpleLit (MachChar	c)    = CmmInt (fromIntegral (ord c)) wordWidth
mkSimpleLit MachNullAddr      = zeroCLit
mkSimpleLit (MachInt i)       = CmmInt i wordWidth
mkSimpleLit (MachInt64 i)     = CmmInt i W64
mkSimpleLit (MachWord i)      = CmmInt i wordWidth
mkSimpleLit (MachWord64 i)    = CmmInt i W64
mkSimpleLit (MachFloat r)     = CmmFloat r W32
mkSimpleLit (MachDouble r)    = CmmFloat r W64
mkSimpleLit (MachLabel fs ms fod) 
	= CmmLabel (mkForeignLabel fs ms labelSrc fod)
	where
		-- TODO: Literal labels might not actually be in the current package...
		labelSrc = ForeignLabelInThisPackage	
mkSimpleLit other	      = pprPanic "mkSimpleLit" (ppr other)

mkLtOp :: Literal -> MachOp
-- On signed literals we must do a signed comparison
mkLtOp (MachInt _)    = MO_S_Lt wordWidth
mkLtOp (MachFloat _)  = MO_F_Lt W32
mkLtOp (MachDouble _) = MO_F_Lt W64
mkLtOp lit	      = MO_U_Lt (typeWidth (cmmLitType (mkSimpleLit lit)))
				-- ToDo: seems terribly indirect!


---------------------------------------------------
--
--	Cmm data type functions
--
---------------------------------------------------

-- The "B" variants take byte offsets
cmmRegOffB :: CmmReg -> ByteOff -> CmmExpr
cmmRegOffB = cmmRegOff

cmmOffsetB :: CmmExpr -> ByteOff -> CmmExpr
cmmOffsetB = cmmOffset

cmmOffsetExprB :: CmmExpr -> CmmExpr -> CmmExpr
cmmOffsetExprB = cmmOffsetExpr

cmmLabelOffB :: CLabel -> ByteOff -> CmmLit
cmmLabelOffB = cmmLabelOff

cmmOffsetLitB :: CmmLit -> ByteOff -> CmmLit
cmmOffsetLitB = cmmOffsetLit

-----------------------
-- The "W" variants take word offsets
cmmOffsetExprW :: CmmExpr -> CmmExpr -> CmmExpr
-- The second arg is a *word* offset; need to change it to bytes
cmmOffsetExprW e (CmmLit (CmmInt n _)) = cmmOffsetW e (fromInteger n)
cmmOffsetExprW e wd_off = cmmIndexExpr wordWidth e wd_off

cmmOffsetW :: CmmExpr -> WordOff -> CmmExpr
cmmOffsetW e n = cmmOffsetB e (wORD_SIZE * n)

cmmRegOffW :: CmmReg -> WordOff -> CmmExpr
cmmRegOffW reg wd_off = cmmRegOffB reg (wd_off * wORD_SIZE)

cmmOffsetLitW :: CmmLit -> WordOff -> CmmLit
cmmOffsetLitW lit wd_off = cmmOffsetLitB lit (wORD_SIZE * wd_off)

cmmLabelOffW :: CLabel -> WordOff -> CmmLit
cmmLabelOffW lbl wd_off = cmmLabelOffB lbl (wORD_SIZE * wd_off)

cmmLoadIndexW :: CmmExpr -> Int -> CmmType -> CmmExpr
cmmLoadIndexW base off ty = CmmLoad (cmmOffsetW base off) ty

-----------------------
cmmULtWord, cmmUGeWord, cmmUGtWord, cmmSubWord,
  cmmNeWord, cmmEqWord, cmmOrWord, cmmAndWord 
  :: CmmExpr -> CmmExpr -> CmmExpr
cmmOrWord  e1 e2 = CmmMachOp mo_wordOr  [e1, e2]
cmmAndWord e1 e2 = CmmMachOp mo_wordAnd [e1, e2]
cmmNeWord  e1 e2 = CmmMachOp mo_wordNe  [e1, e2]
cmmEqWord  e1 e2 = CmmMachOp mo_wordEq  [e1, e2]
cmmULtWord e1 e2 = CmmMachOp mo_wordULt [e1, e2]
cmmUGeWord e1 e2 = CmmMachOp mo_wordUGe [e1, e2]
cmmUGtWord e1 e2 = CmmMachOp mo_wordUGt [e1, e2]
--cmmShlWord e1 e2 = CmmMachOp mo_wordShl [e1, e2]
--cmmUShrWord e1 e2 = CmmMachOp mo_wordUShr [e1, e2]
cmmSubWord e1 e2 = CmmMachOp mo_wordSub [e1, e2]

cmmNegate :: CmmExpr -> CmmExpr
cmmNegate (CmmLit (CmmInt n rep)) = CmmLit (CmmInt (-n) rep)
cmmNegate e			  = CmmMachOp (MO_S_Neg (cmmExprWidth e)) [e]

blankWord :: CmmStatic
blankWord = CmmUninitialised wORD_SIZE

-- Tagging --
-- Tag bits mask
--cmmTagBits = CmmLit (mkIntCLit tAG_BITS)
cmmTagMask, cmmPointerMask :: CmmExpr
cmmTagMask = CmmLit (mkIntCLit tAG_MASK)
cmmPointerMask = CmmLit (mkIntCLit (complement tAG_MASK))

-- Used to untag a possibly tagged pointer
-- A static label need not be untagged
cmmUntag, cmmGetTag :: CmmExpr -> CmmExpr
cmmUntag e@(CmmLit (CmmLabel _)) = e
-- Default case
cmmUntag e = (e `cmmAndWord` cmmPointerMask)

cmmGetTag e = (e `cmmAndWord` cmmTagMask)

-- Test if a closure pointer is untagged
cmmIsTagged :: CmmExpr -> CmmExpr
cmmIsTagged e = (e `cmmAndWord` cmmTagMask)
                 `cmmNeWord` CmmLit zeroCLit

cmmConstrTag, cmmConstrTag1 :: CmmExpr -> CmmExpr
cmmConstrTag e = (e `cmmAndWord` cmmTagMask) `cmmSubWord` (CmmLit (mkIntCLit 1))
-- Get constructor tag, but one based.
cmmConstrTag1 e = e `cmmAndWord` cmmTagMask

-----------------------
--	Making literals

mkWordCLit :: StgWord -> CmmLit
mkWordCLit wd = CmmInt (fromIntegral wd) wordWidth

packHalfWordsCLit :: (Integral a, Integral b) => a -> b -> CmmLit
-- Make a single word literal in which the lower_half_word is
-- at the lower address, and the upper_half_word is at the 
-- higher address
-- ToDo: consider using half-word lits instead
-- 	 but be careful: that's vulnerable when reversed
packHalfWordsCLit lower_half_word upper_half_word
#ifdef WORDS_BIGENDIAN
   = mkWordCLit ((fromIntegral lower_half_word `shiftL` hALF_WORD_SIZE_IN_BITS)
		 .|. fromIntegral upper_half_word)
#else 
   = mkWordCLit ((fromIntegral lower_half_word) 
		 .|. (fromIntegral upper_half_word `shiftL` hALF_WORD_SIZE_IN_BITS))
#endif

--------------------------------------------------------------------------
--
-- Incrementing a memory location
--
--------------------------------------------------------------------------

addToMemLbl :: CmmType -> CLabel -> Int -> CmmAGraph
addToMemLbl rep lbl n = addToMem rep (CmmLit (CmmLabel lbl)) n

addToMem :: CmmType 	-- rep of the counter
	 -> CmmExpr	-- Address
	 -> Int		-- What to add (a word)
	 -> CmmAGraph
addToMem rep ptr n = addToMemE rep ptr (CmmLit (CmmInt (toInteger n) (typeWidth rep)))

addToMemE :: CmmType 	-- rep of the counter
	  -> CmmExpr	-- Address
	  -> CmmExpr	-- What to add (a word-typed expression)
	  -> CmmAGraph
addToMemE rep ptr n
  = mkStore ptr (CmmMachOp (MO_Add (typeWidth rep)) [CmmLoad ptr rep, n])


-------------------------------------------------------------------------
--
--	Loading a field from an object, 
--	where the object pointer is itself tagged
--
-------------------------------------------------------------------------

mkTaggedObjectLoad :: LocalReg -> LocalReg -> WordOff -> DynTag -> CmmAGraph
-- (loadTaggedObjectField reg base off tag) generates assignment
-- 	reg = bitsK[ base + off - tag ]
-- where K is fixed by 'reg'
mkTaggedObjectLoad reg base offset tag
  = mkAssign (CmmLocal reg)  
	     (CmmLoad (cmmOffsetB (CmmReg (CmmLocal base))
				  (wORD_SIZE*offset - tag))
                      (localRegType reg))

-------------------------------------------------------------------------
--
--	Converting a closure tag to a closure for enumeration types
--      (this is the implementation of tagToEnum#).
--
-------------------------------------------------------------------------

tagToClosure :: TyCon -> CmmExpr -> CmmExpr
tagToClosure tycon tag
  = CmmLoad (cmmOffsetExprW closure_tbl tag) bWord
  where closure_tbl = CmmLit (CmmLabel lbl)
	lbl = mkClosureTableLabel (tyConName tycon) NoCafRefs

-------------------------------------------------------------------------
--
--	Conditionals and rts calls
--
-------------------------------------------------------------------------

emitRtsCall :: PackageId -> FastString -> [(CmmExpr,ForeignHint)] -> Bool -> FCode ()
emitRtsCall pkg fun args safe = emitRtsCall' [] pkg fun args Nothing safe
   -- The 'Nothing' says "save all global registers"

emitRtsCallWithVols :: PackageId -> FastString -> [(CmmExpr,ForeignHint)] -> [GlobalReg] -> Bool -> FCode ()
emitRtsCallWithVols pkg fun args vols safe
   = emitRtsCall' [] pkg fun args (Just vols) safe

emitRtsCallWithResult :: LocalReg -> ForeignHint -> PackageId -> FastString
	-> [(CmmExpr,ForeignHint)] -> Bool -> FCode ()
emitRtsCallWithResult res hint pkg fun args safe
   = emitRtsCall' [(res,hint)] pkg fun args Nothing safe

-- Make a call to an RTS C procedure
emitRtsCall'
   :: [(LocalReg,ForeignHint)]
   -> PackageId
   -> FastString
   -> [(CmmExpr,ForeignHint)]
   -> Maybe [GlobalReg]
   -> Bool -- True <=> CmmSafe call
   -> FCode ()
emitRtsCall' res pkg fun args _vols safe
  = --error "emitRtsCall'"
    do { updfr_off <- getUpdFrameOff
       ; emit caller_save
       ; emit $ call updfr_off
       ; emit caller_load }
  where
    call updfr_off =
      if safe then
        mkCmmCall fun_expr res' args' updfr_off
      else
        mkUnsafeCall (ForeignTarget fun_expr
                         (ForeignConvention CCallConv arg_hints res_hints)) res' args'
    (args', arg_hints) = unzip args
    (res',  res_hints) = unzip res
    (caller_save, caller_load) = callerSaveVolatileRegs
    fun_expr = mkLblExpr (mkCmmCodeLabel pkg fun)


-----------------------------------------------------------------------------
--
--	Caller-Save Registers
--
-----------------------------------------------------------------------------

-- Here we generate the sequence of saves/restores required around a
-- foreign call instruction.

-- TODO: reconcile with includes/Regs.h
--  * Regs.h claims that BaseReg should be saved last and loaded first
--    * This might not have been tickled before since BaseReg is callee save
--  * Regs.h saves SparkHd, ParkT1, SparkBase and SparkLim
callerSaveVolatileRegs :: (CmmAGraph, CmmAGraph)
callerSaveVolatileRegs = (caller_save, caller_load)
  where
    caller_save = catAGraphs (map callerSaveGlobalReg    regs_to_save)
    caller_load = catAGraphs (map callerRestoreGlobalReg regs_to_save)

    system_regs = [ Sp,SpLim,Hp,HpLim,CurrentTSO,CurrentNursery
		    {- ,SparkHd,SparkTl,SparkBase,SparkLim -}
		  , BaseReg ]

    regs_to_save = filter callerSaves system_regs

    callerSaveGlobalReg reg
	= mkStore (get_GlobalReg_addr reg) (CmmReg (CmmGlobal reg))

    callerRestoreGlobalReg reg
	= mkAssign (CmmGlobal reg)
		    (CmmLoad (get_GlobalReg_addr reg) (globalRegType reg))

-- -----------------------------------------------------------------------------
-- Global registers

-- We map STG registers onto appropriate CmmExprs.  Either they map
-- to real machine registers or stored as offsets from BaseReg.  Given
-- a GlobalReg, get_GlobalReg_addr always produces the 
-- register table address for it.
-- (See also get_GlobalReg_reg_or_addr in MachRegs)

get_GlobalReg_addr              :: GlobalReg -> CmmExpr
get_GlobalReg_addr BaseReg = regTableOffset 0
get_GlobalReg_addr mid     = get_Regtable_addr_from_offset 
				(globalRegType mid) (baseRegOffset mid)

-- Calculate a literal representing an offset into the register table.
-- Used when we don't have an actual BaseReg to offset from.
regTableOffset :: Int -> CmmExpr
regTableOffset n = 
  CmmLit (CmmLabelOff mkMainCapabilityLabel (oFFSET_Capability_r + n))

get_Regtable_addr_from_offset :: CmmType -> Int -> CmmExpr
get_Regtable_addr_from_offset _rep offset =
#ifdef REG_Base
  CmmRegOff (CmmGlobal BaseReg) offset
#else
  regTableOffset offset
#endif


-- | Returns 'True' if this global register is stored in a caller-saves
-- machine register.

callerSaves :: GlobalReg -> Bool

#ifdef CALLER_SAVES_Base
callerSaves BaseReg		= True
#endif
#ifdef CALLER_SAVES_Sp
callerSaves Sp			= True
#endif
#ifdef CALLER_SAVES_SpLim
callerSaves SpLim		= True
#endif
#ifdef CALLER_SAVES_Hp
callerSaves Hp			= True
#endif
#ifdef CALLER_SAVES_HpLim
callerSaves HpLim		= True
#endif
#ifdef CALLER_SAVES_CurrentTSO
callerSaves CurrentTSO		= True
#endif
#ifdef CALLER_SAVES_CurrentNursery
callerSaves CurrentNursery	= True
#endif
callerSaves _			= False


-- -----------------------------------------------------------------------------
-- Information about global registers

baseRegOffset :: GlobalReg -> Int

baseRegOffset Sp		  = oFFSET_StgRegTable_rSp
baseRegOffset SpLim		  = oFFSET_StgRegTable_rSpLim
baseRegOffset (LongReg 1)         = oFFSET_StgRegTable_rL1
baseRegOffset Hp		  = oFFSET_StgRegTable_rHp
baseRegOffset HpLim		  = oFFSET_StgRegTable_rHpLim
baseRegOffset CurrentTSO	  = oFFSET_StgRegTable_rCurrentTSO
baseRegOffset CurrentNursery	  = oFFSET_StgRegTable_rCurrentNursery
baseRegOffset HpAlloc		  = oFFSET_StgRegTable_rHpAlloc
baseRegOffset GCEnter1		  = oFFSET_stgGCEnter1
baseRegOffset GCFun		  = oFFSET_stgGCFun
baseRegOffset reg		  = pprPanic "baseRegOffset:" (ppr reg)

-------------------------------------------------------------------------
--
--	Strings generate a top-level data block
--
-------------------------------------------------------------------------

emitDataLits :: CLabel -> [CmmLit] -> FCode ()
-- Emit a data-segment data block
emitDataLits lbl lits
  = emitData Data (CmmDataLabel lbl : map CmmStaticLit lits)

mkDataLits :: CLabel -> [CmmLit] -> GenCmmTop CmmStatic info stmt
-- Emit a data-segment data block
mkDataLits lbl lits
  = CmmData Data (CmmDataLabel lbl : map CmmStaticLit lits)

emitRODataLits :: CLabel -> [CmmLit] -> FCode ()
-- Emit a read-only data block
emitRODataLits lbl lits
  = emitData section (CmmDataLabel lbl : map CmmStaticLit lits)
  where section | any needsRelocation lits = RelocatableReadOnlyData
                | otherwise                = ReadOnlyData
        needsRelocation (CmmLabel _)      = True
        needsRelocation (CmmLabelOff _ _) = True
        needsRelocation _                 = False

mkRODataLits :: CLabel -> [CmmLit] -> GenCmmTop CmmStatic info stmt
mkRODataLits lbl lits
  = CmmData section (CmmDataLabel lbl : map CmmStaticLit lits)
  where section | any needsRelocation lits = RelocatableReadOnlyData
                | otherwise                = ReadOnlyData
        needsRelocation (CmmLabel _)      = True
        needsRelocation (CmmLabelOff _ _) = True
        needsRelocation _                 = False

mkStringCLit :: String -> FCode CmmLit
-- Make a global definition for the string,
-- and return its label
mkStringCLit str = mkByteStringCLit (map (fromIntegral . ord) str)

mkByteStringCLit :: [Word8] -> FCode CmmLit
mkByteStringCLit bytes
  = do 	{ uniq <- newUnique
	; let lbl = mkStringLitLabel uniq
	; emitData ReadOnlyData [CmmDataLabel lbl, CmmString bytes]
	; return (CmmLabel lbl) }

-------------------------------------------------------------------------
--
--	Assigning expressions to temporaries
--
-------------------------------------------------------------------------

assignTemp :: CmmExpr -> FCode LocalReg
-- Make sure the argument is in a local register
assignTemp (CmmReg (CmmLocal reg)) = return reg
assignTemp e = do { uniq <- newUnique
		  ; let reg = LocalReg uniq (cmmExprType e)
		  ; emit (mkAssign (CmmLocal reg) e)
		  ; return reg }

newTemp :: CmmType -> FCode LocalReg
newTemp rep = do { uniq <- newUnique
		 ; return (LocalReg uniq rep) }

newUnboxedTupleRegs :: Type -> FCode ([LocalReg], [ForeignHint])
-- Choose suitable local regs to use for the components
-- of an unboxed tuple that we are about to return to 
-- the Sequel.  If the Sequel is a join point, using the
-- regs it wants will save later assignments.
newUnboxedTupleRegs res_ty 
  = ASSERT( isUnboxedTupleType res_ty )
    do	{ sequel <- getSequel
	; regs <- choose_regs sequel
	; ASSERT( regs `equalLength` reps )
	  return (regs, map primRepForeignHint reps) }
  where
    ty_args = tyConAppArgs (repType res_ty)
    reps = [ rep
	   | ty <- ty_args
    	   , let rep = typePrimRep ty
  	   , not (isVoidRep rep) ]
    choose_regs (AssignTo regs _) = return regs
    choose_regs _other		  = mapM (newTemp . primRepCmmType) reps



-------------------------------------------------------------------------
--	mkMultiAssign
-------------------------------------------------------------------------

mkMultiAssign :: [LocalReg] -> [CmmExpr] -> CmmAGraph
-- Emit code to perform the assignments in the
-- input simultaneously, using temporary variables when necessary.

type Key  = Int
type Vrtx = (Key, Stmt)	-- Give each vertex a unique number,
			-- for fast comparison
type Stmt = (LocalReg, CmmExpr)	-- r := e

-- We use the strongly-connected component algorithm, in which
--	* the vertices are the statements
--	* an edge goes from s1 to s2 iff
--		s1 assigns to something s2 uses
--	  that is, if s1 should *follow* s2 in the final order

mkMultiAssign []    []    = mkNop
mkMultiAssign [reg] [rhs] = mkAssign (CmmLocal reg) rhs
mkMultiAssign regs  rhss  = ASSERT( equalLength regs rhss )
			    unscramble ([1..] `zip` (regs `zip` rhss))

unscramble :: [Vrtx] -> CmmAGraph
unscramble vertices
  = catAGraphs (map do_component components)
  where
	edges :: [ (Vrtx, Key, [Key]) ]
	edges = [ (vertex, key1, edges_from stmt1)
		| vertex@(key1, stmt1) <- vertices ]

	edges_from :: Stmt -> [Key]
	edges_from stmt1 = [ key2 | (key2, stmt2) <- vertices, 
				    stmt1 `mustFollow` stmt2 ]

	components :: [SCC Vrtx]
	components = stronglyConnCompFromEdgedVertices edges

	-- do_components deal with one strongly-connected component
	-- Not cyclic, or singleton?  Just do it
	do_component :: SCC Vrtx -> CmmAGraph
	do_component (AcyclicSCC (_,stmt))  = mk_graph stmt
	do_component (CyclicSCC []) 	    = panic "do_component"
	do_component (CyclicSCC [(_,stmt)]) = mk_graph stmt

		-- Cyclic?  Then go via temporaries.  Pick one to
		-- break the loop and try again with the rest.
	do_component (CyclicSCC ((_,first_stmt) : rest))
	  = withUnique 		$ \u -> 
	    let (to_tmp, from_tmp) = split u first_stmt
	    in mk_graph to_tmp
	       <*> unscramble rest
	       <*> mk_graph from_tmp

	split :: Unique -> Stmt -> (Stmt, Stmt)
	split uniq (reg, rhs)
	  = ((tmp, rhs), (reg, CmmReg (CmmLocal tmp)))
	  where
	    rep = cmmExprType rhs
	    tmp = LocalReg uniq rep

	mk_graph :: Stmt -> CmmAGraph
	mk_graph (reg, rhs) = mkAssign (CmmLocal reg) rhs

mustFollow :: Stmt -> Stmt -> Bool
(reg, _) `mustFollow` (_, rhs) = reg `regUsedIn` rhs

regUsedIn :: LocalReg -> CmmExpr -> Bool
reg  `regUsedIn` CmmLoad e  _ 	 	     = reg `regUsedIn` e
reg  `regUsedIn` CmmReg (CmmLocal reg')      = reg == reg'
reg  `regUsedIn` CmmRegOff (CmmLocal reg') _ = reg == reg'
reg  `regUsedIn` CmmMachOp _ es   	     = any (reg `regUsedIn`) es
_reg `regUsedIn` _other		 	     = False    	-- The CmmGlobal cases

-------------------------------------------------------------------------
--	mkSwitch
-------------------------------------------------------------------------


emitSwitch :: CmmExpr  		-- Tag to switch on
	   -> [(ConTagZ, CmmAGraph)]	-- Tagged branches
	   -> Maybe CmmAGraph	    	-- Default branch (if any)
	   -> ConTagZ -> ConTagZ	-- Min and Max possible values; behaviour
	    			        -- 	outside this range is undefined
	   -> FCode ()
emitSwitch tag_expr branches mb_deflt lo_tag hi_tag
  = do	{ dflags <- getDynFlags
	; emit (mkCmmSwitch (via_C dflags) tag_expr branches mb_deflt lo_tag hi_tag) }
  where
    via_C dflags | HscC <- hscTarget dflags = True
		 | otherwise                = False


mkCmmSwitch :: Bool			-- True <=> never generate a conditional tree
	    -> CmmExpr  		-- Tag to switch on
	    -> [(ConTagZ, CmmAGraph)]	-- Tagged branches
	    -> Maybe CmmAGraph	    	-- Default branch (if any)
	    -> ConTagZ -> ConTagZ	-- Min and Max possible values; behaviour
	    			        -- 	outside this range is undefined
	    -> CmmAGraph

-- First, two rather common cases in which there is no work to do
mkCmmSwitch _ _ []         (Just code) _ _ = code
mkCmmSwitch _ _ [(_,code)] Nothing     _ _ = code

-- Right, off we go
mkCmmSwitch via_C tag_expr branches mb_deflt lo_tag hi_tag
  = withFreshLabel "switch join" 	$ \ join_lbl ->
    label_default join_lbl mb_deflt	$ \ mb_deflt ->
    label_branches join_lbl branches	$ \ branches ->
    assignTemp' tag_expr		$ \tag_expr' -> 
    
    mk_switch tag_expr' (sortLe le branches) mb_deflt 
	      lo_tag hi_tag via_C
	  -- Sort the branches before calling mk_switch
    <*> mkLabel join_lbl

  where
    (t1,_) `le` (t2,_) = t1 <= t2

mk_switch :: CmmExpr -> [(ConTagZ, BlockId)]
	  -> Maybe BlockId 
	  -> ConTagZ -> ConTagZ -> Bool
	  -> CmmAGraph

-- SINGLETON TAG RANGE: no case analysis to do
mk_switch _tag_expr [(tag, lbl)] _ lo_tag hi_tag _via_C
  | lo_tag == hi_tag
  = ASSERT( tag == lo_tag )
    mkBranch lbl

-- SINGLETON BRANCH, NO DEFAULT: no case analysis to do
mk_switch _tag_expr [(_tag,lbl)] Nothing _ _ _
  = mkBranch lbl
	-- The simplifier might have eliminated a case
	-- 	 so we may have e.g. case xs of 
	--				 [] -> e
	-- In that situation we can be sure the (:) case 
	-- can't happen, so no need to test

-- SINGLETON BRANCH: one equality check to do
mk_switch tag_expr [(tag,lbl)] (Just deflt) _ _ _
  = mkCbranch cond deflt lbl
  where
    cond =  cmmNeWord tag_expr (CmmLit (mkIntCLit tag))
	-- We have lo_tag < hi_tag, but there's only one branch, 
	-- so there must be a default

-- ToDo: we might want to check for the two branch case, where one of
-- the branches is the tag 0, because comparing '== 0' is likely to be
-- more efficient than other kinds of comparison.

-- DENSE TAG RANGE: use a switch statment.
--
-- We also use a switch uncoditionally when compiling via C, because
-- this will get emitted as a C switch statement and the C compiler
-- should do a good job of optimising it.  Also, older GCC versions
-- (2.95 in particular) have problems compiling the complicated
-- if-trees generated by this code, so compiling to a switch every
-- time works around that problem.
--
mk_switch tag_expr branches mb_deflt lo_tag hi_tag via_C
  | use_switch 	-- Use a switch
  = let 
	find_branch :: ConTagZ -> Maybe BlockId
	find_branch i = case (assocMaybe branches i) of
			  Just lbl -> Just lbl
			  Nothing  -> mb_deflt

	-- NB. we have eliminated impossible branches at
	-- either end of the range (see below), so the first
	-- tag of a real branch is real_lo_tag (not lo_tag).
	arms :: [Maybe BlockId]
	arms = [ find_branch i | i <- [real_lo_tag..real_hi_tag]]
    in
    mkSwitch (cmmOffset tag_expr (- real_lo_tag)) arms

  -- if we can knock off a bunch of default cases with one if, then do so
  | Just deflt <- mb_deflt, (lowest_branch - lo_tag) >= n_branches
  = mkCmmIfThenElse 
	(cmmULtWord tag_expr (CmmLit (mkIntCLit lowest_branch)))
	(mkBranch deflt)
	(mk_switch tag_expr branches mb_deflt 
			lowest_branch hi_tag via_C)

  | Just deflt <- mb_deflt, (hi_tag - highest_branch) >= n_branches
  = mkCmmIfThenElse 
	(cmmUGtWord tag_expr (CmmLit (mkIntCLit highest_branch)))
	(mkBranch deflt)
	(mk_switch tag_expr branches mb_deflt 
			lo_tag highest_branch via_C)

  | otherwise	-- Use an if-tree
  = mkCmmIfThenElse 
	(cmmUGeWord tag_expr (CmmLit (mkIntCLit mid_tag)))
	(mk_switch tag_expr hi_branches mb_deflt 
			     mid_tag hi_tag via_C)
	(mk_switch tag_expr lo_branches mb_deflt 
			     lo_tag (mid_tag-1) via_C)
	-- we test (e >= mid_tag) rather than (e < mid_tag), because
	-- the former works better when e is a comparison, and there
	-- are two tags 0 & 1 (mid_tag == 1).  In this case, the code
	-- generator can reduce the condition to e itself without
	-- having to reverse the sense of the comparison: comparisons
	-- can't always be easily reversed (eg. floating
	-- pt. comparisons).
  where
    use_switch 	 = {- pprTrace "mk_switch" (
			ppr tag_expr <+> text "n_tags:" <+> int n_tags <+>
                        text "branches:" <+> ppr (map fst branches) <+>
			text "n_branches:" <+> int n_branches <+>
			text "lo_tag:" <+> int lo_tag <+>
			text "hi_tag:" <+> int hi_tag <+>
			text "real_lo_tag:" <+> int real_lo_tag <+>
			text "real_hi_tag:" <+> int real_hi_tag) $ -}
		   ASSERT( n_branches > 1 && n_tags > 1 ) 
		   n_tags > 2 && (via_C || (dense && big_enough))
		 -- up to 4 branches we use a decision tree, otherwise
                 -- a switch (== jump table in the NCG).  This seems to be
                 -- optimal, and corresponds with what gcc does.
    big_enough 	 = n_branches > 4
    dense      	 = n_branches > (n_tags `div` 2)
    n_branches   = length branches
    
    -- ignore default slots at each end of the range if there's 
    -- no default branch defined.
    lowest_branch  = fst (head branches)
    highest_branch = fst (last branches)

    real_lo_tag
	| isNothing mb_deflt = lowest_branch
	| otherwise          = lo_tag

    real_hi_tag
	| isNothing mb_deflt = highest_branch
	| otherwise          = hi_tag

    n_tags = real_hi_tag - real_lo_tag + 1

	-- INVARIANT: Provided hi_tag > lo_tag (which is true)
	--	lo_tag <= mid_tag < hi_tag
	--	lo_branches have tags <  mid_tag
	--	hi_branches have tags >= mid_tag

    (mid_tag,_) = branches !! (n_branches `div` 2)
	-- 2 branches => n_branches `div` 2 = 1
	--	      => branches !! 1 give the *second* tag
	-- There are always at least 2 branches here

    (lo_branches, hi_branches) = span is_lo branches
    is_lo (t,_) = t < mid_tag

--------------
mkCmmLitSwitch :: CmmExpr		  -- Tag to switch on
	       -> [(Literal, CmmAGraph)]  -- Tagged branches
	       -> CmmAGraph		  -- Default branch (always)
	       -> CmmAGraph		  -- Emit the code
-- Used for general literals, whose size might not be a word, 
-- where there is always a default case, and where we don't know
-- the range of values for certain.  For simplicity we always generate a tree.
--
-- ToDo: for integers we could do better here, perhaps by generalising
-- mk_switch and using that.  --SDM 15/09/2004
mkCmmLitSwitch _scrut []       deflt = deflt
mkCmmLitSwitch scrut  branches deflt
  = assignTemp' scrut		$ \ scrut' ->
    withFreshLabel "switch join" 	$ \ join_lbl ->
    label_code join_lbl deflt		$ \ deflt ->
    label_branches join_lbl branches	$ \ branches ->
    mk_lit_switch scrut' deflt (sortLe le branches)
    <*> mkLabel join_lbl
  where
    le (t1,_) (t2,_) = t1 <= t2

mk_lit_switch :: CmmExpr -> BlockId 
 	      -> [(Literal,BlockId)]
	      -> CmmAGraph
mk_lit_switch scrut deflt [(lit,blk)] 
  = mkCbranch (CmmMachOp ne [scrut, CmmLit cmm_lit]) deflt blk
  where
    cmm_lit = mkSimpleLit lit
    cmm_ty  = cmmLitType cmm_lit
    rep     = typeWidth cmm_ty
    ne      = if isFloatType cmm_ty then MO_F_Ne rep else MO_Ne rep

mk_lit_switch scrut deflt_blk_id branches
  = mkCmmIfThenElse cond
	(mk_lit_switch scrut deflt_blk_id lo_branches)
	(mk_lit_switch scrut deflt_blk_id hi_branches)
  where
    n_branches = length branches
    (mid_lit,_) = branches !! (n_branches `div` 2)
	-- See notes above re mid_tag

    (lo_branches, hi_branches) = span is_lo branches
    is_lo (t,_) = t < mid_lit

    cond = CmmMachOp (mkLtOp mid_lit) 
			[scrut, CmmLit (mkSimpleLit mid_lit)]


--------------
label_default :: BlockId -> Maybe CmmAGraph
	      -> (Maybe BlockId -> CmmAGraph)
	      -> CmmAGraph
label_default _ Nothing thing_inside 
  = thing_inside Nothing
label_default join_lbl (Just code) thing_inside 
  = label_code join_lbl code 	$ \ lbl ->
    thing_inside (Just lbl)

--------------
label_branches :: BlockId -> [(a,CmmAGraph)]
	       -> ([(a,BlockId)] -> CmmAGraph) 
	       -> CmmAGraph
label_branches _join_lbl [] thing_inside 
  = thing_inside []
label_branches join_lbl ((tag,code):branches) thing_inside
  = label_code join_lbl code		$ \ lbl ->
    label_branches join_lbl branches 	$ \ branches' ->
    thing_inside ((tag,lbl):branches')

--------------
label_code :: BlockId -> CmmAGraph -> (BlockId -> CmmAGraph) -> CmmAGraph
-- (label_code J code fun)
--	generates
--  [L: code; goto J] fun L
label_code join_lbl code thing_inside
  = withFreshLabel "switch" 	$ \lbl -> 
    outOfLine (mkLabel lbl <*> code <*> mkBranch join_lbl)
    <*> thing_inside lbl
 

--------------
assignTemp' :: CmmExpr -> (CmmExpr -> CmmAGraph) -> CmmAGraph
assignTemp' e thing_inside
  | isTrivialCmmExpr e = thing_inside e
  | otherwise          = withTemp (cmmExprType e)	$ \ lreg ->
			 let reg = CmmLocal lreg in 
			 mkAssign reg e <*> thing_inside (CmmReg reg)

withTemp :: CmmType -> (LocalReg -> CmmAGraph) -> CmmAGraph
withTemp rep thing_inside
  = withUnique $ \uniq -> thing_inside (LocalReg uniq rep)


-------------------------------------------------------------------------
--
--	Static Reference Tables
--
-------------------------------------------------------------------------

-- There is just one SRT for each top level binding; all the nested
-- bindings use sub-sections of this SRT.  The label is passed down to
-- the nested bindings via the monad.

getSRTInfo :: SRT -> FCode C_SRT
getSRTInfo (SRTEntries {}) = panic "getSRTInfo"

getSRTInfo (SRT off len bmp)
  | len > hALF_WORD_SIZE_IN_BITS || bmp == [fromIntegral srt_escape]
  = do 	{ id <- newUnique
	-- ; top_srt <- getSRTLabel
        ; let srt_desc_lbl = mkLargeSRTLabel id
        -- JD: We're not constructing and emitting SRTs in the back end,
        -- which renders this code wrong (it now names a now-non-existent label).
	-- ; emitRODataLits srt_desc_lbl
        --      ( cmmLabelOffW top_srt off
	--        : mkWordCLit (fromIntegral len)
	--        : map mkWordCLit bmp)
	; return (C_SRT srt_desc_lbl 0 srt_escape) }

  | otherwise
  = do	{ top_srt <- getSRTLabel
	; return (C_SRT top_srt off (fromIntegral (head bmp))) }
	-- The fromIntegral converts to StgHalfWord

getSRTInfo NoSRT 
  = -- TODO: Should we panic in this case?
    -- Someone obviously thinks there should be an SRT
    return NoC_SRT


srt_escape :: StgHalfWord
srt_escape = -1
