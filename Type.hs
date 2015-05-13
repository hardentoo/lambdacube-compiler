{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE UndecidableInstances #-}
module Type where

import Data.Char
import Data.Either
import Data.String
import Data.Maybe
import Data.List
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Monoid
import Data.Foldable hiding (foldr)
import Data.Traversable
import Control.Monad.Except
import Control.Monad.State
import Control.Monad.Identity
import Control.Monad.Reader
import Control.Applicative
import Control.Arrow hiding ((<+>))
import Text.Parsec.Pos
import GHC.Exts (Constraint)
import Debug.Trace

import ParserUtil (ParseError)
import Pretty

-------------------------------------------------------------------------------- literals

data Lit
    = LInt    Integer
    | LNat    Int
    | LChar   Char
    | LString String
    | LFloat  Double
    deriving (Eq, Ord)

-------------------------------------------------------------------------------- types

data Constraint' n a
    = CEq a (TypeFun n a) -- unification between a type and a fully applied type function; CEq t f:  t ~ f
    | CUnify a a          -- unification between (non-type-function) types; CUnify t s:  t ~ s
    | CClass n a          -- class constraint
    | Split a a a         -- Split x y z:  x, y, z are records; fields of x = disjoint union of the fields of y and z
    deriving (Eq,Ord,Functor,Foldable,Traversable)

mapConstraint :: (n -> n') -> (a -> a') -> Constraint' n a -> Constraint' n' a'
mapConstraint nf af = \case
    CEq a (TypeFun n as) -> CEq (af a) (TypeFun (nf n) (af <$> as))
    CUnify a1 a2 -> CUnify (af a1) (af a2)
    CClass n a -> CClass (nf n) (af a)
    Split a1 a2 a3 -> Split (af a1) (af a2) (af a3)

data TypeFun n a = TypeFun n [a]
    deriving (Eq,Ord,Functor,Foldable,Traversable)

data Witness
    = Refl
    | WInstance (Env Thunk)
    deriving (Eq, Ord)

-- TODO: remove
instance Eq Thunk where
instance Ord Thunk where

--------------------------------------------

data Void

instance PShow Void
instance Eq Void
instance Ord Void

newtype Ty' n m = Ty'' (m (Exp_ () n Void Void (Ty' n m)))

pattern Ty' a b = Ty'' (a, b)
type TyR = Ty' Name WithRange

-------------------------------------------- kinded types

data Ty
    = Ty (Exp_ Ty IdN Void Void Ty)
    | StarToStar !Int   -- TODO: remove

instance Eq Ty where
    StarToStar i == StarToStar j = i == j
    Ty b == Ty b' = b == b'
    _ == _ = False
instance Ord Ty where
    StarToStar i `compare` StarToStar j = i `compare` j
    Ty b `compare` Ty b' = b `compare` b'
    StarToStar _ `compare` _ = LT
    _ `compare` _ = GT

pattern Ty_ b <- Ty b where
    Ty_ Star_ = Star
    Ty_ b = Ty b

unfoldTy (StarToStar i) = Ty $ case i of
    0 -> Star_
    _ -> Forall_ Nothing Star $ StarToStar $ i - 1
unfoldTy x = x

pattern Ty__ b <- (unfoldTy -> Ty b) where
    Ty__ Star_ = Star
    Ty__ b = Ty b

