{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE NoImplicitPrelude   #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE TypeFamilies        #-}
{-# LANGUAGE TypeOperators       #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE DerivingStrategies  #-}

module Main where

import Prelude (IO, print, putStrLn, String)
import qualified Prelude as H

import PlutusTx
import PlutusTx.Prelude        hiding (Semigroup(..), unless, ($))
import Plutus.V2.Ledger.Api
  ( BuiltinData
  , ScriptContext (..)
  , TxInfo (..)
  , TxOut (..)
  , Validator
  , mkValidatorScript
  , PubKeyHash
  , Address (..)
  , Credential (..)
  , POSIXTime
  , CurrencySymbol
  , TokenName
  , txInfoValidRange
  )
import Plutus.V2.Ledger.Contexts (txSignedBy)
import Plutus.V1.Ledger.Interval (contains, from)
import qualified Plutus.V1.Ledger.Value as Value

import qualified Data.ByteString.Lazy as LBS
import qualified Data.ByteString.Short as SBS
import Codec.Serialise (serialise)

import Cardano.Api (writeFileTextEnvelope)
import Cardano.Api.Shelley (PlutusScript (..), PlutusScriptV2)

--------------------------------------------------------------------------------
-- Datum & Redeemer
--------------------------------------------------------------------------------

-- Invoice datum: issuer, buyer, amount (in smallest stable unit),
-- due date, paid flag, invoice hash (for off-chain reference), optional assigned factor,
-- stable token identifier, and KYC authority pubkey that must sign stable settlements.
data InvoiceDatum = InvoiceDatum
    { invIssuer       :: PubKeyHash
    , invBuyer        :: PubKeyHash
    , invAmount       :: Integer         -- amount in stable-token base units
    , invDue          :: POSIXTime
    , invPaid         :: Bool
    , invHash         :: BuiltinByteString
    , invAssignedTo   :: Maybe PubKeyHash -- Nothing = not assigned (still with issuer)
    , invStableCS     :: CurrencySymbol
    , invStableTN     :: TokenName
    , invKycAuth      :: PubKeyHash       -- compliance authority required for stable settlements
    }
PlutusTx.unstableMakeIsData ''InvoiceDatum

-- Redeemer actions: AssignTo factor, Pay (tx pays stable token), MarkPaid (issuer can mark off-chain verified),
-- Cancel (issuer only)
data InvoiceAction = AssignTo PubKeyHash
                   | Pay Integer POSIXTime -- amountPaid, paidAt
                   | MarkPaid
                   | Cancel
PlutusTx.unstableMakeIsData ''InvoiceAction

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

{-# INLINABLE pubKeyHashAddress #-}
pubKeyHashAddress :: PubKeyHash -> Address
pubKeyHashAddress pkh = Address (PubKeyCredential pkh) Nothing

{-# INLINABLE valuePaidTo #-}
-- Sum of a particular asset paid to a given pubkey in tx outputs
valuePaidTo :: TxInfo -> PubKeyHash -> CurrencySymbol -> TokenName -> Integer
valuePaidTo info pkh cs tn =
    let outs = txInfoOutputs info
        matches = [ Value.valueOf (txOutValue o) cs tn
                  | o <- outs
                  , txOutAddress o == pubKeyHashAddress pkh
                  ]
    in foldr (+) 0 matches

{-# INLINABLE nowInRange #-}
-- Check if the tx's valid range includes a POSIXTime >= t (i.e. time t is reachable in this tx)
nowInRange :: TxInfo -> POSIXTime -> Bool
nowInRange info t = contains (from t) (txInfoValidRange info)

{-# INLINABLE isPastDue #-}
isPastDue :: TxInfo -> POSIXTime -> Bool
isPastDue info due = -- tx valid range includes some time >= due
    nowInRange info due

--------------------------------------------------------------------------------
-- Core validator
--------------------------------------------------------------------------------

{-# INLINABLE mkInvoiceValidator #-}
mkInvoiceValidator :: InvoiceDatum -> InvoiceAction -> ScriptContext -> Bool
mkInvoiceValidator inv action ctx =
    case action of

      AssignTo factorPkh ->
        traceIfFalse "assign: only issuer can assign" (txSignedBy info (invIssuer inv))
        && traceIfFalse "assign: cannot assign if already paid" (not (invPaid inv))
        where
          info = scriptContextTxInfo ctx

      Pay amountPaid paidAt ->
        -- Buyer pays the invoice (or buyer-authorized agent). Payment must be >= invAmount.
        -- If a factor is assigned, funds should go to the factor; otherwise to issuer.
        traceIfFalse "pay: buyer signature required" (txSignedBy info (invBuyer inv))
        && traceIfFalse "pay: amountPaid must be positive" (amountPaid > 0)
        && traceIfFalse "pay: amountPaid must be >= invoice amount" (amountPaid >= invAmount inv)
        && traceIfFalse "pay: timestamp reachable in tx" (nowInRange info paidAt)
        && traceIfFalse "pay: destination must receive stable token" (valuePaidTo info recipient (invStableCS inv) (invStableTN inv) >= invAmount inv)
        -- If payment is done via stable rails, require the KYC authority to sign this transaction to show compliance check.
        && traceIfFalse "pay: kyc authority signature required for stable settlement" (txSignedBy info (invKycAuth inv))
        where
          info = scriptContextTxInfo ctx
          recipient = case invAssignedTo inv of
                        Just f  -> f
                        Nothing -> invIssuer inv

      MarkPaid ->
        -- Issuer may mark an invoice as paid (off-chain verified) — only issuer.
        traceIfFalse "markpaid: issuer signature required" (txSignedBy info (invIssuer inv))
        where
          info = scriptContextTxInfo ctx

      Cancel ->
        -- Issuer may cancel (only issuer) but only if not already paid.
        traceIfFalse "cancel: issuer signature required" (txSignedBy info (invIssuer inv))
        && traceIfFalse "cancel: cannot cancel if already paid" (not (invPaid inv))
        where
          info = scriptContextTxInfo ctx

--------------------------------------------------------------------------------
-- Wrap & compile
--------------------------------------------------------------------------------

{-# INLINABLE wrapped #-}
wrapped :: BuiltinData -> BuiltinData -> BuiltinData -> ()
wrapped d r c =
    let inv  = unsafeFromBuiltinData d :: InvoiceDatum
        act  = unsafeFromBuiltinData r :: InvoiceAction
        ctx  = unsafeFromBuiltinData c :: ScriptContext
    in if mkInvoiceValidator inv act ctx
         then ()
         else traceError "InvoiceFactor: validation failed"

validator :: Validator
validator = mkValidatorScript $$(PlutusTx.compile [|| wrapped ||])

--------------------------------------------------------------------------------
-- Write validator to file
--------------------------------------------------------------------------------

saveValidator :: IO ()
saveValidator = do
    let scriptSerialised = serialise validator
        scriptShortBs    = SBS.toShort (LBS.toStrict scriptSerialised)
        plutusScript     = PlutusScriptSerialised scriptShortBs :: PlutusScript PlutusScriptV2
    r <- writeFileTextEnvelope "invoice-factor-plutus.plutus" Nothing plutusScript
    case r of
      Left err -> print err
      Right () -> putStrLn "Invoice / factoring validator written to: invoice-factor-plutus.plutus"

main :: IO ()
main = saveValidator
