module Middleend.Cleaner where

import Hashkell.Syntax
import Frontend (FunctionTable, FunctionData(..), Cplx(..))

import Control.Monad.State.Strict
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.List (isPrefixOf, partition)
import Data.Maybe (Maybe)
import qualified Data.Maybe as Maybe

cleanup :: FunctionTable -> FunctionTable
cleanup = Map.map cleanup'
    where
        cleanup' :: FunctionData -> FunctionData
        cleanup' (mcplx, mts, Just (params, e))
            = (mcplx', mts, Just (finalParams, e''))
            where
                (mcplx', finalParams, e') = ensureUniqueNames mcplx params e
                e''                       = ensureNoUnusedDefs e'
        cleanup' agg
            = agg


--- Unique names ---

type Counter = Int
type UniqueState = (Set Name, Map Name Name, Counter)

-- ensureUniqueNames ensures that all identifiers in the params or let
-- expressions are unique AND are not similar to those generated by the
-- application (i.e. "_x*", "_y*"), renaming them to be "_y{i}" as well
-- as any users of those identifiers
-- this is necessary for dependency graph building to be correct, since
-- we use the names as our keys in the tables
ensureUniqueNames :: Maybe Cplx -> [Name] -> Expr -> (Maybe Cplx, [Name], Expr)
ensureUniqueNames mcplx params e 
    = (mcplx', finalParams, evalState (uniqueNamer e) initState)
    where
        -- setup of the initState by creating any mappings for param names
        -- which are similar to those generated by parallelisation
        similarityCheck = zip params (map isSimilarToGeneratedNames params)
        paramCountUsed  = scanl (\acc (_, s) -> if s then acc + 1 else acc)
                            0
                            similarityCheck
        mappings        = map (\((p, s), c) -> 
                            if s
                                then (p, "_y" ++ show c)
                                else (p, p))
                            (zip similarityCheck paramCountUsed)
        mappingsAsMap   = Map.fromList (filter (uncurry (/=)) mappings)
        mcplx'          = replaceCplxName mcplx mappingsAsMap
        finalParams     = map snd mappings
        initState       = ( Set.fromList finalParams
                          , mappingsAsMap
                          , last paramCountUsed
                          )

-- replaceCplxName ensures that the complexity's names are changed to be
-- unique when the params are not unique
replaceCplxName :: Maybe Cplx -> Map Name Name -> Maybe Cplx
replaceCplxName Nothing _
    = Nothing
replaceCplxName mcplx @ (Just Constant{}) _
    = mcplx
replaceCplxName (Just (Polynomial id n)) mapping
    = return $ Polynomial (Map.findWithDefault id id mapping) n
replaceCplxName (Just (Exponential n id)) mapping
    = return $ Exponential n (Map.findWithDefault id id mapping)
replaceCplxName (Just (Logarithmic id)) mapping
    = return $ Logarithmic (Map.findWithDefault id id mapping)
replaceCplxName (Just (Factorial id)) mapping
    = return $ Factorial (Map.findWithDefault id id mapping)

-- isSimilarToGeneratedNames checks if a name is similar to "_x{i}" or "_y{i}",
-- which are the names generated by the application
isSimilarToGeneratedNames :: String -> Bool
isSimilarToGeneratedNames name
    = ("_x" `isPrefixOf` name) || ("_y" `isPrefixOf` name) 

-- updateUniqueState checks if a given def uses an identifier which has already
-- been used, or is similar to a name generated by the application, and if so
-- creates a new unique name mapping
updateUniqueState :: Def -> State UniqueState ()
updateUniqueState (Def n _) = do
    (s, m, c) <- get
    if Set.member n s || isSimilarToGeneratedNames n
        then put (s, Map.insert n ("_y" ++ show c) m, c + 1)
        else put (Set.insert n s, m, c)

-- toUniqueName replaces a name with its unique name mapping, or returns it
-- unchanged if it is already unique
toUniqueName :: Name -> State UniqueState Name
toUniqueName n = do
    (_, m, _) <- get
    return (Map.findWithDefault n n m)

-- uniqueNamer recursively traverses the expression and renames all non-unique
-- identifier names, or those similar to names generated by the application
uniqueNamer :: Expr -> State UniqueState Expr
uniqueNamer e @ Lit{} = return e
uniqueNamer (Var n) = Var <$> toUniqueName n
uniqueNamer (Op op e1 e2) = do
    e1' <- uniqueNamer e1
    e2' <- uniqueNamer e2
    return (Op op e1' e2')
uniqueNamer (App e1 e2) = do
    e1' <- uniqueNamer e1
    e2' <- uniqueNamer e2
    return (App e1' e2')
uniqueNamer (If e1 e2 e3) = do
    e1' <- uniqueNamer e1
    e2' <- uniqueNamer e2
    e3' <- uniqueNamer e3
    return (If e1' e2' e3')
uniqueNamer (Let defs e) = do
    (_, m, _) <- get
    mapM_ updateUniqueState defs
    -- setup the names for duplicated names in this scope
    defs' <- mapM (\(Def n e) -> Def <$> toUniqueName n <*> uniqueNamer e) defs
    e' <- uniqueNamer e
    (s, _, c) <- get
    -- we want uniqueness for the entire expression, but the renamings are only
    -- relevant for the scope in `e`; we restore the old renamings
    put (s, m, c)
    return (Let defs' e')

--- No unsed Defs ---

-- PRE: all names are unique (use ensureUniqueNames)
-- ensureNoUnusedDefs removes any unused definitions in let expressions
-- this is necessary for the usage of a dependency graph to be correct, since
-- we assume that all leaf nodes are potential return values, but unused definitions
-- will also appear as leaf nodes
ensureNoUnusedDefs :: Expr -> Expr
ensureNoUnusedDefs e 
    | e == e'   = e
    | otherwise = ensureNoUnusedDefs e' 
    -- we do this repeatedly until the expression is unchanged to handle chains
    -- of unused definitions
    -- TODO: could improve this algorithm
    where e' = removeUnusedDefs (usedDefs e) e

-- usedDefs recursively traverses an expression and builds a set of all the
-- used identifiers
usedDefs :: Expr -> Set Name
usedDefs Lit{} 
    = Set.empty
usedDefs (Var n) 
    = Set.singleton n
usedDefs (Op _ e1 e2) 
    = Set.union (usedDefs e1) (usedDefs e2)
usedDefs (App e1 e2)
    = Set.union (usedDefs e1) (usedDefs e2)
usedDefs (Let defs e)
    -- get the used identifiers from a Def's expression, but also delete the
    -- name from the result, the handle recursive definitions (e.g. x = x)
    = Set.unions (usedDefs e : map (\(Def n de) -> Set.delete n (usedDefs de)) defs)
usedDefs (If e1 e2 e3)
    = Set.unions [usedDefs e1, usedDefs e2, usedDefs e3]

-- removeUnusedDefs uses the set of used Def names, and removes any Defs
-- which are not in the set
removeUnusedDefs :: Set Name -> Expr -> Expr
removeUnusedDefs _ e @ Lit{}
    = e
removeUnusedDefs _ e @ Var{}
    = e
removeUnusedDefs used (Op op e1 e2)
    = Op op (removeUnusedDefs used e1) (removeUnusedDefs used e2)
removeUnusedDefs used (App e1 e2)
    = App (removeUnusedDefs used e1) (removeUnusedDefs used e2)
removeUnusedDefs used (Let defs e)
    -- if all are unused, then we can just return the expression
    | null defs' = e'
    | otherwise  = Let defs' e'
    where 
        e'    = removeUnusedDefs used e
        defs' = map (\(Def n e) -> Def n (removeUnusedDefs used e)) 
                $ filter (\(Def n _) -> Set.member n used) defs
removeUnusedDefs used (If e1 e2 e3)
    = If (removeUnusedDefs used e1)
        (removeUnusedDefs used e2)
        (removeUnusedDefs used e3)