pattern TApp k a b = Ty_ (EApp_ k a b)
pattern TCon k a <- Ty_ (TCon_ k (TypeIdN a)) where
    TCon k a = Ty_ (TCon_ k (TypeIdN' a "typecon"))
pattern TVar k b = Ty_ (EVar_ k b)
pattern TLit b = Ty_ (ELit_ b)

pattern Star = StarToStar 0

pattern TyStar a = Ty_ a
pattern TRecord b = TyStar (TRecord_ b)
pattern TTuple b = TyStar (TTuple_ b)
pattern TUnit = TTuple []
pattern ConstraintKind c = TyStar (ConstraintKind_ c)
pattern Forall a b c = TyStar (Forall_ (Just a) b c)
pattern TArr a b <- TyStar (Forall_ Nothing a b) where
    TArr Star (StarToStar i) = StarToStar (i + 1)
    TArr a b = TyStar (Forall_ Nothing a b)

infixr 7 ~>, ~~>
a ~> b = TArr a b

(~~>) :: [Ty] -> Ty -> Ty
args ~~> res = foldr (~>) res args

infix 4 ~~, ~~~
(~~) = CEq
(~~~) = CUnify

inferLit :: Lit -> Ty
inferLit a = case a of
    LInt _    -> TInt
    LChar _   -> TChar
    LFloat _  -> TFloat
    LString _ -> TString
    LNat _    -> TNat


kindOf :: Ty -> Ty
kindOf = \case
    Ty__ t -> case t of
        ELit_ l -> inferLit l
        EVar_ k _ -> k
        EApp_ k _ _ -> k
--        ETuple_    [b]
--        ELam_      p b
--        ETypeSig_ b t -> t  -- TODO?
--        EType_ t -> kindOf t        -- ??
{-
        | ELet_      p b b
        | ENamedRecord_ Name [(Name, b)]
        | ERecord_   [(Name, b)]
        | EFieldProj_ Name
        | EAlts_     Int [b]  -- function alternatives; Int: arity
        | ENext_              -- go to next alternative
        | ExtractInstance [b] Int Name
        | PrimFun Name [b] Int
-}
        -- was types
        Star_ -> Star
        TCon_ k _ -> k
        Forall_ _ _ _ -> Star
        TTuple_ _ -> Star
        TRecord_ _ -> Star
        ConstraintKind_ _ -> Star
        Witness k _ -> k
        _ -> error "kindOf"

isStar = \case
    Star -> True
    _ -> False

-------------------------------------------------------------------------------- patterns

data Pat_ c v b
    = PLit_ Lit
    | PVar_ v
    | PCon_ c [b]
    | PTuple_ [b]
    | PRecord_ [(Name, b)]
    | PAt_ v b
    | Wildcard_
    deriving (Functor,Foldable,Traversable)

mapPat :: (c -> c') -> (v -> v') -> Pat_ c v b -> Pat_ c' v' b
mapPat f g = \case
    PLit_ l -> PLit_ l
    PVar_ v -> PVar_ $ g v
    PCon_ c p -> PCon_ (f c) p
    PTuple_ p -> PTuple_ p
    PRecord_ p -> PRecord_ p -- $ map (g *** id) p
    PAt_ v p -> PAt_ (g v) p
    Wildcard_ -> Wildcard_

--------------------------------------------

newtype Pat' c n m = Pat' (m (Pat_ c n (Pat' c n m)))

pattern Pat a b = Pat' (a, b)
pattern PVar' a b = Pat a (PVar_ b)
pattern PCon' a b c = Pat a (PCon_ b c)

--------------------------------------------

type Pat = Pat' Var Var Identity

pattern Pat'' a = Pat' (Identity a)

pattern PAt v l = Pat'' (PAt_ v l)
pattern PLit l = Pat'' (PLit_ l)
pattern PVar l = Pat'' (PVar_ l)
pattern PCon c l = Pat'' (PCon_ c l)
pattern PTuple l = Pat'' (PTuple_ l)
pattern Wildcard = Pat'' Wildcard_

-------------------------------------------------------------------------------- expressions

data Exp_ k v t p b       -- TODO: elim t parameter
    = ELit_      Lit      -- could be replaced by EType + ELit
    | EVar_      k v
    | EApp_      k b b
    | ETuple_    [b]
    | ELam_      p b
    | ETypeSig_  b t
    | EType_     t          -- TODO: elim

    | ELet_      p b b
    | ENamedRecord_ Name [(Name, b)]
    | ERecord_   [(Name, b)]
    | EFieldProj_ Name
    | EAlts_     Int [b]  -- function alternatives; Int: arity
    | ENext_              -- go to next alternative
    | ExtractInstance [b] Int Name
    | PrimFun Name [b] Int

    -- was types
    | Star_
    | TCon_    k v
    -- | TFun_    f [a]    -- TODO
    | Forall_  (Maybe v) b b
    | TTuple_  [b]
    | TRecord_ (Map v b)
    | ConstraintKind_ (Constraint' v b)        -- flatten?
    | Witness  k Witness      -- TODO: make this polymorphic
    deriving (Eq,Ord,Functor,Foldable,Traversable) -- TODO: elim Eq instance


mapExp :: Ord v' => (v -> v') -> (t -> t') -> (p -> p') -> Exp_ k v t p b -> Exp_ k v' t' p' b
mapExp = mapExp_ id

mapKind :: Ord v => (k -> k') -> Exp_ k v t p b -> Exp_ k' v t p b
mapKind f = mapExp_ f id id id

mapExp_ :: Ord v' => (k -> k') -> (v -> v') -> (t -> t') -> (p -> p') -> Exp_ k v t p b -> Exp_ k' v' t' p' b
mapExp_ kf vf tf f = \case
    ELit_      x       -> ELit_ x
    EVar_      k x       -> EVar_ (kf k) $ vf x
    EApp_      k x y     -> EApp_ (kf k) x y
    ELam_      x y     -> ELam_ (f x) y
    ELet_      x y z   -> ELet_ (f x) y z
    ETuple_    x       -> ETuple_ x
    ERecord_   x       -> ERecord_ $ x --map (vf *** id) x
    ENamedRecord_ n x  -> ENamedRecord_ n x --(vf n) $ map (vf *** id) x
    EFieldProj_ x      -> EFieldProj_ x -- $ vf x
    ETypeSig_  x y     -> ETypeSig_ x $ tf y
    EAlts_     x y     -> EAlts_ x y
    ENext_             -> ENext_
    EType_ t           -> EType_ $ tf t
    ExtractInstance i j n -> ExtractInstance i j n
    PrimFun a b c      -> PrimFun a b c
    Star_              -> Star_
    TCon_    k v       -> TCon_ (kf k) (vf v)
    -- | TFun_    f [a]    -- TODO
    Forall_  mv b1 b2  -> Forall_ (vf <$> mv) b1 b2
    TTuple_  bs        -> TTuple_ bs
    TRecord_ m         -> TRecord_ $ Map.fromList $ map (vf *** id) $ Map.toList m -- (Map v b)
    ConstraintKind_ c  -> ConstraintKind_ $ mapConstraint vf id c
    Witness  k w       -> Witness (kf k) w


--------------------------------------------

data Exp' n t p m = Exp' (m (Exp_ () n t p (Exp' n t p m)))

pattern Exp a b = Exp' (a, b)
pattern ELit' a b = Exp a (ELit_ b)
pattern EVar' a b = Exp a (EVar_ () b)
pattern EApp' a b c = Exp a (EApp_ () b c)
pattern ELam' a b c = Exp a (ELam_ b c)
pattern ELet' a b c d = Exp a (ELet_ b c d)
pattern ETuple' a b = Exp a (ETuple_ b)
pattern ERecord' a b = Exp a (ERecord_ b)
pattern ENamedRecord' a n b = Exp a (ENamedRecord_ n b)
pattern EFieldProj' a c = Exp a (EFieldProj_ c)
pattern ETypeSig' a b c = Exp a (ETypeSig_ b c)
pattern EAlts' a i b = Exp a (EAlts_ i b)
pattern ENext' a = Exp a ENext_
pattern EType' a b = Exp a (EType_ b)

--------------------------------------------

type Exp = Exp' Var Ty Pat Identity

pattern Exp'' a = Exp' (Identity a)
pattern ELit a = Exp'' (ELit_ a)
pattern EVar a = Exp'' (EVar_ () a)
pattern EApp a b = Exp'' (EApp_ () a b)
pattern ELam a b = Exp'' (ELam_ a b)
pattern ELet a b c = Exp'' (ELet_ a b c)
pattern ETuple a = Exp'' (ETuple_ a)
pattern ERecord b = Exp'' (ERecord_ b)
pattern EFieldProj a = Exp'' (EFieldProj_ a)
pattern EType a = Exp'' (EType_ a)
pattern EAlts i b = Exp'' (EAlts_ i b)
pattern ENext = Exp'' ENext_

pattern EInt a = ELit (LInt a)
pattern EFloat a = ELit (LFloat a)

pattern Va x <- VarE (ExpIdN x) _
pattern A0 x <- EVar (Va x)
pattern A1 f x <- EApp (A0 f) x
pattern A2 f x y <- EApp (A1 f x) y
pattern A3 f x y z <- EApp (A2 f x y) z
pattern A4 f x y z v <- EApp (A3 f x y z) v
pattern A5 f x y z v w <-  EApp (A4 f x y z v) w
pattern A6 f x y z v w q <-  EApp (A5 f x y z v w) q
pattern A7 f x y z v w q r <-  EApp (A6 f x y z v w q) r
pattern A8 f x y z v w q r s <-  EApp (A7 f x y z v w q r) s
pattern A9 f x y z v w q r s t <-  EApp (A8 f x y z v w q r s) t
pattern A10 f x y z v w q r s t a <-  EApp (A9 f x y z v w q r s t) a
pattern A11 f x y z v w q r s t a b <-  EApp (A10 f x y z v w q r s t a) b

--------------------------------------------

type Thunk = Exp' Var Ty Pat ((,) TEnv)
type Thunk' = Exp_ () Var Ty Pat Thunk

-------------------------------------------------------------------------------- tag handling

class GetTag c where
    type Tag c
    getTag :: c -> Tag c

instance GetTag (Exp' n t p ((,) a)) where
    type Tag (Exp' n t p ((,) a)) = a
    getTag (Exp a _) = a
instance GetTag (Ty' n ((,) a)) where
    type Tag (Ty' n ((,) a)) = a
    getTag (Ty' k _) = k
instance GetTag (Pat' c n ((,) a)) where
    type Tag (Pat' c n ((,) a)) = a
    getTag (Pat a _) = a


-------------------------------------------------------------------------------- names

data NameSpace = TypeNS | ExpNS
    deriving (Eq, Ord)

-- TODO: more structure instead of Doc
data NameInfo = NameInfo (Maybe Fixity) Doc

data N = N
    { nameSpace :: NameSpace
    , qualifier :: [String]
    , nName :: String
    , nameInfo :: NameInfo
    }

instance Eq N where N a b c d == N a' b' c' d' = (a, b, c) == (a', b', c')
instance Ord N where N a b c d `compare` N a' b' c' d' = (a, b, c) `compare` (a', b', c')

type Fixity = (Maybe FixityDir, Int)
data FixityDir = FDLeft | FDRight

pattern ExpN n <- N ExpNS [] n _ where
    ExpN n = N ExpNS [] n (NameInfo Nothing "exp")
pattern ExpN' n i = N ExpNS [] n (NameInfo Nothing i)
pattern TypeN n <- N TypeNS [] n _
pattern TypeN' n i = N TypeNS [] n (NameInfo Nothing i)

-- TODO: rename/eliminate
type Name = N
type TName = N
type TCName = N    -- type constructor name; if this turns out to be slow use Int or ADT instead of String
type EName = N
type FName = N
type MName = N     -- module name
type ClassName = N

toExpN (N _ a b i) = N ExpNS a b i
toTypeN (N _ a b i) = N TypeNS a b i
isTypeVar (N ns _ _ _) = ns == TypeNS
isConstr (N _ _ (c:_) _) = isUpper c || c == ':'

data Var = VarE IdN Ty
    deriving (Eq, Ord)

-------------------------------------------------------------------------------- error handling

-- TODO: add more structure to support desugaring
data Range
    = Range SourcePos SourcePos
    | NoRange

instance Monoid Range where
    mempty = NoRange
    Range a1 a2 `mappend` Range b1 b2 = Range (min a1 a2) (max b1 b2)
    NoRange `mappend` a = a
    a `mappend` b = a

type WithRange = (,) Range

--------------------------------------------------------------------------------

type WithExplanation = (,) Doc

pattern WithExplanation d x = (d, x)

-- TODO: add more structure
data ErrorMsg
    = AddRange Range ErrorMsg
    | InFile String ErrorMsg
    | ErrorCtx Doc ErrorMsg
    | ErrorMsg Doc
    | EParseError ParseError
    | UnificationError Ty Ty [WithExplanation [Ty]]

instance Show ErrorMsg where
    show = show . f Nothing Nothing where
        f file rng = \case
            InFile s e -> f (Just s) Nothing e
            AddRange r e -> showRange file (Just r) <$$> f file (Just r) e
            ErrorCtx d e -> "during" <+> d <$$> f file rng e
            EParseError pe -> text $ show pe
            ErrorMsg d -> d
            UnificationError a b tys -> "cannot unify" <+> pShow a </> "with" <+> pShow b
                <$$> "----------- equations"
                <$$> vcat (map (\(s, l) -> s <$$> vcat (map pShow l)) tys)

type ErrorT = ExceptT ErrorMsg

throwParseError = throwError . EParseError

mapError f m = catchError m $ throwError . f

addCtx d = mapError (ErrorCtx d)

addRange :: MonadError ErrorMsg m => Range -> m a -> m a
addRange NoRange = id
addRange r = mapError $ AddRange r

{-
checkUnambError = do
    cs <- get
    case cs of
        (Just _: _) -> throwError $ head $ catMaybes $ reverse cs
        _ -> return ()
-}
--throwErrorTCM :: Doc -> TCM a
throwErrorTCM = throwError . ErrorMsg

showRange :: Maybe String -> Maybe Range -> Doc
showRange Nothing Nothing = "no file position"
showRange Nothing (Just _) = "no file"
showRange (Just _) Nothing = "no position"
showRange (Just src) (Just (Range s e)) = str
    where
      startLine = sourceLine s - 1
      endline = sourceLine e - if sourceColumn e == 1 then 1 else 0
      len = endline - startLine
      str = vcat $ ("position:" <+> text (show s) <+> "-" <+> text (show e)):
                   map text (take len $ drop startLine $ lines src)
                ++ [text $ replicate (sourceColumn s - 1) ' ' ++ replicate (sourceColumn e - sourceColumn s) '^' | len == 1]

-------------------------------------------------------------------------------- parser output

data ValueDef p e = ValueDef p e
data TypeSig n t = TypeSig n t

data ModuleR
  = Module
  { moduleImports :: [Name]    -- TODO
  , moduleExports :: ()     -- TODO
  , definitions   :: [DefinitionR]
  }

type DefinitionR = WithRange Definition
data Definition
    = DValueDef (ValueDef PatR ExpR)
    | DAxiom (TypeSig Name TyR)
    | DDataDef Name [(Name, TyR)] [WithRange ConDef]      -- TODO: remove, use GADT
    | GADT Name [(Name, TyR)] [(Name, TyR)]
    | ClassDef ClassName [(Name, TyR)] [TypeSig Name TyR]
    | InstanceDef ClassName TyR [ValueDef PatR ExpR]
    | TypeFamilyDef Name [(Name, TyR)] TyR
-- used only during parsing
    | PreValueDef (Range, EName) [PatR] WhereRHS
    | DTypeSig (TypeSig EName TyR)
    | PreInstanceDef ClassName TyR [DefinitionR]
    | ForeignDef Name TyR

-- used only during parsing
data WhereRHS = WhereRHS GuardedRHS (Maybe [DefinitionR])

-- used only during parsing
data GuardedRHS
    = Guards Range [(ExpR, ExpR)]
    | NoGuards ExpR

data ConDef = ConDef Name [FieldTy]
data FieldTy = FieldTy {fieldName :: Maybe Name, fieldType :: TyR}

type PatR = Pat' Name Name WithRange
type ExpR = Exp' Name TyR PatR WithRange
type ConstraintR = Constraint' Name TyR
type TypeFunR = TypeFun Name TyR
type ValueDefR = ValueDef PatR ExpR

-------------------------------------------------------------------------------- names with unique ids

type IdN = N
pattern IdN a = a
--newtype IdN = IdN N deriving (Eq, Ord)
{- TODO
data IdN = IdN !Int N

instance Eq IdN where IdN i _ == IdN j _ = i == j
instance Ord IdN where IdN i _ `compare` IdN j _ = i `compare` j
-}

pattern TypeIdN n <- IdN (TypeN n)
pattern TypeIdN' n i = IdN (TypeN' n i)
pattern ExpIdN n <- IdN (ExpN n)
pattern ExpIdN' n i = IdN (ExpN' n i)



type FreshVars = [String]     -- fresh typevar names

type VarMT = StateT FreshVars

newName :: MonadState FreshVars m => Doc -> m IdN
newName i = do
  (n: ns) <- get
  put ns
  return $ TypeIdN' n i

newEName = do
  (n: ns) <- get
  put ns
  return $ ExpIdN' n ""

-------------------------------------------------------------------------------- environments

type Env' a = Map Name a
type Env a = Map IdN a

type SubstEnv = Env (Either Ty Ty)  -- either substitution or type signature   TODO: dedicated type instead of Either

type Subst = Env Ty  -- substitutions

data TEnv = TEnv Subst EnvMap       -- TODO: merge into this:   Env (Either Ty (Maybe Thunk))

type EnvMap = Env (Maybe Thunk)   -- Nothing: statically unknown but defined

data ClassD = ClassD InstEnv

type InstEnv = Env' InstType'

type PrecMap = Env' Fixity

type InstanceDefs = Env' (Map Ty Witness)

--------------------------------------------------------------------------------

data PolyEnv = PolyEnv
    { instanceDefs :: InstanceDefs
    , classDefs  :: Env' ClassD
    , getPolyEnv :: InstEnv
    , precedences :: PrecMap
    , thunkEnv :: EnvMap
    , typeFamilies :: InstEnv
    }

emptyPolyEnv :: PolyEnv
emptyPolyEnv = PolyEnv mempty mempty mempty mempty mempty mempty

joinPolyEnvs :: forall m. MonadError ErrorMsg m => [PolyEnv] -> m PolyEnv
joinPolyEnvs ps = PolyEnv
    <$> mkJoin' instanceDefs
    <*> mkJoin classDefs
    <*> mkJoin getPolyEnv
    <*> mkJoin precedences
    <*> mkJoin thunkEnv
    <*> mkJoin typeFamilies
  where
    mkJoin :: (PolyEnv -> Env a) -> m (Env a)
    mkJoin f = case filter (not . null . drop 1 . snd) $ Map.toList ms' of
        [] -> return $ fmap head $ Map.filter (not . null) ms'
        xs -> throwErrorTCM $ "Definition clash:" <+> pShow (map fst xs)
       where
        ms' = Map.unionsWith (++) $ map (((:[]) <$>) . f) ps

    mkJoin' f = case [(n, x) | (n, s) <- Map.toList ms', (x, is) <- Map.toList s, not $ null $ drop 1 is] of
        [] -> return $ fmap head . Map.filter (not . null) <$> ms'
        xs -> throwErrorTCM $ "Definition clash:" <+> pShow xs
       where
        ms' = Map.unionsWith (Map.unionWith (++)) $ map ((((:[]) <$>) <$>) . f) ps

--withTyping :: Env InstType -> TCM a -> TCM a
withTyping ts = addPolyEnv $ emptyPolyEnv {getPolyEnv = ts}

addPolyEnv pe m = do
    env <- ask
    env <- joinPolyEnvs [env, pe]
    local (const env) m

-------------------------------------------------------------------------------- monads

type TypingT = WriterT' SubstEnv

type InstType = TypingT (VarMT Identity) ([Ty], Ty)
type InstType' = Doc -> InstType

pureInstType = lift . pure

-- type checking monad transformer
type TCMT m = ReaderT PolyEnv (ErrorT (VarMT m))

type TCM = TCMT Identity

type TCMS = TypingT TCM

toTCMS :: InstType -> TCMS ([Ty], Ty)
toTCMS = mapWriterT' $ lift . lift --mapStateT lift

liftIdentity :: Monad m => Identity a -> m a
liftIdentity = return . runIdentity

-------------------------------------------------------------------------------- typecheck output

type ExpT = (Exp, Ty)
type PatT = Pat
type ConstraintT = Constraint' IdN Ty
type TypeFunT = TypeFun IdN Ty
type ValueDefT = ValueDef PatT ExpT

-------------------------------------------------------------------------------- LambdaCube specific definitions
-- TODO: eliminate most of these

pattern StarStar = StarToStar 1

pattern TCon0 a = TCon Star a
pattern TCon1 a b = TApp Star (TCon StarStar a) b
pattern TCon2 a b c = TApp Star (TApp StarStar (TCon (StarToStar 2) a) b) c
pattern TCon2' a b c = TApp Star (TApp StarStar (TCon VecKind a) b) c
pattern TCon3' a b c d = TApp Star (TApp StarStar (TApp VecKind (TCon (TArr Star VecKind) a) b) c) d

pattern TENat' a = EType (TENat a)
pattern TENat a = Ty_ (ELit_ (LNat a))
pattern TVec a b = TCon2' "Vec" (TENat a) b
pattern TMat a b c = TApp Star (TApp StarStar (TApp VecKind (TCon MatKind "Mat") (TENat a)) (TENat b)) c

-- basic types
pattern TChar = TCon0 "Char"
pattern TString = TCon0 "String"
pattern TBool = TCon0 "Bool"
pattern TWord = TCon0 "Word"
pattern TInt = TCon0 "Int"
pattern TNat = TCon0 "Nat"
pattern TFloat = TCon0 "Float"
pattern VecKind = TArr TNat StarStar
pattern MatKind = TArr TNat (TArr TNat StarStar)

-- Semantic
pattern Depth a = TCon1 "Depth" a
pattern Stencil a = TCon1 "Stencil" a
pattern Color a = TCon1 "Color" a

-- GADT
pattern TInput b = TCon1 "Input" b
pattern TFragmentOperation b = TCon1 "FragmentOperation" b
pattern TImage b c = TCon2' "Image" b c
pattern TInterpolated b = TCon1 "Interpolated" b
pattern TFrameBuffer b c = TCon2' "FrameBuffer" b c

pattern ClassN n <- TypeN n where
    ClassN n = TypeN' n "class"
pattern IsValidOutput = ClassN "ValidOutput"
pattern IsTypeLevelNatural = ClassN "TNat"
pattern IsValidFrameBuffer = ClassN "ValidFrameBuffer"
pattern IsInputTuple = ClassN "InputTuple"

pattern TypeFunS a b <- TypeFun (TypeN a) b where
    TypeFunS a b = TypeFun (TypeN' a "typefun") b
pattern TFMat a b               = TypeFunS "Mat" [a, b]      -- may be data family
pattern TFVec a b               = TypeFunS "Vec" [a, b]      -- may be data family
pattern TFMatVecElem a          = TypeFunS "MatVecElem" [a]
pattern TFMatVecScalarElem a    = TypeFunS "MatVecScalarElem" [a]
pattern TFVecScalar a b         = TypeFunS "VecScalar" [a, b]
pattern TFFTRepr' a             = TypeFunS "FTRepr'" [a]
pattern TFColorRepr a           = TypeFunS "ColorRepr" [a]
pattern TFFrameBuffer a         = TypeFunS "FrameBuffer" [a]
pattern TFFragOps a             = TypeFunS "FragOps" [a]
pattern TFJoinTupleType a b     = TypeFunS "JoinTupleType" [a, b]

-------------------------------------------------------------------------------- free variables

class FreeVars a where freeVars :: a -> Set IdN

instance FreeVars Ty where
    freeVars = \case
        Ty_ x -> case x of
            EVar_ k a -> Set.singleton a <> freeVars k
            TCon_ k a -> freeVars k
            EApp_ k a b -> freeVars k <> freeVars a <> freeVars b
            Forall_ (Just v) k t -> freeVars k <> Set.delete v (freeVars t)
            Witness k w -> freeVars k -- TODO: w?
            x -> foldMap freeVars x
        StarToStar _ -> mempty

instance FreeVars a => FreeVars [a]                 where freeVars = foldMap freeVars
--instance FreeVars Typing where freeVars (TypingConstr m t) = freeVars m <> freeVars t
instance FreeVars a => FreeVars (TypeFun n a)       where freeVars = foldMap freeVars
instance FreeVars a => FreeVars (Env a)         where freeVars = foldMap freeVars
instance FreeVars a => FreeVars (Constraint' n a)    where freeVars = foldMap freeVars

-------------------------------------------------------------------------------- Pretty show instances

-- TODO: eliminate
showN :: N -> String
showN (N _ qs s _) = show $ hcat (punctuate (pShow '.') $ map text $ qs ++ [s])

instance PShow N where
    pShowPrec p = \case
        N _ qs s (NameInfo _ i) -> hcat (punctuate (pShow '.') $ map text $ qs ++ [s]) -- <> "{" <> i <> "}"

showVar (N q _ n (NameInfo _ i)) = pShow q <> text n <> "{" <> i <> "}"

instance PShow NameSpace where
    pShowPrec p = \case
        TypeNS -> "'"
        ExpNS -> ""

--instance PShow IdN where pShowPrec p (IdN n) = pShowPrec p n

instance PShow Lit where
    pShowPrec p = \case
        LInt    i -> pShow i
        LChar   i -> text $ show i
        LString i -> text $ show i
        LFloat  i -> pShow i
        LNat    i -> pShow i

instance PShow Witness where
    pShowPrec p = \case
        Refl -> "Refl"
        WInstance _ -> "WInstance ..."       

instance PShow Ty where
    pShowPrec p = \case
        Star -> "*"
        StarToStar i -> hcat $ intersperse "->" $ replicate (i+1) "*"
        TyStar i -> pShowPrec p i
--        Ty k i -> pInfix (-2) "::" p i k

instance (PShow k, PShow v, PShow t, PShow p, PShow b) => PShow (Exp_ k v t p b) where
    pShowPrec p = \case
        ELit_ l -> pShowPrec p l
        EVar_ k v -> pShowPrec p v
        EApp_ k a b -> pApp p a b
        ETuple_ a -> tupled $ map pShow a
        ELam_ p b -> "\\" <> pShow p <+> "->" <+> pShow b
        ETypeSig_ b t -> pShow b <+> "::" <+> pShow t
        EType_ t -> "'" <> pShowPrec p t
        ELet_ a b c -> "let" <+> pShow a <+> "=" <+> pShow b <+> "in" </> pShow c
        ENamedRecord_ n xs -> pShow n <+> showRecord xs
        ERecord_ xs -> showRecord xs
        EFieldProj_ n -> "." <> pShow n
        EAlts_ i b -> pShow i <> braces (vcat $ punctuate (pShow ';') $ map pShow b)
        ENext_ -> "SKIP"
        ExtractInstance i j n -> "extract" <+> pShow i <+> pShow j <+> pShow n
        PrimFun a b c -> "primfun" <+> pShow a <+> pShow b <+> pShow c

        Star_ -> "*"
--        TLit_ l -> pShowPrec p l
--        EVar_ n -> pShow n
        TCon_ k n -> pShow n
--        TApp_ a b -> pApp p a b
        Forall_ Nothing a b -> pInfixr (-1) "->" p a b
--        Forall_ (Just n) (a) b -> "forall" <+> pShow n <+> "::" <+> pShow (_ a) <> "." <+> pShow b
        Forall_ (Just n) a b -> "forall" <+> pShow n <+> "::" <+> pShow a <> "." <+> pShow b
        TTuple_ a -> tupled $ map pShow a
        TRecord_ m -> "Record" <+> showRecord (Map.toList m)
        ConstraintKind_ c -> pShowPrec p c
        Witness k w -> pShowPrec p w


showRecord = braces . hsep . punctuate (pShow ',') . map (\(a, b) -> pShow a <> ":" <+> pShow b)

instance (PShow n, PShow t, PShow p, PShow a) => PShow (Exp' n t p ((,) a)) where
    pShowPrec p e = case getLams e of
        ([], Exp _ e) -> pShowPrec p e
        (ps, Exp _ e) -> "\\" <> hsep (map pShow ps) <+> "->" <+> pShow e

getLams (ELam' _ p e) = (p:) *** id $ getLams e
getLams e = ([], e)

instance (PShow n, PShow t, PShow p) => PShow (Exp' n t p Identity) where
    pShowPrec p e = case getLams' e of
        ([], Exp'' e) -> pShowPrec p e
        (ps, Exp'' e) -> "\\" <> hsep (map pShow ps) <+> "->" <+> pShow e

getLams' (ELam p e) = (p:) *** id $ getLams' e
getLams' e = ([], e)

instance (PShow c, PShow v, PShow b) => PShow (Pat_ c v b) where
    pShowPrec p = \case
        PLit_ l -> pShow l
        PVar_ v -> pShow v
        PCon_ s xs -> pApps p s xs
        PTuple_ a -> tupled $ map pShow a
        PRecord_ xs -> "Record" <+> showRecord xs
        PAt_ v p -> pShow v <> "@" <> pShow p
        Wildcard_ -> "_"

instance (PShow n, PShow c) => PShow (Pat' c n ((,) a)) where
    pShowPrec p (Pat' (_, e)) = pShowPrec p e

instance (PShow n, PShow c) => PShow (Pat' c n Identity) where
    pShowPrec p (Pat'' e) = pShowPrec p e

instance (PShow n, PShow a) => PShow (TypeFun n a) where
    pShowPrec p (TypeFun s xs) = pApps p s xs

instance (PShow n, PShow a) => PShow (Constraint' n a) where
    pShowPrec p = \case
        CEq a b -> pShow a <+> "~~" <+> pShow b
        CUnify a b -> pShow a <+> "~" <+> pShow b
        CClass a b -> pShow a <+> pShow b
--        | Split a a a         -- Split x y z:  x, y, z are records; fields of x = disjoint union of the fields of y and z

instance (PShow n) => PShow (Ty' n ((,) a)) where
    pShowPrec p (Ty' a b) = pShowPrec p b

instance PShow Var where
    pShowPrec p = \case
        VarE n t -> pShow n --pParens True $ pShow n <+> "::" <+> pShow t

instance PShow TEnv where

instance PShow Range where
    pShowPrec p = \case
        Range a b -> text (show a) <+> "--" <+> text (show b)
        NoRange -> ""

-------------------------------------------------------------------------------- replacement

type Repl = Map IdN IdN

-- TODO: express with Substitute?
class Replace a where repl :: Repl -> a -> a

instance Replace Ty where
    repl st = \case
        ty | Map.null st -> ty -- optimization
        StarToStar n -> StarToStar n
        Ty_ s -> Ty_ $ mapKind (repl st) $ case s of
            Forall_ (Just n) a b -> Forall_ (Just n) (repl st a) (repl (Map.delete n st) b)
            EVar_ k a | Just t <- Map.lookup a st -> EVar_ (repl st k) t
            t -> repl st <$> t

instance Replace a => Replace (Env a) where
    repl st e = Map.fromList $ map (r *** repl st) $ Map.toList e
      where
        r x = fromMaybe x $ Map.lookup x st

instance (Replace a, Replace b) => Replace (Either a b) where
    repl st = either (Left . repl st) (Right . repl st)

-------------------------------------------------------------------------------- substitution

data Subst_ = Subst_ { substS :: Subst, lookupS :: Name -> Maybe Ty, delN :: Name -> Subst_ }

showS = pShow . substS

-- TODO: review usage (use only after unification)
class Substitute a where subst_ :: Subst_ -> a -> a

subst :: Substitute a => Subst -> a -> a
subst = subst_ . mkSubst
  where
    mkSubst :: Subst -> Subst_
    mkSubst s = Subst_ s (`Map.lookup` s) $ \n -> mkSubst $ Map.delete n s

substEnvSubst :: Substitute a => SubstEnv -> a -> a
substEnvSubst = subst_ . mkSubst'
  where
    mkSubst' :: SubstEnv -> Subst_
    mkSubst' s = Subst_ (Map.map fromLeft $ Map.filter isLeft s) ((`Map.lookup` s) >=> either Just (const Nothing)) $ \n -> mkSubst' $ Map.delete n s
    fromLeft = either id $ error "impossible"

trace' x = trace (ppShow x) x

recsubst :: (Ty -> IdN -> Ty) -> (IdN -> Ty -> Ty) -> Ty -> Ty
recsubst g h = \case
    StarToStar n -> StarToStar n
    Ty_ s -> case s of
        Forall_ (Just n) a b -> Ty_ $ Forall_ (Just n) (f a) $ h n b
        EVar_ k v -> g (Ty_ $ EVar_ (f k) v) v
        _ -> Ty_ $ mapKind f $ f <$> s
  where
    f = recsubst g h

instance Substitute Ty where
    subst_ st t = f mempty st t where
      f acc st = recsubst r1 r2 where
            r2 n = f acc (delN st n)
            r1 def a
                | Set.member a acc = error $ "cycle" ++ show (showS st <$$> pShow t)
                | Just t <- lookupS st a = f (Set.insert a acc) st t
                | otherwise = def
{-
instance Substitute (Env Ty) where
    subst_ st = fmap (Map.fromList . concat) . sequenceA . map f . Map.toList where
        f (x, y)
            | Map.member x st = pure []
            | otherwise = (:[]) . (,) x <$> subst_ st y
-}
instance Substitute SubstEnv where
    subst_ st = Map.fromDistinctAscList . concatMap f . Map.toList where
        f (x, y)
            | Just _ <- lookupS st x = []
            | otherwise = [(x, either Left (Right . subst_ st) y)]

--instance Substitute a => Substitute (Constraint' n a)      where subst_ = fmap . subst_
instance Substitute a => Substitute [a]                    where subst_ = fmap . subst_
instance (Substitute a, Substitute b) => Substitute (a, b) where subst_ s (a, b) = (subst_ s a, subst_ s b)

instance Substitute Thunk where
    subst_ s = applySubst $ substS s

instance Substitute Var where
    subst_ s = \case
        VarE n t -> VarE n $ subst_ s t

instance Substitute Pat where
    subst_ s = \case
        PVar v -> PVar $ subst_ s v
        PCon (VarE n ty) l -> PCon (VarE n $ subst_ s ty) $ subst_ s l
        Pat'' p -> Pat'' $ subst_ s <$> p

--------------------------------------------------------------------------------

-- Note: domain of substitutions is disjunct
-- semantics:  subst (s2 `composeSubst` s1) = subst s2 . subst s1
-- example:  subst ({y -> z} `composeSubst` {x -> y}) = subst {y -> z} . subst {x -> y} = subst {y -> z, x -> z}
-- example2: subst ({x -> z} `composeSubst` {x -> y}) = subst {x -> z} . subst {x -> y} = subst {x -> y}
composeSubst :: Subst -> Subst -> Subst
s2 `composeSubst` s1 = (subst s2 <$> s1) <> s2


-------------------------------------------------------------------------------- utility

tyOf :: Exp -> Ty
tyOf = \case
    ETuple es -> TTuple $ map tyOf es
    EVar (VarE _ t) -> t
    EApp (tyOf -> TArr _ t) _ -> t
    ELam (tyOfPat -> a) (tyOf -> b) -> TArr a b
--    _ -> TUnit -- hack!
    e -> error $ "tyOf " ++ ppShow e

tyOfPat :: Pat -> Ty
tyOfPat = \case
    PCon (VarE _ t) ps -> stripArgs (length ps) t
    e -> error $ "tyOfPat " ++ ppShow e
  where
    stripArgs 0 t = t
    stripArgs n (TArr _ t) = stripArgs (n-1) t

patternEVars (Pat'' p) = case p of
    PVar_ (VarE v _) -> [v]
    p -> foldMap patternEVars p

-------------------------------------------------------------------------------- thunks

instance Monoid TEnv where
    mempty = TEnv mempty mempty
    -- semantics: apply (m1 <> m2) = apply m1 . apply m2;  see 'composeSubst'
    m1@(TEnv x1 y1) `mappend` TEnv x2 y2 = TEnv (x1 `composeSubst` x2) $ ((applyEnv m1 <$>) <$> y2) <> y1

envMap :: Thunk -> EnvMap
envMap (Exp (TEnv _ m) _) = m

subst' :: Substitute a => TEnv -> a -> a
subst' (TEnv s _) = subst s

applyEnv :: TEnv -> Thunk -> Thunk
applyEnv m1 (Exp m exp) = Exp (m1 <> m) exp

applyEnvBefore :: TEnv -> Thunk -> Thunk
applyEnvBefore m1 (Exp m exp) = Exp (m <> m1) exp

--   applySubst s  ===  applyEnv (TEnv s mempty)
-- but the following is more efficient
applySubst :: Subst -> Thunk -> Thunk
applySubst s' (Exp (TEnv s m) exp) = Exp (TEnv (s' `composeSubst` s) m) exp

-- build recursive environment  -- TODO: generalize
recEnv :: Pat -> Thunk -> Thunk
recEnv (PVar (VarE v _)) th_ = th where th = applyEnvBefore (TEnv mempty (Map.singleton v (Just th))) th_
recEnv _ th = th

mkThunk :: Exp -> Thunk
mkThunk = thunk . mkThunk'

mkThunk' :: Exp -> Thunk'
mkThunk' (Exp'' e) = mkThunk <$> e

thunk :: Thunk' -> Thunk
thunk = Exp mempty

peelThunk :: Thunk -> Thunk'
peelThunk (Exp env e) = mapExp vf (subst' env) (subst' env) $ applyEnv env <$> e
  where
    vf = \case
        VarE v t -> VarE v $ subst' env t

--------------------------------------------------------------------------------

buildLet :: [ValueDefT] -> ExpT -> ExpT
buildLet es e = foldr (\(ValueDef p (e, t')) (x, t'') -> (ELet p e x, t'')) e es


-------------------------------------------------------------------------------- WriterT'

class Monoid' e where
    type MonoidConstraint e (m :: * -> *) :: Constraint
    mempty' :: e
    mappend' :: MonoidConstraint e m => e -> e -> m e

newtype WriterT' e m a
  = WriterT' {runWriterT' :: m (e, a)}
    deriving (Functor,Foldable,Traversable)

instance (Monoid' e) => MonadTrans (WriterT' e) where
    lift m = WriterT' $ (,) mempty' <$> m

instance (Monoid' e, Monad m, MonoidConstraint e m) => Applicative (WriterT' e m) where
    pure a = WriterT' $ pure (mempty', a)
    a <*> b = join $ (<$> b) <$> a

instance (Monoid' e, Monad m, MonoidConstraint e m) => Monad (WriterT' e m) where
    WriterT' m >>= f = WriterT' $ do
            (e1, a) <- m
            (e2, b) <- runWriterT' $ f a
            e <- mappend' e1 e2
            return (e, b)

instance (Monoid' e, MonoidConstraint e m, MonadReader r m) => MonadReader r (WriterT' e m) where
    ask = lift ask
    local f (WriterT' m) = WriterT' $ local f m

instance (Monoid' e, MonoidConstraint e m, MonadState s m) => MonadState s (WriterT' e m) where
    state f = lift $ state f

instance (Monoid' e, MonoidConstraint e m, MonadError err m) => MonadError err (WriterT' e m) where
    catchError (WriterT' m) f = WriterT' $ catchError m $ runWriterT' <$> f
    throwError e = lift $ throwError e

mapWriterT' f (WriterT' m) = WriterT' $ f m
