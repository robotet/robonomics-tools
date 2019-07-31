{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
module Network.Robonomics.Liability where

import           Control.Monad.Reader                   (asks)
import           Control.Monad.Trans                    (lift)
import           Data.Base58String.Bitcoin              (toBytes)
import           Data.ByteArray                         (convert)
import qualified Data.ByteString.Char8                  as C8
import           Data.Default                           (def)
import           Data.Proxy                             (Proxy (..))
import           Data.Solidity.Abi.Codec                as ABI (encode)
import           Lens.Micro                             ((.~))
import           Network.Ethereum.Account.Safe          (safeConfirmations,
                                                         safeSend)
import           Network.Ethereum.Api.Types             (DefaultBlock,
                                                         Filter (..), Quantity,
                                                         changeBlockNumber)
import           Network.Ethereum.Api.Types             (TxReceipt)
import           Network.Ethereum.Contract.Event        (event')
import           Network.Ethereum.Contract.Method       (selector)
import           Network.Ethereum.Web3
import           Network.JsonRpc.TinyClient             (JsonRpc)

import qualified Network.Robonomics.Contract.Factory    as F
import qualified Network.Robonomics.Contract.Liability  as L
import qualified Network.Robonomics.Contract.Lighthouse as Lighthouse
import           Network.Robonomics.Message             (Demand, Offer,
                                                         Report (..))

data Liability = Liability
    { liabilityModel      :: Bytes
    , liabilityObjective  :: Bytes
    , liabilityLighthouse :: Address
    , liabilityPromisee   :: Address
    , liabilityPromisor   :: Address
    , liabilityToken      :: Address
    , liabilityCost       :: Integer
    } deriving Eq

instance Show Liability where
    show Liability{..} = ("Liability" ++) $
        C8.unpack $ C8.concat $ C8.cons ' ' <$>
            [ C8.pack (show liabilityModel)
            , C8.pack (show liabilityObjective)
            , C8.pack (show liabilityLighthouse)
            , C8.pack (show liabilityPromisee)
            , C8.pack (show liabilityPromisor)
            , C8.pack (show liabilityToken)
            , C8.pack (show liabilityCost)
            ]

-- | Read liability from blockchain by address
read :: JsonRpc m
     => Address
     -- ^ Liability address
     -> LocalKeyAccount m Liability
read a = withParam (to .~ a) $
    Liability <$> L.model
              <*> L.objective
              <*> L.lighthouse
              <*> L.promisee
              <*> L.promisor
              <*> L.token
              <*> (fromIntegral <$> L.cost)

-- | All liabilities created in given block range
list :: Address
     -- ^ Liability factory address
     -> DefaultBlock
     -- ^ Observation range FROM
     -> DefaultBlock
     -- ^ Observation range TO
     -> (Quantity -> Address -> Web3 ())
     -- ^ Liability handler with args: block number, liability address
     -> Web3 ()
list factory from to f = do
    let flt = (def :: Filter F.NewLiability)
            { filterAddress   = Just [ factory ]
            , filterFromBlock = from
            , filterToBlock   = to
            }
    event' flt $ \(F.NewLiability a) -> do
        mbbn <- asks changeBlockNumber
        case mbbn of
            Just bn -> lift $ f bn a
            Nothing -> return ()
        return ContinueEvent

-- | Create liability smart contract for given demand/offer pair
create :: (JsonRpc m, Unit gasPrice)
       => Address
       -- ^ Lighthouse address
       -> gasPrice
       -- ^ Gas price
       -> (Demand, Offer)
       -- ^ Matched deal
       -> LocalKeyAccount m TxReceipt
create lighthouse price (demand, offer) =
    withParam (to .~ lighthouse) $
        withParam (gasPrice .~ price) $
            F.createLiability (ABI.encode demand) (ABI.encode offer)

-- | Finalize liability for given signed report
finalize :: (JsonRpc m, Unit gasPrice)
         => Address
         -- ^ Lighthouse address
         -> gasPrice
         -- ^ Gas price
         -> Report
         -- ^ Liability report
         -> LocalKeyAccount m TxReceipt
finalize lighthouse price Report{..} =
    withParam (to .~ lighthouse) $
        withParam (gasPrice .~ price) $
            Lighthouse.finalizeLiability reportLiability resultBytes reportSuccess reportSignature
  where resultBytes = convert (toBytes reportResult)
