{-# LANGUAGE DataKinds                #-}
{-# LANGUAGE DisambiguateRecordFields #-}
{-# LANGUAGE FlexibleContexts         #-}
{-# LANGUAGE NamedFieldPuns           #-}
{-# LANGUAGE PatternSynonyms          #-}
{-# LANGUAGE PolyKinds                #-}
{-# LANGUAGE ScopedTypeVariables      #-}
{-# LANGUAGE TypeApplications         #-}
{-# LANGUAGE TypeFamilies             #-}
module Test.ThreadNet.Infra.Shelley (
    CoreNode(..)
  , CoreNodeKeyInfo(..)
  , genCoreNode
  , mkLeaderCredentials
  , mkGenesisConfig
  , coreNodeKeys
  , mkProtocolRealTPraos
  , tpraosSlotLength
  ) where

import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Sequence.Strict as Seq
import qualified Data.Set as Set
import           Data.Word (Word64)

import           Cardano.Crypto (ProtocolMagicId (..))
import           Cardano.Crypto.DSIGN.Class (DSIGNAlgorithm (..), SignKeyDSIGN,
                     signedDSIGN)
import           Cardano.Crypto.Hash (HashAlgorithm)
import           Cardano.Crypto.KES.Class (SignKeyKES, deriveVerKeyKES,
                     genKeyKES)
import           Cardano.Crypto.Seed (mkSeedFromBytes)
import           Cardano.Crypto.VRF.Class (SignKeyVRF, deriveVerKeyVRF,
                     genKeyVRF)
import           Cardano.Slotting.Slot (EpochSize (..))

import           Ouroboros.Consensus.BlockchainTime
import           Ouroboros.Consensus.Config.SecurityParam
import           Ouroboros.Consensus.Node.ProtocolInfo

import           Test.Util.Orphans.Arbitrary ()
import           Test.Util.Random
import           Test.Util.Time (dawnOfTime)

import qualified Shelley.Spec.Ledger.Address as SL
import qualified Shelley.Spec.Ledger.BaseTypes as SL
import qualified Shelley.Spec.Ledger.Coin as SL
import qualified Shelley.Spec.Ledger.Credential as SL
import qualified Shelley.Spec.Ledger.Crypto as SL
import qualified Shelley.Spec.Ledger.Keys as SL
import qualified Shelley.Spec.Ledger.OCert as SL
import qualified Shelley.Spec.Ledger.PParams as SL
import qualified Shelley.Spec.Ledger.TxData as SL

import           Ouroboros.Consensus.Shelley.Ledger (ShelleyBlock)
import           Ouroboros.Consensus.Shelley.Node
import           Ouroboros.Consensus.Shelley.Protocol
import           Ouroboros.Consensus.Shelley.Protocol.Crypto (DSIGN,
                     HotKey (..))

import           Test.Consensus.Shelley.MockCrypto (TPraosMockCrypto)
import qualified Test.Shelley.Spec.Ledger.Generator.Core as Gen

tpraosSlotLength :: SlotLength
tpraosSlotLength = slotLengthFromSec 2

data CoreNode c = CoreNode {
      cnGenesisKey  :: !(SignKeyDSIGN (SL.DSIGN c))
    , cnDelegateKey :: !(SignKeyDSIGN (SL.DSIGN c))
      -- ^ Cold delegate key. The hash of the corresponding verification
      -- (public) key will be used as the payment credential.
    , cnStakingKey  :: !(SignKeyDSIGN (SL.DSIGN c))
      -- ^ The hash of the corresponding verification (public) key will be
      -- used as the staking credential.
    , cnVRF         :: !(SignKeyVRF   (SL.VRF   c))
    , cnKES         :: !(SignKeyKES   (SL.KES   c))
    , cnOCert       :: !(SL.OCert               c)
    }

data CoreNodeKeyInfo h = CoreNodeKeyInfo
  { cnkiKeyPair
      ::  ( SL.KeyPair 'SL.Payment (TPraosMockCrypto h)
          , SL.KeyPair 'SL.Staking (TPraosMockCrypto h)
          )
  , cnkiCoreNode ::
      ( SL.KeyPair 'SL.Genesis (TPraosMockCrypto h)
      , Gen.AllIssuerKeys h 'SL.GenesisDelegate
      )
  }

coreNodeKeys
  :: HashAlgorithm h
  => CoreNode (TPraosMockCrypto h)
  -> CoreNodeKeyInfo h
coreNodeKeys CoreNode{cnGenesisKey, cnDelegateKey, cnStakingKey, cnVRF, cnKES}
  = CoreNodeKeyInfo
      { cnkiCoreNode =
          ( mkDSIGNKeyPair cnGenesisKey
          , Gen.AllIssuerKeys
            { Gen.cold = mkDSIGNKeyPair cnDelegateKey
            , Gen.vrf  = mkVRFKeyPair cnVRF
            , Gen.hot  = [(SL.KESPeriod 100, mkKESKeyPair cnKES)]
            , Gen.hk   = SL.hashKey (SL.VKey $ deriveVerKeyDSIGN cnDelegateKey)
            }
          )
      , cnkiKeyPair = (mkDSIGNKeyPair cnDelegateKey, mkDSIGNKeyPair cnStakingKey)
      }
  where
    mkDSIGNKeyPair k = SL.KeyPair (SL.VKey $ deriveVerKeyDSIGN k)
                                  k
    mkVRFKeyPair k = (k, deriveVerKeyVRF k)
    mkKESKeyPair k = (k, deriveVerKeyKES k)

genCoreNode
  :: (MonadRandom m, TPraosCrypto c)
  => SL.KESPeriod
  -> m (CoreNode c)
genCoreNode startKESPeriod = do
    genKey <- withMRSeed 8 genKeyDSIGN
    delKey <- withMRSeed 8 genKeyDSIGN
    stkKey <- withMRSeed 8 genKeyDSIGN
    vrfKey <- withMRSeed 8 genKeyVRF
    kesKey <- withMRSeed 8 genKeyKES
    let kesPub = deriveVerKeyKES kesKey
        sigma = signedDSIGN
          ()
          (kesPub, certificateIssueNumber, startKESPeriod)
          delKey
    let ocert = SL.OCert {
            ocertVkHot     = kesPub
          , ocertN         = certificateIssueNumber
          , ocertKESPeriod = startKESPeriod
          , ocertSigma     = sigma
          }
    return CoreNode {
        cnGenesisKey  = genKey
      , cnDelegateKey = delKey
      , cnStakingKey  = stkKey
      , cnVRF         = vrfKey
      , cnKES         = kesKey
      , cnOCert       = ocert
      }
  where
    certificateIssueNumber = 0
    withMRSeed sz go = do
      seed <- mkSeedFromBytes <$> getRandomBytes sz
      pure $ go seed

mkLeaderCredentials :: TPraosCrypto c => CoreNode c -> TPraosLeaderCredentials c
mkLeaderCredentials CoreNode { cnDelegateKey, cnVRF, cnKES, cnOCert } =
    TPraosLeaderCredentials {
        tpraosLeaderCredentialsSignKey    = HotKey 0 cnKES
      , tpraosLeaderCredentialsIsCoreNode = TPraosIsCoreNode {
          tpraosIsCoreNodeOpCert     = cnOCert
        , tpraosIsCoreNodeColdVerKey = SL.VKey $ deriveVerKeyDSIGN cnDelegateKey
        , tpraosIsCoreNodeSignKeyVRF = cnVRF
        }
      }

mkGenesisConfig
  :: forall c. TPraosCrypto c
  => ProtVer  -- ^ Initial protocol version
  -> SecurityParam
  -> Double  -- ^ Decentralisation param
  -> SlotLength
  -> Word64  -- ^ Max KES evolutions
  -> [CoreNode c]
  -> ShelleyGenesis c
mkGenesisConfig pVer k d slotLength maxKESEvolutions coreNodes =
    ShelleyGenesis {
      -- Matches the start of the ThreadNet tests
      sgSystemStart           = dawnOfTime
    , sgNetworkMagic          = 0
    , sgNetworkId             = networkId
    , sgProtocolMagicId       = ProtocolMagicId 0
    , sgActiveSlotsCoeff      = 0.5 -- TODO 1 is not accepted by 'mkActiveSlotCoeff'
    , sgSecurityParam         = maxRollbacks k
    , sgEpochLength           = EpochSize (10 * maxRollbacks k)
    , sgSlotsPerKESPeriod     = 10 -- TODO
    , sgMaxKESEvolutions      = maxKESEvolutions
    , sgSlotLength            = getSlotLength slotLength
    , sgUpdateQuorum          = 1  -- TODO
    , sgMaxLovelaceSupply     = maxLovelaceSupply
    , sgProtocolParams        = pparams
    , sgGenDelegs             = coreNodesToGenesisMapping
    , sgInitialFunds          = initialFunds
    , sgStaking               = initialStake
    }
  where
    networkId :: SL.Network
    networkId = SL.Testnet

    initialLovelacePerCoreNode :: Word64
    initialLovelacePerCoreNode = 1000

     -- TODO
    maxLovelaceSupply :: Word64
    maxLovelaceSupply =
      fromIntegral (length coreNodes) * initialLovelacePerCoreNode

    pparams :: SL.PParams
    pparams = SL.emptyPParams
      { SL._d               =
            SL.truncateUnitInterval
          . realToFrac
          $ d
      , SL._maxBBSize       = 10000 -- TODO
      , SL._maxBHSize       = 1000 -- TODO
      , SL._protocolVersion = pVer
      }

    coreNodesToGenesisMapping :: Map (SL.KeyHash 'SL.Genesis c) (SL.GenDelegPair c)
    coreNodesToGenesisMapping  = Map.fromList
      [ let
          gkh :: SL.KeyHash 'SL.Genesis c
          gkh = SL.hashKey . SL.VKey $ deriveVerKeyDSIGN cnGenesisKey

          gdpair :: SL.GenDelegPair c
          gdpair = SL.GenDelegPair
              (SL.hashKey . SL.VKey $ deriveVerKeyDSIGN cnDelegateKey)
              (SL.hashVerKeyVRF $ deriveVerKeyVRF cnVRF)

        in (gkh, gdpair)
      | CoreNode { cnGenesisKey, cnDelegateKey, cnVRF } <- coreNodes
      ]

    initialFunds :: Map (SL.Addr c) SL.Coin
    initialFunds = Map.fromList
      [ (addr, coin)
      | CoreNode { cnDelegateKey, cnStakingKey } <- coreNodes
      , let addr = SL.Addr networkId
                           (mkCredential cnDelegateKey)
                           (SL.StakeRefBase (mkCredential cnStakingKey))
            coin = SL.Coin $ fromIntegral initialLovelacePerCoreNode
      ]

    -- In this initial stake, each core node delegates its stake to itself.
    initialStake :: ShelleyGenesisStaking c
    initialStake = ShelleyGenesisStaking
      { sgsPools = Map.fromList
          [ (pk, pp)
          | pp@(SL.PoolParams { _poolPubKey = pk }) <- Map.elems coreNodeToPoolMapping
          ]
        -- The staking key maps to the key hash of the pool, which is set to the
        -- "delegate key" in order that nodes may issue blocks both as delegates
        -- and as stake pools.
      , sgsStake = Map.fromList
          [ ( SL.hashKey . SL.VKey $ deriveVerKeyDSIGN cnStakingKey
            , SL.hashKey . SL.VKey $ deriveVerKeyDSIGN cnDelegateKey
            )
          | CoreNode {cnDelegateKey, cnStakingKey} <- coreNodes
          ]
      }
      where
        coreNodeToPoolMapping :: Map (SL.KeyHash 'SL.StakePool c) (SL.PoolParams c)
          = Map.fromList
            [ ( SL.KeyHash $ SL.hash $ deriveVerKeyDSIGN cnStakingKey
              , SL.PoolParams
                { SL._poolPubKey = poolHash
                , SL._poolVrf = vrfHash
                  -- Each core node pledges its full stake to the pool.
                , SL._poolPledge = SL.Coin $ fromIntegral initialLovelacePerCoreNode
                , SL._poolCost = SL.Coin 1
                , SL._poolMargin = SL.UnsafeUnitInterval 0
                  -- Reward accounts live in a separate "namespace" to other
                  -- accounts, so it should be fine to use the same address.
                , SL._poolRAcnt = SL.RewardAcnt networkId $ mkCredential cnDelegateKey
                , SL._poolOwners = Set.singleton poolOwnerHash
                , SL._poolRelays = Seq.empty
                , SL._poolMD = SL.SNothing
                }
              )
            | CoreNode { cnDelegateKey, cnStakingKey, cnVRF } <- coreNodes
              -- The pool and owner hashes are derived from the same key, but
              -- use different hashing schemes
            , let poolHash = SL.hashKey . SL.VKey $ deriveVerKeyDSIGN cnDelegateKey
            , let poolOwnerHash = SL.hashKey . SL.VKey $ deriveVerKeyDSIGN cnDelegateKey
            , let vrfHash = SL.hashVerKeyVRF $ deriveVerKeyVRF cnVRF
            ]

    mkCredential :: SignKeyDSIGN (DSIGN c) -> SL.Credential r c
    mkCredential = SL.KeyHashObj . SL.hashKey . SL.VKey . deriveVerKeyDSIGN

mkProtocolRealTPraos
  :: forall m c. (MonadRandom m, TPraosCrypto c)
  => ShelleyGenesis c
  -> CoreNode c
  -> ProtocolInfo m (ShelleyBlock c)
mkProtocolRealTPraos genesis coreNode =
    protocolInfoShelley
      genesis
      maxMajorPV
      protVer
      (Just (mkLeaderCredentials coreNode))
  where
    protVer = SL.ProtVer 0 0
    maxMajorPV = 1000 -- TODO
