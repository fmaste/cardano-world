{-# LANGUAGE NamedFieldPuns             #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE BangPatterns               #-}

module Ouroboros.Network.BlockFetch.Decision (
    -- * Deciding what to fetch
    fetchDecisions,
    FetchDecisionPolicy(..),
    FetchMode(..),
    PeerInfo,
    FetchDecision,
    FetchDecline(..),

    -- ** Components of the decision-making process
    filterPlausibleCandidates,
    selectForkSuffixes,
    filterNotAlreadyFetched,
    filterNotAlreadyInFlightWithPeer,
    prioritisePeerChains,
    filterNotAlreadyInFlightWithOtherPeers,
    fetchRequestDecisions,
  ) where

import qualified Data.Set as Set

import           Data.List (sortBy, groupBy, transpose)
import           Data.Function (on)

import           Control.Exception (assert)
import           Control.Monad (guard)

import           Ouroboros.Network.AnchoredFragment (AnchoredFragment)
import qualified Ouroboros.Network.AnchoredFragment as AnchoredFragment
import           Ouroboros.Network.Block
import           Ouroboros.Network.ChainFragment (ChainFragment(..))
import qualified Ouroboros.Network.ChainFragment as ChainFragment

import           Ouroboros.Network.BlockFetch.ClientState
                   ( FetchRequest(..)
                   , PeerFetchInFlight(..)
                   , PeerFetchStatus(..)
                   )
import           Ouroboros.Network.BlockFetch.DeltaQ
                   ( PeerGSV(..), SizeInBytes
                   , PeerFetchInFlightLimits(..)
                   , calculatePeerFetchInFlightLimits
                   , estimateResponseDeadlineProbability
                   , estimateExpectedResponseDuration )


data FetchDecisionPolicy header = FetchDecisionPolicy {
       maxInFlightReqsPerPeer  :: Word,  -- A protocol constant.

       maxConcurrencyBulkSync  :: Word,
       maxConcurrencyDeadline  :: Word,

       plausibleCandidateChain :: AnchoredFragment header
                               -> AnchoredFragment header -> Bool,

       compareCandidateChains  :: AnchoredFragment header
                               -> AnchoredFragment header
                               -> Ordering,

       blockFetchSize          :: header -> SizeInBytes
     }


data FetchMode =
       -- | Use this mode when we are catching up on the chain but are stil
       -- well behind. In this mode the fetch logic will optimise for
       -- throughput rather than latency.
       --
       FetchModeBulkSync

       -- | Use this mode for block-producing nodes that have a known deadline
       -- to produce a block and need to get the best chain before that. In
       -- this mode the fetch logic will optimise for picking the best chain
       -- within the given deadline.
     | FetchModeDeadline

       -- TODO: add an additional mode for in-between: when we are a core node
       -- following the chain but do not have an imminent deadline, or are a
       -- relay forwarding chains within the network.
       --
       -- This is a mixed mode because we have to combine the distribution of
       -- time to next block under praos, with the distribution of latency of
       -- our peers, and also the consensus preference.

  deriving (Eq, Show)


type PeerInfo header extra =
       ( PeerFetchStatus header,
         PeerFetchInFlight header,
         PeerGSV,
         extra
       )

-- | Throughout the decision making process we accumulate reasons to decline
-- to fetch any blocks. This type is used to wrap intermediate and final
-- results.
--
type FetchDecision result = Either FetchDecline result

-- | All the various reasons we can decide not to fetch blocks from a peer.
--
data FetchDecline =
     FetchDeclineChainNotPlausible
   | FetchDeclineChainNoIntersection
   | FetchDeclineAlreadyFetched
   | FetchDeclineInFlightThisPeer
   | FetchDeclineInFlightOtherPeer
   | FetchDeclinePeerShutdown
   | FetchDeclinePeerSlow
   | FetchDeclineReqsInFlightLimit  !Word
   | FetchDeclineBytesInFlightLimit !SizeInBytes !SizeInBytes !SizeInBytes
   | FetchDeclinePeerBusy           !SizeInBytes !SizeInBytes !SizeInBytes
   | FetchDeclineConcurrencyLimit   !FetchMode !Word
  deriving (Eq, Show)


-- | The \"oh noes?!\" operator.
--
-- In the case of an error, the operator provides a specific error value.
--
(?!) :: Maybe a -> e -> Either e a
Just x  ?! _ = Right x
Nothing ?! e = Left  e

-- | The combination of a 'ChainSuffix' and a list of discontiguous
-- 'ChainFragment's:
--
-- * When comparing two 'CandidateFragments' as candidate chains, we use the
--   'ChainSuffix'.
--
-- * To track which blocks of that candidate still have to be downloaded, we
--   use a list of discontiguous 'ChainFragment's.
--
type CandidateFragments header = (ChainSuffix header, [ChainFragment header])


fetchDecisions
  :: (HasHeader header, HasHeader block,
      HeaderHash header ~ HeaderHash block)
  => FetchDecisionPolicy header
  -> FetchMode
  -> AnchoredFragment header
  -> (Point block -> Bool)
  -> [(AnchoredFragment header, PeerInfo header extra)]
  -> [(FetchDecision (FetchRequest header), PeerInfo header extra)]
fetchDecisions fetchDecisionPolicy@FetchDecisionPolicy {
                 plausibleCandidateChain,
                 compareCandidateChains,
                 blockFetchSize
               }
               fetchMode
               currentChain
               fetchedBlocks =

    -- Finally, make a decision for each (chain, peer) pair.
    fetchRequestDecisions
      fetchDecisionPolicy
      fetchMode
  . map swizzleSIG

    -- Filter to keep blocks that are not already in-flight with other peers.
  . filterNotAlreadyInFlightWithOtherPeers
      fetchMode
  . map swizzleSI

    -- Reorder chains based on consensus policy and network timing data.
  . prioritisePeerChains
      fetchMode
      compareCandidateChains
      blockFetchSize
  . map swizzleIG

    -- Filter to keep blocks that are not already in-flight for this peer.
  . filterNotAlreadyInFlightWithPeer
  . map swizzleI

    -- Filter to keep blocks that have not already been downloaded.
  . filterNotAlreadyFetched
      fetchedBlocks

    -- Select the suffix up to the intersection with the current chain.
  . selectForkSuffixes
      currentChain

    -- First, filter to keep chains the consensus layer tells us are plausible.
  . filterPlausibleCandidates
      plausibleCandidateChain
      currentChain
  where
    -- Data swizzling functions to get the right info into each stage.
    swizzleI   (c, p@(_,     inflight,_,   _)) = (c,         inflight,       p)
    swizzleIG  (c, p@(_,     inflight,gsvs,_)) = (c,         inflight, gsvs, p)
    swizzleSI  (c, p@(status,inflight,_,   _)) = (c, status, inflight,       p)
    swizzleSIG (c, p@(status,inflight,gsvs,_)) = (c, status, inflight, gsvs, p)

{-
We have the node's /current/ or /adopted/ chain. This is the node's chain in
the sense specified by the Ouroboros algorithm. It is a fully verified chain
with block bodies and a ledger state.

    ┆   ┆
    ├───┤
    │   │
    ├───┤
    │   │
    ├───┤
    │   │
    ├───┤
    │   │
 ───┴───┴─── current chain length (block number)

With chain selection we are interested in /candidate/ chains. We have these
candidate chains in the form of chains of verified headers, but without bodies.

The consensus layer gives us the current set of candidate chains from our peers
and we have the task of selecting which block bodies to download, and then
passing those block bodes back to the consensus layer. The consensus layer will
try to validate them and decide if it wants to update its current chain.

    ┆   ┆     ┆   ┆     ┆   ┆     ┆   ┆     ┆   ┆
    ├───┤     ├───┤     ├───┤     ├───┤     ├───┤
    │   │     │   │     │   │     │   │     │   │
    ├───┤     ├───┤     ├───┤     ├───┤     ├───┤
    │   │     │   │     │   │     │   │     │   │
    ├───┤     ├───┤     ├───┤     ├───┤     ├───┤
    │   │     │   │     │   │     │   │     │   │
    ├───┤     ├───┤     ├───┤     ├───┤     └───┘
    │   │     │   │     │   │     │   │
 ───┴───┴─────┼───┼─────┼───┼─────┼───┼───────────── current chain length
              │   │     │   │     │   │
  current     ├───┤     ├───┤     └───┘
  (blocks)    │   │     │   │
              └───┘     └───┘
                A         B         C         D
             candidates
             (headers)

In this example we have four candidate chains, with all but chain D strictly
longer than our current chain.

In general there are many candidate chains. We make a distinction between a
candidate chain and the peer from which it is available. It is often the
case that the same chain is available from multiple peers. We will try to be
clear about when we are referring to chains or the combination of a chain and
the peer from which it is available.

For the sake of the example let us assume we have the four chains above
available from the following peers.

peer    1         2         3         4         5         6         7
      ┆   ┆     ┆   ┆     ┆   ┆     ┆   ┆     ┆   ┆     ┆   ┆     ┆   ┆
      ├───┤     ├───┤     ├───┤     ├───┤     ├───┤     ├───┤     ├───┤
      │   │     │   │     │   │     │   │     │   │     │   │     │   │
      ├───┤     ├───┤     ├───┤     ├───┤     └───┘     ├───┤     ├───┤
      │   │     │   │     │   │     │   │               │   │     │   │
    ──┼───┼─────┼───┼─────┼───┼─────┼───┼───────────────┼───┼─────┼───┼──
      │   │     │   │     │   │     │   │               │   │     │   │
      └───┘     ├───┤     ├───┤     ├───┤               ├───┤     ├───┤
                │   │     │   │     │   │               │   │     │   │
                └───┘     └───┘     └───┘               └───┘     └───┘
chain   C         A         B         A         D         B         A

This is the form in which we are informed about candidate chains from the
consensus layer, the combination of a chain and the peer it is from. This
makes sense, since these things change independently.

We will process the chains in this form, keeping the peer/chain combination all
the way through. Although there could in principle be some opportunistic saving
by sharing when multiple peers provide the same chain, taking advantage of this
adds complexity and does nothing to improve our worst case costs.

We are only interested in candidate chains that are strictly longer than our
current chain. So our first task is to filter down to this set.
-}


-- | Keep only those candidate chains that are preferred over the current
-- chain. Typically, this means that their length is longer than the length of
-- the current chain.
--
filterPlausibleCandidates
  :: HasHeader header
  => (AnchoredFragment block -> AnchoredFragment header -> Bool)
  -> AnchoredFragment block  -- ^ The current chain
  -> [(AnchoredFragment header, peerinfo)]
  -> [(FetchDecision (AnchoredFragment header), peerinfo)]
filterPlausibleCandidates plausibleCandidateChain currentChain chains =
    [ (chain', peer)
    | (chain,  peer) <- chains
    , let chain' = do
            guard (plausibleCandidateChain currentChain chain)
              ?! FetchDeclineChainNotPlausible
            return chain
    ]


{-
In the example, this leaves us with only the candidate chains: A, B and C, but
still paired up with the various peers.


peer    1         2         3         4                   6         7
      ┆   ┆     ┆   ┆     ┆   ┆     ┆   ┆               ┆   ┆     ┆   ┆
      ├───┤     ├───┤     ├───┤     ├───┤               ├───┤     ├───┤
      │   │     │   │     │   │     │   │               │   │     │   │
      ├───┤     ├───┤     ├───┤     ├───┤               ├───┤     ├───┤
      │   │     │   │     │   │     │   │               │   │     │   │
    ──┼───┼─────┼───┼─────┼───┼─────┼───┼───────────────┼───┼─────┼───┼──
      │   │     │   │     │   │     │   │               │   │     │   │
      └───┘     ├───┤     ├───┤     ├───┤               ├───┤     ├───┤
                │   │     │   │     │   │               │   │     │   │
                └───┘     └───┘     └───┘               └───┘     └───┘
chain   C         A         B         A                   B         A
-}


{-
Of course we would at most need to download the blocks in a candidate chain
that are not already in the current chain. So we must find those intersections.

Before we do that, lets define how we represent a suffix of a chain. We do this
very simply as a chain fragment: exactly those blocks contained in the suffix.
A chain fragment is of course not a chain, but has many similar invariants.

We will later also need to represent chain ranges when we send block fetch
requests. We do this using a pair of points: the first and last blocks in the
range.  While we can represent an empty chain fragment, we cannot represent an
empty fetch range, but this is ok since we never request empty ranges.

 Chain fragment
    ┌───┐
    │ ◉ │ Start of range, inclusive
    ├───┤
    │   │
    ├───┤
    │   │
    ├───┤
    │   │
    ├───┤
    │ ◉ │ End of range, inclusive.
    └───┘
-}

-- | A chain suffix, obtained by intersecting a candidate chain with the
-- current chain.
--
-- The anchor point of a 'ChainSuffix' will be a point within the bounds of
-- the currrent chain ('AnchoredFragment.withinFragmentBounds'), indicating
-- that it forks off in the last @K@ blocks.
--
-- A 'ChainSuffix' must be non-empty, as an empty suffix, i.e. the candidate
-- chain is equal to the current chain, would not be a plausible candidate.
newtype ChainSuffix header =
    ChainSuffix { getChainSuffix :: AnchoredFragment header }

{-
We define the /chain suffix/ as the suffix of the candidate chain up until (but
not including) where it intersects the current chain.


   current    peer 1    peer 2

    ┆   ┆
    ├───┤
    │  ◀┿━━━━━━━━━━━━━━━━━┓
    ├───┤               ┌─╂─┐
    │   │               │ ◉ │
    ├───┤               ├───┤
    │   │               │   │
    ├───┤               ├───┤
    │  ◀┿━━━━━━━┓       │   │
 ───┴───┴─────┬─╂─┬─────┼───┼───
              │ ◉ │     │   │
              └───┘     ├───┤
                        │ ◉ │
                        └───┘
                C         A

In this example we found that C was a strict extension of the current chain
and chain A was a short fork.

Note that it's possible that we don't find any intersection within the last K
blocks. This means the candidate forks by more than K and so we are not
interested in this candidate at all.
-}

-- | Find the chain suffix for a candidate chain, with respect to the
-- current chain.
--
chainForkSuffix
  :: (HasHeader header, HasHeader block,
      HeaderHash header ~ HeaderHash block)
  => AnchoredFragment block  -- ^ Current chain.
  -> AnchoredFragment header -- ^ Candidate chain
  -> Maybe (ChainSuffix header)
chainForkSuffix current candidate =
    case AnchoredFragment.intersect current candidate of
      Nothing                         -> Nothing
      Just (_, _, _, candidateSuffix) ->
        -- If the suffix is empty, it means the candidate chain was equal to
        -- the current chain and didn't fork off. Such a candidate chain is
        -- not a plausible candidate, so it must have been filtered out.
        assert (not (AnchoredFragment.null candidateSuffix)) $
        Just (ChainSuffix candidateSuffix)

selectForkSuffixes
  :: (HasHeader header, HasHeader block,
      HeaderHash header ~ HeaderHash block)
  => AnchoredFragment block
  -> [(FetchDecision (AnchoredFragment header), peerinfo)]
  -> [(FetchDecision (ChainSuffix      header), peerinfo)]
selectForkSuffixes current chains =
    [ (mchain', peer)
    | (mchain,  peer) <- chains
    , let mchain' = do
            chain <- mchain
            chainForkSuffix current chain ?! FetchDeclineChainNoIntersection
    ]

{-
We define the /fetch range/ as the suffix of the fork range that has not yet
had its blocks downloaded and block content checked against the headers.

    ┆   ┆
    ├───┤
    │   │
    ├───┤               ┌───┐
    │   │    already    │   │
    ├───┤    fetched    ├───┤
    │   │    blocks     │   │
    ├───┤               ├───┤
    │   │               │░◉░│  ◄  fetch range
 ───┴───┴─────┬───┬─────┼───┼───
              │░◉░│ ◄   │░░░│
              └───┘     ├───┤
                        │░◉░│  ◄
                        └───┘

In earlier versions of this scheme we maintained and relied on the invariant
that the ranges of fetched blocks are backwards closed. This meant we never had
discontinuous ranges of fetched or not-yet-fetched blocks. This invariant does
simplify things somewhat by keeping the ranges continuous however it precludes
fetching ranges of blocks from different peers in parallel.

We do not maintain any such invariant and so we have to deal with there being
gaps in the ranges we have already fetched or are yet to fetch. To keep the
tracking simple we do not track the ranges themselves, rather we track the set
of individual blocks without their relationship to each other.

-}

-- | Find the fragments of the chain suffix that we still need to fetch, these
-- are the fragments covering blocks that have not yet been fetched and are
-- not currently in the process of being fetched from this peer.
--
-- Typically this is a single fragment forming a suffix of the chain, but in
-- the general case we can get a bunch of discontiguous chain fragments.
--
filterNotAlreadyFetched
  :: (HasHeader header, HeaderHash header ~ HeaderHash block)
  => (Point block -> Bool)
  -> [(FetchDecision (ChainSuffix        header), peerinfo)]
  -> [(FetchDecision (CandidateFragments header), peerinfo)]
filterNotAlreadyFetched alreadyDownloaded chains =
    [ (mcandidates, peer)
    | (mcandidate,  peer) <- chains
    , let mcandidates = do
            candidate <- mcandidate
            let chainfragment = AnchoredFragment.unanchorFragment
                              $ getChainSuffix candidate
                fragments = ChainFragment.filter notAlreadyFetched
                                                 chainfragment
            guard (not (null fragments)) ?! FetchDeclineAlreadyFetched
            return (candidate, fragments)
    ]
  where
    notAlreadyFetched = not . alreadyDownloaded . castPoint . blockPoint


filterNotAlreadyInFlightWithPeer
  :: HasHeader header
  => [(FetchDecision (CandidateFragments header), PeerFetchInFlight header,
                                                  peerinfo)]
  -> [(FetchDecision (CandidateFragments header), peerinfo)]
filterNotAlreadyInFlightWithPeer chains =
    [ (mcandidatefragments',          peer)
    | (mcandidatefragments, inflight, peer) <- chains
    , let mcandidatefragments' = do
            (candidate, chainfragments) <- mcandidatefragments
            let fragments = concatMap (ChainFragment.filter
                                         (notAlreadyInFlight inflight))
                                      chainfragments
            guard (not (null fragments)) ?! FetchDeclineInFlightThisPeer
            return (candidate, fragments)
    ]
  where
    notAlreadyInFlight inflight b =
      blockPoint b `Set.notMember` peerFetchBlocksInFlight inflight


-- | A penultimate step of filtering, but this time across peers, rather than
-- individually for each peer. If we're following the parallel fetch
-- mode then we filter out blocks that are already in-flight with other
-- peers.
--
-- Note that this does /not/ cover blocks that are proposed to be fetched in
-- this round of decisions. That step is covered  in 'fetchRequestDecisions'.
--
filterNotAlreadyInFlightWithOtherPeers
  :: HasHeader header
  => FetchMode
  -> [(FetchDecision [ChainFragment header], PeerFetchStatus header,
                                             PeerFetchInFlight header,
                                             peerinfo)]
  -> [(FetchDecision [ChainFragment header], peerinfo)]

filterNotAlreadyInFlightWithOtherPeers FetchModeDeadline chains =
    [ (mchainfragments,       peer)
    | (mchainfragments, _, _, peer) <- chains ]

filterNotAlreadyInFlightWithOtherPeers FetchModeBulkSync chains =
    [ (mcandidatefragments',      peer)
    | (mcandidatefragments, _, _, peer) <- chains
    , let mcandidatefragments' = do
            chainfragments <- mcandidatefragments
            let fragments = concatMap (ChainFragment.filter notAlreadyInFlight)
                                      chainfragments
            guard (not (null fragments)) ?! FetchDeclineInFlightOtherPeer
            return fragments
    ]
  where
    notAlreadyInFlight b =
      blockPoint b `Set.notMember` blocksInFlightWithOtherPeers

   -- All the blocks that are already in-flight with all peers
    blocksInFlightWithOtherPeers =
      Set.unions
        [ case status of
            PeerFetchStatusShutdown -> Set.empty
            PeerFetchStatusAberrant -> Set.empty
            _other                  -> peerFetchBlocksInFlight inflight
        | (_, status, inflight, _) <- chains ]


prioritisePeerChains
  :: forall header peer. HasHeader header
  => FetchMode
  -> (AnchoredFragment header -> AnchoredFragment header -> Ordering)
  -> (header -> SizeInBytes)
  -> [(FetchDecision (CandidateFragments header), PeerFetchInFlight header,
                                                  PeerGSV,
                                                  peer)]
  -> [(FetchDecision [ChainFragment header],      peer)]
prioritisePeerChains FetchModeDeadline compareCandidateChains blockFetchSize =
    --TODO: last tie-breaker is still original order (which is probably
    -- peerid order). We should use a random tie breaker so that adversaries
    -- cannot get any advantage.

    map (\(decision, peer) ->
            (fmap (\(_,_,fragment) -> fragment) decision, peer))
  . concatMap ( concat
              . transpose
              . groupBy (equatingFst
                          (equatingRight
                            ((==) `on` chainHeadPoint)))
              . sortBy  (comparingFst
                          (comparingRight
                            (compare `on` chainHeadPoint)))
              )
  . groupBy (equatingFst
              (equatingRight
                (equatingPair
                   -- compare on probability band first, then preferred chain
                   (==)
                   (equateCandidateChains `on` getChainSuffix)
                 `on`
                   (\(band, chain, _fragments) -> (band, chain)))))
  . sortBy  (descendingOrder
              (comparingFst
                (comparingRight
                  (comparingPair
                     -- compare on probability band first, then preferred chain
                     compare
                     (compareCandidateChains `on` getChainSuffix)
                   `on`
                      (\(band, chain, _fragments) -> (band, chain))))))
  . map annotateProbabilityBand
  where
    annotateProbabilityBand (Left decline, _, _, peer) = (Left decline, peer)
    annotateProbabilityBand (Right (chain,fragments), inflight, gsvs, peer) =
        (Right (band, chain, fragments), peer)
      where
        band = probabilityBand $
                 estimateResponseDeadlineProbability
                   gsvs
                   (peerFetchBytesInFlight inflight)
                   (totalFetchSize blockFetchSize fragments)
                   deadline

    deadline = 2 -- seconds -- TODO: get this from external info

    equateCandidateChains chain1 chain2
      | EQ <- compareCandidateChains chain1 chain2 = True
      | otherwise                                  = False

    chainHeadPoint (_,ChainSuffix c,_) = AnchoredFragment.headPoint c

prioritisePeerChains FetchModeBulkSync compareCandidateChains blockFetchSize =
    map (\(decision, peer) ->
            (fmap (\(_, _, fragment) -> fragment) decision, peer))
  . sortBy (comparingFst
             (comparingRight
               (comparingPair
                  -- compare on preferred chain first, then duration
                  (compareCandidateChains `on` getChainSuffix)
                  compare
                `on`
                  (\(duration, chain, _fragments) -> (chain, duration)))))
  . map annotateDuration
  where
    annotateDuration (Left decline, _, _, peer) = (Left decline, peer)
    annotateDuration (Right (chain,fragments), inflight, gsvs, peer) =
        (Right (duration, chain, fragments), peer)
      where
        -- TODO: consider if we should put this into bands rather than just
        -- taking the full value.
        duration = estimateExpectedResponseDuration
                     gsvs
                     (peerFetchBytesInFlight inflight)
                     (totalFetchSize blockFetchSize fragments)

totalFetchSize :: HasHeader header
               => (header -> SizeInBytes)
               -> [ChainFragment header]
               -> SizeInBytes
totalFetchSize blockFetchSize fragments =
  sum [ blockFetchSize header
      | fragment <- fragments
      , header   <- ChainFragment.toOldestFirst fragment ]

type Comparing a = a -> a -> Ordering
type Equating  a = a -> a -> Bool

descendingOrder :: Comparing a -> Comparing a
descendingOrder cmp = flip cmp

comparingPair :: Comparing a -> Comparing b -> Comparing (a, b)
comparingPair cmpA cmpB (a1, b1) (a2, b2) = cmpA a1 a2 <> cmpB b1 b2

equatingPair :: Equating a -> Equating b -> Equating (a, b)
equatingPair eqA eqB (a1, b1) (a2, b2) = eqA a1 a2 && eqB b1 b2

comparingEither :: Comparing a -> Comparing b -> Comparing (Either a b)
comparingEither _ _    (Left  _) (Right _) = LT
comparingEither cmpA _ (Left  x) (Left  y) = cmpA x y
comparingEither _ cmpB (Right x) (Right y) = cmpB x y
comparingEither _ _    (Right _) (Left  _) = GT

equatingEither :: Equating a -> Equating b -> Equating (Either a b)
equatingEither _ _   (Left  _) (Right _) = False
equatingEither eqA _ (Left  x) (Left  y) = eqA x y
equatingEither _ eqB (Right x) (Right y) = eqB x y
equatingEither _ _   (Right _) (Left  _) = False

comparingFst :: Comparing a -> Comparing (a, b)
comparingFst cmp = cmp `on` fst

equatingFst :: Equating a -> Equating (a, b)
equatingFst eq = eq `on` fst

comparingRight :: Comparing b -> Comparing (Either a b)
comparingRight = comparingEither mempty

equatingRight :: Equating b -> Equating (Either a b)
equatingRight = equatingEither (\_ _ -> True)

-- | Given the probability of the download completing within the deadline,
-- classify that into one of three broad bands: high, medium and low.
--
-- The bands are
--
-- * high:    98% -- 100%
-- * medium:  75% --  98%
-- * low:      0% --  75%
--
probabilityBand :: Double -> ProbabilityBand
probabilityBand p
  | p > 0.98  = ProbabilityHigh
  | p > 0.75  = ProbabilityModerate
  | otherwise = ProbabilityLow
 -- TODO: for hysteresis, increase probability if we're already using this peer

data ProbabilityBand = ProbabilityLow
                     | ProbabilityModerate
                     | ProbabilityHigh
  deriving (Eq, Ord, Show)


{-
In the second phase we walk over the prioritised fetch suffixes for each peer
and make a decision about whether we should initiate any new fetch requests.

This decision is based on a number of factors:

 * Is the fetch suffix empty? If so, there's nothing to do.
 * Do we already have block fetch requests in flight with this peer?
 * If so are we under the maximum number of in-flight blocks for this peer?
 * Is this peer still performing within expectations or has it missed any soft
   time outs?
 * Has the peer missed any hard timeouts or otherwise been disconnected.
 * Are we at our soft or hard limit of the number of peers we are prepared to
   fetch blocks from concurrently?

We look at each peer chain fetch suffix one by one. Of course decisions we
make earlier can affect decisions later, in particular the number of peers we
fetch from concurrently can increase if we fetch from a new peer, and we must
obviously take that into account when considering later peer chains.
-}


fetchRequestDecisions
  :: HasHeader header
  => FetchDecisionPolicy header
  -> FetchMode
  -> [(FetchDecision [ChainFragment header], PeerFetchStatus header,
                                             PeerFetchInFlight header,
                                             PeerGSV,
                                             peer)]
  -> [(FetchDecision (FetchRequest header),  peer)]
fetchRequestDecisions fetchDecisionPolicy fetchMode chains =
    go nConcurrentFetchPeers0 Set.empty chains
  where
    go !_ !_ [] = []
    go !nConcurrentFetchPeers !blocksFetchedThisRound
       ((mchainfragments, status, inflight, gsvs, peer) : cps) =

        (decision, peer)
      : go nConcurrentFetchPeers' blocksFetchedThisRound' cps
      where
        decision = fetchRequestDecision
                     fetchDecisionPolicy
                     fetchMode
                     nConcurrentFetchPeers
                     (calculatePeerFetchInFlightLimits gsvs)
                     inflight
                     status
                     mchainfragments'

        mchainfragments' =
          case fetchMode of
            FetchModeDeadline -> mchainfragments
            FetchModeBulkSync -> do
                chainfragments <- mchainfragments
                let fragments =
                      concatMap (ChainFragment.filter notFetchedThisRound)
                                chainfragments
                guard (not (null fragments)) ?! FetchDeclineInFlightOtherPeer
                return fragments
              where
                notFetchedThisRound h =
                  blockPoint h `Set.notMember` blocksFetchedThisRound

        nConcurrentFetchPeers'
          -- increment if it was idle, and now will not be
          | peerFetchReqsInFlight inflight == 0
          , Right{} <- decision = nConcurrentFetchPeers + 1
          | otherwise           = nConcurrentFetchPeers

        -- This is only for avoiding duplication between fetch requests in this
        -- round of decisions. Avoiding duplication with blocks that are already
        -- in flight is handled by filterNotAlreadyInFlightWithOtherPeers
        blocksFetchedThisRound' =
          case decision of
            Left _                         -> blocksFetchedThisRound
            Right (FetchRequest fragments) -> blocksFetchedThisRound
                                  `Set.union` blocksFetchedThisDecision
              where
                blocksFetchedThisDecision =
                  Set.fromList
                    [ blockPoint header
                    | fragment <- fragments
                    , header   <- ChainFragment.toOldestFirst fragment ]

    nConcurrentFetchPeers0 =
        fromIntegral
      . length
      . filter (> 0)
      . map (\(_, _, PeerFetchInFlight{peerFetchReqsInFlight}, _, _) ->
                       peerFetchReqsInFlight)
      $ chains


fetchRequestDecision
  :: HasHeader header
  => FetchDecisionPolicy header
  -> FetchMode
  -> Word
  -> PeerFetchInFlightLimits
  -> PeerFetchInFlight header
  -> PeerFetchStatus header
  -> FetchDecision [ChainFragment header]
  -> FetchDecision (FetchRequest  header)

fetchRequestDecision _ _ _ _ _ _ (Left decline)
  = Left decline

fetchRequestDecision _ _ _ _ _ PeerFetchStatusShutdown _
  = Left FetchDeclinePeerShutdown

fetchRequestDecision _ _ _ _ _ PeerFetchStatusAberrant _
  = Left FetchDeclinePeerSlow

fetchRequestDecision FetchDecisionPolicy {
                       maxConcurrencyBulkSync,
                       maxConcurrencyDeadline,
                       maxInFlightReqsPerPeer,
                       blockFetchSize
                     }
                     fetchMode
                     nConcurrentFetchPeers
                     PeerFetchInFlightLimits {
                       inFlightBytesLowWatermark,
                       inFlightBytesHighWatermark
                     }
                     PeerFetchInFlight {
                       peerFetchReqsInFlight,
                       peerFetchBytesInFlight
                     }
                     peerFetchStatus
                     (Right fetchFragments)

  | peerFetchReqsInFlight >= maxInFlightReqsPerPeer
  = Left $ FetchDeclineReqsInFlightLimit
             maxInFlightReqsPerPeer

  | peerFetchBytesInFlight >= inFlightBytesHighWatermark
  = Left $ FetchDeclineBytesInFlightLimit
             peerFetchBytesInFlight
             inFlightBytesLowWatermark
             inFlightBytesHighWatermark

    -- This covers the case when we could still fit in more reqs or bytes, but
    -- we want to let it drop below a low water mark before sending more so we
    -- get a bit more batching behaviour, rather than lots of 1-block reqs.
  | peerFetchStatus == PeerFetchStatusBusy
  = Left $ FetchDeclinePeerBusy
             peerFetchBytesInFlight
             inFlightBytesLowWatermark
             inFlightBytesHighWatermark

  | peerFetchReqsInFlight == 0
  , let maxConcurrentFetchPeers = case fetchMode of
                                    FetchModeBulkSync -> maxConcurrencyBulkSync
                                    FetchModeDeadline -> maxConcurrencyDeadline
  , nConcurrentFetchPeers >= maxConcurrentFetchPeers
  = Left $ FetchDeclineConcurrencyLimit
             fetchMode maxConcurrentFetchPeers

    -- We've checked our request limit and our byte limit. We are then
    -- guaranteed to get at least one non-empty request range.
  | otherwise
  = assert (peerFetchReqsInFlight < maxInFlightReqsPerPeer) $
    assert (not (null fetchFragments)) $

    Right $ selectBlocksUpToLimits
              blockFetchSize
              peerFetchReqsInFlight
              maxInFlightReqsPerPeer
              peerFetchBytesInFlight
              inFlightBytesHighWatermark
              fetchFragments


-- | 
--
-- Precondition: The result will be non-empty if
--
-- Property: result is non-empty if preconditions satisfied
--
selectBlocksUpToLimits
  :: HasHeader header
  => (header -> SizeInBytes) -- ^ Block body size
  -> Word -- ^ Current number of requests in flight
  -> Word -- ^ Maximum number of requests in flight allowed
  -> SizeInBytes -- ^ Current number of bytes in flight
  -> SizeInBytes -- ^ Maximum number of bytes in flight allowed
  -> [ChainFragment header]
  -> FetchRequest header
selectBlocksUpToLimits blockFetchSize nreqs0 maxreqs nbytes0 maxbytes fragments =
    assert (nreqs0 < maxreqs && nbytes0 < maxbytes && not (null fragments)) $
    -- The case that we are already over our limits has to be checked earlier,
    -- outside of this function. From here on however we check for limits.

    let fragments' = goFrags nreqs0 nbytes0 fragments in
    assert (all (not . ChainFragment.null) fragments') $
    FetchRequest fragments'
  where
    goFrags _     _      []     = []
    goFrags nreqs nbytes (c:cs)
      | nreqs+1  > maxreqs      = []
      | otherwise               = goFrag (nreqs+1) nbytes Empty c cs
      -- Each time we have to pick from a new discontiguous chain fragment then
      -- that will become a new request, which contributes to our in-flight
      -- request count. We never break the maxreqs limit.

    goFrag nreqs nbytes c' Empty    cs = c' : goFrags nreqs nbytes cs
    goFrag nreqs nbytes c' (b :< c) cs
      | nbytes' >= maxbytes            = [c' :> b]
      | otherwise                      = goFrag nreqs nbytes' (c' :> b) c cs
      where
        nbytes' = nbytes + blockFetchSize b
      -- Note that we always pick the one last block that crosses the maxbytes
      -- limit. This cover the case where we otherwise wouldn't even be able to
      -- request a single block, as it's too large.

