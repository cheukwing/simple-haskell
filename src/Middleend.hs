module Middleend (
    Middleend.DependencyGraph.DependencyGraph,
    Middleend.DependencyGraph.DNode(..),
    Middleend.DependencyGraph.DType(..),
    Middleend.DependencyGraph.DExpr(..),
    Middleend.DependencyGraph.DLit(..),
    Middleend.Paralleliser.EncodingInstructionTable,
    Middleend.Paralleliser.EncodingInstruction(..),
    pipeline
) where

import Frontend (AggregationTable)

import Simple.Syntax
import Middleend.Cleaner
import Middleend.Paralleliser
import Middleend.DependencyGraph

pipeline :: Steps -> AggregationTable -> EncodingInstructionTable
pipeline steps
    = createEncodingInstructionTable steps . cleanup