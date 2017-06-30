-- Making implicit [£] explicit in data type, interface and interface alias
-- definitions
module RefineSyntaxConcretiseEps (concretiseEps) where

import Control.Monad
import Control.Monad.Except
import Control.Monad.State
import Data.Functor.Identity

import Data.List
import qualified Data.Map.Strict as M
import qualified Data.Set as S

import Syntax
import Debug

-- Node container for the graph algorithm
data Node = DtNode (DataT Raw) | ItfNode (Itf Raw) | ItfAlNode (ItfAlias Raw)
  deriving (Show, Eq)

-- Used as a result of inspecting a node on whether it has an
-- (implicit/explicit) [£]
data HasEps = HasEps |          -- "Yes" with certainty
              HasEpsIfAny [Id]  -- "Yes" if any of the given id's (definitions)
                                --       have implicit [£]
                                -- (n.b. HasEpsIfAny [] corresponds to "No")
  deriving (Show, Eq)

-- Given data type, interface and interface alias def's, determine which of them
-- carry an implicit or explicit [£] eff var. As the def's may depend on each
-- other, we consider each def. a node and model the dependencies as a
-- dependency graph.
-- A node will be decided either positive (i.e. carries [£]) or
-- negative (i.e. no [£]). Whenever a node reaches a positive one, it is also
-- decided positive (i.e. any contained subtype requiring [£] induces
-- [£] for the parent).
-- Finally, all definitions that are decided to have [£], but do not yet
-- explicitly have it, are added an additional [£] eff var.
concretiseEps :: [DataT Raw] -> [Itf Raw] -> [ItfAlias Raw] -> ([DataT Raw], [Itf Raw], [ItfAlias Raw])
concretiseEps dts itfs itfAls =
  let posIds = map nodeId (decideGraph (nodes, [], [])) in
  (map (concretiseEpsInDataT posIds) dts,
   map (concretiseEpsInItf   posIds) itfs,
   map (concretiseEpsInItfAl posIds) itfAls)
  where

  nodes :: [Node]
  nodes = map DtNode dts ++ map ItfNode itfs ++ map ItfAlNode itfAls

  ids :: [Id]
  ids = map nodeId nodes

  -- Given graph (undecided-nodes, positive-nodes, negative-nodes), decide
  -- subgraphs as long as there are unvisited nodes. Finally (base case),
  -- return positive nodes.
  decideGraph :: ([Node], [Node], [Node]) -> [Node]
  decideGraph ([],   pos, _  ) = pos
  decideGraph (x:xr, pos, neg) = decideGraph $ runIdentity $ execStateT (decideSubgraph x) (xr, pos, neg)

  -- Given graph (passed as state, same as for decideGraph) and a starting
  -- node x (already excluded from the graph), visit the whole subgraph
  -- reachable from x and thereby decide each node.
  -- To avoid cycles, x must always be excluded from graph.
  -- Method: 1) Try to decide x on its own. Either:
  --            (1), (2) Already decided
  --            (3), (4) Decidable without dependencies
  --         2) If x's decision is dependent on neighbours' ones, visit all
  --            and recursively decide them, too. Either:
  --            (5)(i)  A neighbour y is decided pos.     => x is pos.
  --            (5)(ii) All neighbours y are decided neg. => x is neg.
  decideSubgraph :: Node -> State ([Node], [Node], [Node]) Bool
  decideSubgraph x = do
    (xs, pos, neg) <- get
    if        x `elem` pos then return True      -- (1)
    else if   x `elem` neg then return False     -- (2)
    else case hasEpsNode x of
      HasEps          -> do put (xs, x:pos, neg) -- (3)
                            return True
      HasEpsIfAny ids ->
        let neighbours = filter ((`elem` ids) . nodeId) (xs ++ pos ++ neg) in
        do dec <- foldl (\dec y -> do -- Exclude neighbour from graph
                                      (xs', pos', neg') <- get
                                      put (xs' \\ [y], pos', neg')
                                      d  <- dec
                                      d' <- decideSubgraph y
                                      -- Once pos. y found, result stays pos.
                                      return $ d || d')
                        (return False)           -- (4) (no neighbours)
                        neighbours
           (xs', pos', neg') <- get
           if dec then put (xs', x:pos', neg')   -- (5)(i)
                  else put (xs', pos', x:neg')   -- (5)(ii)
           return dec

  {- hasEpsX functions examine an instance of X and determine whether it
     1) has an [£] for sure or
     2) has an [£] depending on other definitions

     The tvs parameter hold the locally introduced value type variables. It
     serves the following purpose: If an identifier is encountered, we cannot be
     sure if it was correctly determined as either data type or local type
     variable. This is the exact same issue to deal with as in refineVType,
     now in hasEpsVType -}

  hasEpsNode :: Node -> HasEps
  hasEpsNode node = case node of (DtNode dt) -> hasEpsDataT dt
                                 (ItfNode itf) -> hasEpsItf itf
                                 (ItfAlNode itfAl) -> hasEpsItfAl itfAl

  hasEpsDataT :: DataT Raw -> HasEps
  hasEpsDataT (MkDT _ ps ctrs) = if any ((==) ("£", ET)) ps then HasEps
                                 else let tvs = [x | (x, VT) <- ps] in
                                      anyHasEps (map (hasEpsCtr tvs) ctrs)

  hasEpsItf :: Itf Raw -> HasEps
  hasEpsItf (MkItf _ ps cmds) = if any ((==) ("£", ET)) ps then HasEps
                                else let tvs = [x | (x, VT) <- ps] in
                                     anyHasEps (map (hasEpsCmd tvs) cmds)

  hasEpsItfAl :: ItfAlias Raw -> HasEps
  hasEpsItfAl (MkItfAlias _ ps itfMap) = if any ((==) ("£", ET)) ps then HasEps
                                         else let tvs = [x | (x, VT) <- ps] in
                                              hasEpsItfMap tvs itfMap

  hasEpsCmd :: [Id] -> Cmd Raw -> HasEps
  hasEpsCmd tvs (MkCmd _ ps ts t) = let tvs' = tvs ++ [x | (x, VT) <- ps] in
                                    anyHasEps $ map (hasEpsVType tvs') ts ++ [hasEpsVType tvs' t]

  hasEpsCtr :: [Id] -> Ctr Raw -> HasEps
  hasEpsCtr tvs (MkCtr _ ts) = anyHasEps (map (hasEpsVType tvs) ts)

  hasEpsVType :: [Id] -> VType Raw -> HasEps
  hasEpsVType tvs (MkDTTy x ts) =
    if x `elem` ids then anyHasEps $ HasEpsIfAny [x] : map (hasEpsTyArg tvs) ts  -- indeed data type
                    else anyHasEps $ map (hasEpsTyArg tvs) ts                    -- ... or not
  hasEpsVType tvs (MkSCTy ty)   = hasEpsCType tvs ty
  hasEpsVType tvs (MkTVar x)    = if x `elem` tvs then HasEpsIfAny []  -- indeed type variable
                                                  else HasEpsIfAny [x] -- ... or not
  hasEpsVType tvs MkStringTy    = HasEpsIfAny []
  hasEpsVType tvs MkIntTy       = HasEpsIfAny []
  hasEpsVType tvs MkCharTy      = HasEpsIfAny []

  hasEpsCType :: [Id] -> CType Raw -> HasEps
  hasEpsCType tvs (MkCType ports peg) = anyHasEps $ map (hasEpsPort tvs) ports ++ [hasEpsPeg tvs peg]

  hasEpsPort :: [Id] -> Port Raw -> HasEps
  hasEpsPort tvs (MkPort adj ty) = anyHasEps [hasEpsAdj tvs adj, hasEpsVType tvs ty]

  hasEpsAdj :: [Id] -> Adj Raw -> HasEps
  hasEpsAdj tvs (MkAdj itfmap) = hasEpsItfMap tvs itfmap

  hasEpsPeg :: [Id] -> Peg Raw -> HasEps
  hasEpsPeg tvs (MkPeg ab ty) = anyHasEps [hasEpsAb tvs ab, hasEpsVType tvs ty]

  hasEpsAb :: [Id] -> Ab Raw -> HasEps
  hasEpsAb tvs (MkAb v m) = anyHasEps [hasEpsAbMod tvs v, hasEpsItfMap tvs m]

  hasEpsItfMap :: [Id] -> ItfMap Raw -> HasEps
  hasEpsItfMap tvs = anyHasEps . (map (hasEpsTyArg tvs)) . concat . M.elems

  hasEpsAbMod :: [Id] -> AbMod Raw -> HasEps
  hasEpsAbMod tvs MkEmpAb       = HasEpsIfAny []
  hasEpsAbMod tvs (MkAbVar "£") = HasEps
  hasEpsAbMod tvs (MkAbVar _)   = HasEpsIfAny []

  hasEpsTyArg :: [Id] -> TyArg Raw -> HasEps
  hasEpsTyArg tvs (VArg t)  = hasEpsVType tvs t
  hasEpsTyArg tvs (EArg ab) = hasEpsAb tvs ab

concretiseEpsInDataT :: [Id] -> DataT Raw -> DataT Raw
concretiseEpsInDataT posIds (MkDT dt ps ctrs) = (MkDT dt ps' ctrs) where
  ps' = if not (any ((==) ("£", ET)) ps) && dt `elem` posIds then ps ++ [("£", ET)] else ps

concretiseEpsInItf :: [Id] -> Itf Raw -> Itf Raw
concretiseEpsInItf posIds (MkItf itf ps cmds) = (MkItf itf ps' cmds) where
  ps' = if not (any ((==) ("£", ET)) ps) && itf `elem` posIds then ps ++ [("£", ET)] else ps

concretiseEpsInItfAl :: [Id] -> ItfAlias Raw -> ItfAlias Raw
concretiseEpsInItfAl posIds (MkItfAlias itfAl ps itfMap) = (MkItfAlias itfAl ps' itfMap) where
  ps' = if not (any ((==) ("£", ET)) ps) && itfAl `elem` posIds then ps ++ [("£", ET)] else ps

{- Helper functions -}

nodeId :: Node -> Id
nodeId (DtNode (MkDT id _ _)) = id
nodeId (ItfNode (MkItf id _ _)) = id
nodeId (ItfAlNode (MkItfAlias id _ _)) = id

-- A variant of the any-operator for HasEps results
anyHasEps :: [HasEps] -> HasEps
anyHasEps xs = if any ((==) HasEps) xs then HasEps
               else HasEpsIfAny (concat [ids | HasEpsIfAny ids <- xs])