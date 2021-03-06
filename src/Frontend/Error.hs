module Frontend.Error where

data Error
    = IllegalComplexity
    | UnsupportedComplexity
    | IncompatibleComplexity
    | DuplicateDeclaration
    deriving (Eq, Show)