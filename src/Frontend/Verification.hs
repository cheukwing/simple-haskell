module Frontend.Verification where

import Hashkell.Syntax
import Frontend.Complexity
import Frontend.Aggregator
import Frontend.Error

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (maybe)
import Control.Monad (when, unless, foldM)
import Control.Monad.Except (throwError)

type FunctionData = (Maybe Cplx, Maybe [Type], Maybe ([Name], Defn))
type FunctionTable = Map Name FunctionData

-- verify checks that the aggregations in an aggregation table are all correct
-- with respect to their complexity annotation
-- NOTE: verification such as general type checking is not considered as we
-- assume input programs are correct when annotations are removed, and because
-- the final output program will be verified by GHC/similar compiler anyway
verify :: AggregationTable -> Either Error FunctionTable
verify at
    = foldM verify' Map.empty (Map.toList at)
    where 
        convertAndVerify agg = toFunctionData agg >>= verifyFunctionData
        verify' ft (k, v) = flip (Map.insert k) ft <$> convertAndVerify v


toFunctionData :: Aggregation -> Either Error FunctionData
toFunctionData (mc, mts, mfn) = do
    mcplx <- case mc of
        Nothing -> return Nothing
        Just c  -> Just <$> parseComplexity c
    return (mcplx, mts, mfn)

-- verifyFunctionData checks that the complexity annotation in an aggregation
-- is compatible with the other information given for a certain function
verifyFunctionData :: FunctionData -> Either Error FunctionData
-- if we just have complexity and types, then if we do have a param in our
-- complexity, ensure that it will have some assigned type
verifyFunctionData fd @ (Just c, Just ts, Nothing)
    = maybe (return fd) 
        (\_ -> if length ts < 2
            then throwError IncompatibleComplexity
            else return fd)
        (paramComplexity c)
-- if we just have complexity and definition, then if we do have a param in our
-- complexity, ensure that it is also present in the params of the definition
verifyFunctionData fd @ (Just c, Nothing, Just (params, _))
    = maybe (return fd)
        (\n -> if n `notElem` params
            then throwError IncompatibleComplexity
            else return fd)
        (paramComplexity c)
-- if we have all the information and we do have a param in our complexity,
-- then get the type of that param (simultaneously checking that the param
-- exists and has a type), then check that the type is supported for
-- use as a complexity
verifyFunctionData fd @ (Just c, Just ts, Just (params, _))
    = maybe (return fd)
        (maybe (throwError IncompatibleComplexity)
            (\t -> if not (isSupportedType t) 
                    then throwError IncompatibleComplexity
                    else return fd)
            . typeOf)
        (paramComplexity c)
    where
        isSupportedType Bool   = False
        isSupportedType Int    = True
        isSupportedType List{} = True
        typeOf name 
            = case [t | (t, p) <- zip ts params, p == name] of
                (t : _) -> Just t
                []      -> Nothing
-- if we do not have a complexity, or just a complexity, then ignore
verifyFunctionData fd
    = return fd