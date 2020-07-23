{-# LANGUAGE OverloadedStrings #-}

module Test.CLI.Shelley.Golden.Node.IssueOpCert
  ( golden_shelleyNodeIssueOpCert
  ) where

import Cardano.Prelude hiding (to)

import Hedgehog (Property)

import qualified System.Directory as IO
import qualified Test.OptParse as OP

{- HLINT ignore "Use camelCase" -}

golden_shelleyNodeIssueOpCert :: Property
golden_shelleyNodeIssueOpCert = OP.propertyOnce $ do
  OP.workspace "tmp/node-issue-op-cert" $ \tempDir -> do
    let hotKesVerificationKeyFile = "test/cli/node-issue-op-cert/data/node-kes.vkey"
        coldSigningKeyFile = "test/cli/node-issue-op-cert/data/delegate.skey"
        originalOperationalCertificateIssueCounterFile = "test/cli/node-issue-op-cert/data/delegate-op-cert.counter"
        operationalCertificateIssueCounterFile = tempDir <> "/delegate-op-cert.counter"
        operationalCertFile = tempDir <> "/operational.cert"

    void . liftIO $ IO.copyFile originalOperationalCertificateIssueCounterFile operationalCertificateIssueCounterFile

    -- We could generate the required keys here, but then if the ket generation fails this
    -- test would also fail which is misleading.
    -- However, the keys can be generated eg:
    --    cabal run cardano-cli:cardano-cli -- shelley node key-gen-KES \
    --        --verification-key-file cardano-cli/test/cli/node-issue-op-cert/data/node-kes.vkey \
    --        --signing-key-file /dev/null
    void . liftIO $ OP.execCardanoCLI
        [ "shelley","node","issue-op-cert"
        , "--hot-kes-verification-key-file", hotKesVerificationKeyFile
        , "--cold-signing-key-file", coldSigningKeyFile
        , "--operational-certificate-issue-counter", operationalCertificateIssueCounterFile
        , "--kes-period", "0"
        , "--out-file", operationalCertFile
        ]

    OP.assertFileOccurences 1 "NodeOperationalCertificate" $ operationalCertFile
    OP.assertFileOccurences 1 "Next certificate issue number: 1" $ operationalCertificateIssueCounterFile
